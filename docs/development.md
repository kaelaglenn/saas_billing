# Development

Setup, the dbt targets, conventions, and how changes reach production. For the warehouse itself (databases,
roles, service users), see [snowflake/README.md](../snowflake/README.md).

## Loading into Snowflake

After the [Snowflake setup](../snowflake/README.md), copy the secrets template and fill in your account identifier
and the absolute path to the `DLT_SVC` private key:

```bash
cp .dlt/secrets.toml.example .dlt/secrets.toml
```

Then generate and load:

```bash
uv run generate-billing-data && uv run load-raw
```

[load.py](../loader/raw_loader/load.py) loads the six raw tables into `RAW.BILLING`, replacing them each run (the
generator always rewrites full history), then checks row counts against the files. Source duplicates and late
arrivals are loaded as-is; cleaning them up is dbt's job. Naive timestamps stay naive (`TIMESTAMP_NTZ`) so the
`accounts` timezone quirk reaches dbt intact.

Non-secret settings are in [.dlt/config.toml](../.dlt/config.toml). In CI, secrets come from environment variables
such as `DESTINATION__SNOWFLAKE__CREDENTIALS__HOST` and `DESTINATION__SNOWFLAKE__CREDENTIALS__PRIVATE_KEY`.
The loader tests run against DuckDB, so they need no credentials.

## dbt setup

The dbt project is in [transform/](../transform/). Connection settings for every environment are in
[transform/profiles.yml](../transform/profiles.yml); anything personal or secret comes from environment variables.

| Target | Who runs it | Role | Builds into |
|---|---|---|---|
| `dev` (default) | you, locally | `DEVELOPER` | `ANALYTICS_DEV.<your DBT_SCHEMA>` |
| `ci` | GitHub Actions on PRs | `DEVELOPER` | `ANALYTICS_DEV.DBT_PR_<number>` |
| `prod` | GitHub Actions on merge | `TRANSFORMER` | `ANALYTICS.STAGING`, `ANALYTICS.MARTS`, … |

One-time setup on a new machine:

1. Install [direnv](https://direnv.net), which loads the project's environment when you `cd` into the repo:

   ```bash
   brew install direnv
   ```

   Then add `eval "$(direnv hook zsh)"` to the end of `~/.zshrc` and open a new terminal.
2. Create a key pair for your own Snowflake user and run the `ALTER USER` statement it prints:

   ```bash
   snowflake/generate_keypair.sh <YOUR_SNOWFLAKE_USER>
   ```

3. Copy the template and fill in your values:

   ```bash
   cp .env.example .env
   ```

4. Approve the repo's [.envrc](../.envrc) (direnv asks again whenever it changes):

   ```bash
   direnv allow
   ```

5. Check the connection. This builds nothing:

   ```bash
   cd transform && dbt debug
   ```

6. Install dbt packages (versions pinned in `transform/package-lock.yml`):

   ```bash
   dbt deps
   ```

7. Install the git hooks, from the repo root:

   ```bash
   uv run pre-commit install
   ```

dbt 1.12 also loads the repo's `.env` on its own, so dbt commands work even outside direnv; direnv still activates
the Python environment for plain `dbt`, `sqlfluff`, and `pytest`.

## Conventions

| Suffix / prefix | Meaning |
|---|---|
| `_at` | Timestamp, always **UTC** (`TIMESTAMP_TZ`, which also carries its offset) |
| `_date_et`, `_month_et` | Calendar date or month (first day) in the **reporting timezone**, America/New_York. A `DATE` has no timezone, so the name states it |
| `_cents` | Money, integer USD cents |
| `is_`, `has_` | Boolean |
| `stg_`, `int_`, `dim_`, `fct_` | Staging, intermediate, dimension, fact models |

Reporting dates come from the `to_reporting_date()` macro; the reporting timezone is `vars.reporting_timezone` in
`transform/dbt_project.yml`.

SQL style follows dbt Labs' style guide (lowercase, trailing commas, explicit aliases), enforced by
[SQLFluff](../.sqlfluff) with the dbt templater. The pre-commit hook lints changed models; from the repo root:

```bash
sqlfluff lint transform/models
```

`sqlfluff fix transform/models` applies the fixes it can make automatically.

## Querying metrics

The governed metric definitions live in [transform/models/semantic_layer/](../transform/models/semantic_layer/).
Query them with the MetricFlow CLI (a dev dependency) from `transform/`, after a `dbt parse`: `mf` reads
`target/semantic_manifest.json`, not the YAML.

```bash
mf query --metrics mrr,net_new_mrr,paying_subscriptions --group-by metric_time__month --order metric_time__month
```

```bash
mf query --metrics mrr --group-by metric_time__quarter,account__industry
```

MRR and ending AR are balances: summed across subscriptions or invoices, but taken at the month-end over time, so a
quarter shows its last month-end, not three months added up ([ADR 0009](decisions/0009-semantic-layer-on-finest-grain-marts.md)).
Amounts are in cents; time is the reporting timezone. The hosted Semantic Layer APIs (for BI tools) need dbt
Cloud; everything here runs on dbt Core.

## How changes reach production

All changes land on `main` through pull requests: one branch per change (`feat/`, `fix/`, `chore/`, `ci/`,
`docs/`, `test/`), always from up-to-date `main`. The pre-commit hooks refuse commits made directly on `main`, block
private keys from being committed, and run ruff and SQLFluff.

- **[CI](../.github/workflows/ci.yml)** runs the same hooks and the full pytest suite on every PR.
- **[dbt CI](../.github/workflows/dbt_ci.yml)** runs on PRs that touch the dbt project: SQLFluff, then slim CI into
  a per-PR schema, `ANALYTICS_DEV.DBT_PR_<number>`, as the `DBT_CI_SVC` service user. It compares the PR with
  production's `manifest.json`, builds only what changed plus everything downstream (`state:modified+`), and reads
  unchanged parents from production (`--defer`). It falls back to a full build when there's no production manifest
  or the PR changes dependencies ([ADR 0007](decisions/0007-slim-ci-against-prod-manifest.md)). The schema is
  dropped when the PR closes ([cleanup](../.github/workflows/dbt_ci_cleanup.yml)).
- **[Deploy](../.github/workflows/dbt_deploy.yml)** runs `dbt build` into `ANALYTICS` as `DBT_PROD_SVC`, the only
  user that can write there, when a merge changes the dbt project. Unit tests are skipped in production; CI runs
  them. The same workflow runs every Monday as a canary (the data is fixed, so it checks that keys, grants, packages
  and the account still work) and keeps `manifest.json` as an artifact for 90 days
  ([ADR 0006](decisions/0006-production-deploy-in-place-with-repo-secret.md)). After a successful build it publishes
  the [dbt docs site](https://kaelaglenn.github.io/saas_billing/) to GitHub Pages.

Repository secrets for these workflows: [GitHub Actions settings](../snowflake/README.md#github-actions-settings).

## The portfolio page

The charts on the [case study page](https://kaelaglenn.com/projects/saas-billing) come from a static export of
production marts: [export_site_charts.py](../scripts/export_site_charts.py) writes small JSON files that the site's
build turns into SVG, so the page never queries Snowflake. The page is declared as a dbt exposure
([exposures.yml](../transform/models/exposures.yml)), so the marts it reads list it as a downstream consumer.

## Working with Claude Code

[CLAUDE.md](../CLAUDE.md) holds the project's commands, conventions, and known pitfalls.
[.claude/settings.json](../.claude/settings.json) enforces the hard rules: no reading the generator's answer-key
code, no dbt `prod`/`ci` targets, no merging PRs, and SQLFluff on every SQL edit. Project skills in
[.claude/skills/](../.claude/skills/) cover staging a new source, verifying a change, ADRs and status briefs.
Personal permissions go in `.claude/settings.local.json` (git-ignored).
