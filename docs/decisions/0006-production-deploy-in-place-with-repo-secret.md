# 0006. Deploy production in place, with the key as a repository secret until the repo is public

- **Status:** Proposed
- **Date:** 2026-11-18
- **Related:** [PR #21](https://github.com/kaelaglenn/saas_billing/pull/21), `.github/workflows/dbt_deploy.yml`,
  `snowflake/README.md` (GitHub Actions settings)

## Context

Production (`ANALYTICS`) had never been built. `DBT_PROD_SVC` (role `TRANSFORMER`) is the only user that can
write there, so a GitHub Actions workflow needs its private key, and we had to decide how to store the key and
how to replace production tables.

- **Storing the key.** The repo is private, on GitHub's free plan, which has no environments (secrets usable only
  by jobs on chosen branches) for private repos. It has one contributor, and pull requests from forks never
  receive secrets. The repo is due to go public at the end of the project.
- **Replacing tables.** dbt CI already builds and tests the whole project, from the same raw data, in a per-PR
  schema before anything merges. Nothing reads production yet: no BI tool, no other consumers. A full production
  build takes about a minute (the first deploy: 345 nodes in 53 seconds on an X-Small warehouse).
- **Scheduling.** The source data is a fixed snapshot with no scheduled loads, so there is nothing new to
  process on a schedule. But production can still break without a code change: the Snowflake trial lapsed on
  ~2026-10-30 and suspended every warehouse, and nothing noticed until a developer ran `dbt debug` weeks later.

## Decision

We deploy production by building it in place (`dbt build --target prod`) on every merge that changes the dbt
project, plus a weekly Monday run as a canary. The prod key is a repository secret while the repo is private, and
moves into a `production` environment limited to `main` when the repo goes public.

## Alternatives considered

- **Blue/green: build into a separate schema or database, test it, then swap it in.** Readers never see a
  half-built or failing state. Lost for now: CI has already tested the same code on the same data, and nobody
  queries production, so it adds a swap step without removing a real risk.
- **Make the repo public first, to get environments.** Lost: going public is a one-way door planned for the end,
  after the README and the answer-key comparison, and the risk of a repository secret meanwhile is low (private
  repo, one contributor, no secrets for fork PRs).
- **Deploy on a schedule only, or on merge only.** Schedule-only delays every change; merge-only means a broken
  account or key goes unnoticed until the next merge. Both together cost a few cents a week.

## Consequences

- Production is rebuilt within minutes of a merge, and the run saves `manifest.json` for slim CI.
- While a deploy runs, tables are replaced one at a time and tested after they're built, so production can
  briefly mix old and new tables, or keep a table whose tests then fail. Acceptable with no readers.
- Until the repo is public, any workflow on any branch could read the prod key. Moving it into a `production`
  environment is part of making the repo public.
- Revisit blue/green once something reads production on a schedule or live (the planned Evidence site reads a
  snapshot, so it doesn't by itself), or if a deploy ever leaves production in a bad state.
- GitHub disables scheduled workflows in public repos after 60 days without activity; if the canary stops, that
  is the first thing to check.
