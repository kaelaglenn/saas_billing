# 0007. Slim CI against the production manifest, with full-build fallbacks

- **Status:** Proposed
- **Date:** 2026-11-19
- **Related:** [ADR 0006](0006-production-deploy-in-place-with-repo-secret.md), `.github/workflows/dbt_ci.yml`,
  `.github/workflows/dbt_deploy.yml`

## Context

dbt CI built the whole project (about 350 nodes of our own plus the evaluator) into a per-PR schema on every PR.
Since [ADR 0006](0006-production-deploy-in-place-with-repo-secret.md), every successful production deploy uploads
its `manifest.json` as a workflow artifact, kept for 90 days, so CI has a production state to compare against.

- **Production is readable from CI.** `DEVELOPER`, the CI role, inherits `REPORTER` and can select every current
  and future table and view in `ANALYTICS` (granted in `snowflake/bootstrap.sql` for this purpose).
- **Environment-aware config doesn't cause false positives.** `generate_schema_name` uses folder schemas only in
  prod, but compared with the prod manifest, an unchanged branch selected 0 of our 352 nodes.
- **The evaluator is disabled in prod**, so its 75 nodes and our exceptions seed are never in the prod manifest.
- **State comparison only sees the project.** A dbt, adapter or package upgrade changes how every model builds
  without changing any node, so `state:modified` would select almost nothing for it.

## Decision

dbt CI builds `state:modified+` with `--defer --state` against the latest successful production deploy's
manifest. It builds the whole project instead when there's no manifest to download, or when the PR changes
`pyproject.toml`, `uv.lock`, `transform/packages.yml` or `transform/package-lock.yml`.

## Alternatives considered

- **Keep building the whole project on every PR.** It's simple and costs about a minute today, but CI's cost and
  run time grow with the project rather than with the change.
- **Slim CI with no dependency check.** Lost: a dependency upgrade would build only the evaluator, so the PR most
  likely to break every model would be the one tested least.
- **Download the manifest with `actions/download-artifact`.** Lost to the `gh` CLI already on the runner: no
  new third-party action to pin and keep updated.

## Consequences

- A PR builds what it changed and everything downstream. Unchanged parents are read from production, so a PR is
  tested against real production tables. In the local dry run, a change to one intermediate model built 17 of
  our nodes instead of about 350.
- The evaluator still audits the whole project on every PR, without special-casing: it always counts as new.
- CI now depends on production. If a deploy fails, PRs compare against the last successful one. A PR branched
  from an older `main` also counts changes merged since as modified. Both make CI build more, never less.
- The workflow needs two more read permissions: `actions: read` for the artifact and `pull-requests: read` for
  the changed-file list.
- Revisit the dependency list whenever dependencies are declared in a new file, and the 90-day fallback if
  deploys become rare enough that the artifact often expires.
