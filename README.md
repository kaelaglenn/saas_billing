# saas_billing

Billing analytics for a fictional B2B SaaS company, built the way a data team would build it from scratch:
a deterministic source-data generator with a ground-truth answer key, loaded into Snowflake and modeled with
dbt, with CI/CD on GitHub Actions.

```
generator (Python) ──▶ data/raw/*.parquet ──dlt──▶ Snowflake RAW ──dbt──▶ Snowflake ANALYTICS
                   └─▶ data/truth/*.parquet  (answer key for dbt tests, never a dbt source)
```

## Roadmap

- [x] Billing data generator with validation, ground truth, and seeded messiness ([spec](docs/billing_data_generator_spec.md))
- [x] Snowflake bootstrap: databases, roles, warehouses, key-pair service users, resource monitor ([setup](snowflake/README.md))
- [x] dlt pipeline: `data/raw` → Snowflake `RAW.BILLING` ([loading](#loading-into-snowflake))
- [ ] dbt project: sources, staging, SCD2 subscription history, MRR and movements, invoices and collections
- [ ] Tests against the answer key in `data/truth`
- [x] CI: lint and tests on every PR ([ci.yml](.github/workflows/ci.yml))
- [ ] CI/CD for dbt: SQLFluff, slim CI into per-PR schemas, prod deploys on merge, scheduled runs, docs on Pages

## Quickstart

Requires [uv](https://docs.astral.sh/uv/).

```bash
uv sync
uv run generate-billing-data          # writes data/raw and data/truth (about 10 seconds)
uv run pytest                         # calendar math + an end-to-end run at 5% scale
```

Options: `--seed`, `--scale` (e.g. `0.1` for a fast 10% dataset), `--output-dir`, `--no-csv`.
Every rate, mix, and probability lives in [generator/config.yaml](generator/config.yaml).

## Loading into Snowflake

After the [Snowflake setup](snowflake/README.md), copy the secrets template and fill in your account identifier
and the absolute path to the `DLT_SVC` private key:

```bash
cp .dlt/secrets.toml.example .dlt/secrets.toml
```

Then generate and load:

```bash
uv run generate-billing-data && uv run load-raw
```

[load.py](loader/raw_loader/load.py) loads the six raw tables into `RAW.BILLING`, replacing them each run (the
generator always rewrites full history), then checks row counts against the files. Source duplicates and late
arrivals are loaded as-is; cleaning them up is dbt's job. Naive timestamps stay naive (`TIMESTAMP_NTZ`) so the
`accounts` timezone quirk reaches dbt intact.

Non-secret settings are in [.dlt/config.toml](.dlt/config.toml). In CI, secrets come from environment variables
such as `DESTINATION__SNOWFLAKE__CREDENTIALS__HOST` and `DESTINATION__SNOWFLAKE__CREDENTIALS__PRIVATE_KEY`.
The loader tests run against DuckDB, so they need no credentials.

## Raw sources

Grain, keys, timestamps and timezones, mutable vs append-only behavior, and every known null, duplicate,
and anomaly for the six `RAW.BILLING` tables: [docs/raw_sources.md](docs/raw_sources.md).

## Developing with dbt

The dbt project is in [transform/](transform/). Connection settings for every environment are in
[transform/profiles.yml](transform/profiles.yml); anything personal or secret comes from environment variables.

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

4. Approve the repo's [.envrc](.envrc) (direnv asks again whenever it changes):

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

dbt 1.12 also loads the repo's `.env` on its own, so dbt commands work even outside direnv; direnv still activates
the Python environment for plain `dbt`, `sqlfluff`, and `pytest`.

### Naming conventions

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
[SQLFluff](.sqlfluff) with the dbt templater. The pre-commit hook lints changed models; from the repo root:

```bash
sqlfluff lint transform/models
```

`sqlfluff fix transform/models` applies the fixes it can make automatically.

## How we work

All changes land on `main` through pull requests. Branch per change (`feat/…`, `fix/…`, `chore/…`, `ci/…`),
push, open a PR, merge once checks pass. The [CI workflow](.github/workflows/ci.yml) runs the same hooks and
the full test suite on every PR.

PRs that touch the dbt project also run [dbt CI](.github/workflows/dbt_ci.yml): SQLFluff, then `dbt build` of the
whole project (models, tests, `dbt_project_evaluator`) into a per-PR schema, `ANALYTICS_DEV.DBT_PR_<number>`,
as the `DBT_CI_SVC` service user. The schema is rebuilt from empty on every run and dropped when the PR closes
([cleanup](.github/workflows/dbt_ci_cleanup.yml)). Setup: [GitHub Actions settings](snowflake/README.md#github-actions-settings).

Merges that change the dbt project [deploy to production](.github/workflows/dbt_deploy.yml): `dbt build` into
`ANALYTICS` as `DBT_PROD_SVC`, the only user that can write there. The same workflow runs every Monday as a
canary (the data is a fixed snapshot, so it checks that keys, grants, packages and the account still work) and
can be run by hand from the Actions tab. Each successful run keeps `manifest.json` and the docs site as a
workflow artifact for 90 days.

After cloning, install the git hooks:

```bash
uv run pre-commit install
```

The hooks refuse commits made directly on `main`, block private keys from being committed, and run ruff.
GitHub won't enforce branch protection on a free private repo, so the hook is the guardrail until the repo
goes public.

Working with Claude Code: [CLAUDE.md](CLAUDE.md) holds the project's commands, conventions, and known pitfalls.
[.claude/settings.json](.claude/settings.json) enforces the hard rules: no reading the answer key, no dbt
`prod`/`ci` targets, no merging PRs, and SQLFluff on every SQL edit. Personal permissions go in
`.claude/settings.local.json` (git-ignored).

## Generator

The pipeline runs in stages so each can be tested on its own:

1. **Simulate** ([simulate.py](generator/billing_generator/simulate.py)) — day-by-day, event-driven state machine.
   Scheduled work (renewals, trial ends, card retries, invoice deadlines) sits in a priority queue; random
   customer actions are drawn daily and queued at random times, so everything is processed in time order.
2. **Validate** ([validate.py](generator/billing_generator/validate.py)) — integrity checks on clean data. Any
   failure stops the run before anything is written. Calibration targets print as PASS/WARN.
3. **Ground truth** ([truth.py](generator/billing_generator/truth.py)) — built from the simulator's own state
   history, never from the raw tables.
4. **Messiness** ([messiness.py](generator/billing_generator/messiness.py)) — duplicates and late arrivals
   injected into `data/raw` only, on a separate random stream, with every touched record logged.

### Outputs

| `data/raw/` (dbt sources) | `data/truth/` (answer key) |
|---|---|
| accounts, subscriptions, subscription_events, invoices, invoice_line_items, payments | subscription_history, mrr_monthly, churn_events, monthly_summary, seeded_anomalies |

`data/` is git-ignored; regenerate it any time. The same seed always produces identical files.

### Implementation decisions (beyond the spec)

These are source-system behaviors the dbt models need to handle:

- **Seat changes carry a `seat_delta`.** A scheduled decrease applies at renewal against whatever the seat
  count is then, so seats at any instant = the last full-state event (`subscription_imported`,
  `subscription_started`, `renewed`) plus deltas that took effect since. Plan and frequency changes carry
  absolute `from_*`/`to_*` values.
- **`subscription_amount_cents` on a scheduled change is the projection at request time**, the way a webhook
  would report it. `renewed` events carry the realized amount and full state.
- **Dropped scheduled changes stay in the event log.** If a subscription lapses before a scheduled decrease or
  cancellation, the event still exists with an `effective_at` after `ended_at`. It never took effect.
- **Pending cancellations carry over at cutover.** Some imported monthly subscriptions already had a
  cancellation pending on Jan 1, 2024; it appears only as `cancel_requested_at` in the
  `subscription_imported` attributes.
- **Zero-amount prorations aren't invoiced.** A change on the last day of a period prorates to 0 days.
- **A cancelled subscription with an unpaid invoice** keeps going through dunning; if collection fails, the
  invoice becomes `uncollectible` but no `lapsed` event is emitted (the subscription already ended).
- **Upgrade/downgrade rates apply to eligible subscriptions only**: upgrades to Pro subscriptions,
  downgrades to Premium subscriptions.
- **Seats can exceed 250** through seat increases; 1–250 is the range at signup.
- **The data window ends at midnight ET on Sep 30, 2026** (2026-10-01 04:00 UTC), so renewals at 00:00 UTC
  on Oct 1 (Sep 30 evening in ET) are included.
- **`accounts.updated_at`** changes only when a subscription on the account starts or ends.
- **`mrr_monthly` for Jan 2024** compares against the imported opening state, so imported subscriptions show
  as `unchanged` rather than `new`.
- **`seeded_anomalies`** also lists the genuine same-day look-alike seat increases (keep both) and the
  forced plan changes inside the repeated November 1–2 a.m. ET hour.
