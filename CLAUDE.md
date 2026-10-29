# saas_billing

Billing analytics for a fictional B2B SaaS company, built the way a data team would build it:

```
generator (Python) ──▶ data/raw ──dlt──▶ Snowflake RAW.BILLING ──dbt──▶ ANALYTICS_DEV (dev) / ANALYTICS (prod)
                   └─▶ data/truth  (answer key: off limits, see below)
```

- `transform/`: the dbt project. `models/staging/billing/` (one view per raw table) → `models/intermediate/`
  → `models/marts/` (tables, contracts enforced). Singular tests in `transform/tests/`.
- `docs/raw_sources.md`: what we know about each raw table (grain, keys, timezones, nulls, duplicates). Read it
  before touching a source; update it when you learn something new.
- `docs/decisions/`: architecture decision records (ADRs); new ones via the `/adr` skill.
- README: setup, the dbt targets, and the full naming table.

## Commands

Run dbt from `transform/`, everything else from the repo root. Always pass `--target dev`, even though it's the
default. **Never use `--target prod` or `--target ci`**: those belong to GitHub Actions.

```bash
uv sync                                                              # install
uv run pytest                                                        # generator + loader tests
uv run pre-commit run --all-files                                    # hooks CI runs
uv run sqlfluff lint transform/models                                # SQL lint (dbt templater, dev target)
uv run --no-sync dbt build --select <selection> --target dev         # from transform/
uv run --no-sync dbt build --no-partial-parse --target dev           # before reporting results; CI parses fully
uv run --no-sync dbt run-operation codegen.generate_base_model --args '{source_name: billing, table_name: <t>}' --target dev
```

`uv run generate-billing-data` rewrites `data/`. `uv run load-raw` replaces the `RAW.BILLING` tables in Snowflake,
so it's an outward action: ask first.

## Conventions

- **Staging**: one model per source table, no joins or aggregations. CTEs `source → deduplicated → renamed`,
  columns grouped by type with comments (ids, strings, numerics, booleans, timestamps). Every dedup removes exact
  copies only, explains why in a comment, and has a natural-key test so anything else fails instead of vanishing.
- **Names**: `stg_`, `int_`, `dim_`, `fct_`. Facts are named for their grain and say which type they are
  (transaction, periodic snapshot, accumulating snapshot) in the YAML description.
- **Time**: `*_at` is a UTC `TIMESTAMP_TZ`. `*_date_et` / `*_month_et` are dates in the reporting timezone
  (`vars.reporting_timezone`, America/New_York), produced by `to_reporting_date()`. Naive source timestamps go
  through `naive_to_utc()`. "Now" is `int_data_watermark`, never `current_timestamp()`.
- **Money**: integer cents, `*_cents`.
- **Booleans**: `is_` / `has_`.
- **Marts**: contracts are enforced, so every column needs a `data_type` in YAML.
- **Style**: dbt Labs (lowercase, trailing commas, explicit aliases). SQLFluff enforces it, and a hook lints dbt
  SQL after each edit.
- **Test severity**: `error` = should never happen, fail the build. `warn` = a known source data-quality issue that
  staging fixes; documented, not blocking.

## Working agreement

- Explain what a step does and why before running it, especially for infrastructure, CI, secrets, git and PRs.
  Before anything outward (push, opening a PR, creating cloud or GitHub resources), say what will be visible and
  confirm.
- Profile the data before designing a model: row counts, natural-key duplicates, null patterns, JSON shape,
  timezones. Justify decisions with business rules and the data.
- **Never read or model toward the answer key**: `data/truth/`, `generator/billing_generator/truth.py`,
  `generator/billing_generator/messiness.py`. On a real team there is none. Comparing against it happens once,
  at the end of the project, when the user says so.
- Verify with evidence independent of the code under test (the source's own current-state tables, invoice status,
  reconciliations computed another way). Avoid tests that are true by construction, and prove a singular test
  actually compared rows (non-empty join), so it can't pass on empty.
- One branch per change (`feat/`, `fix/`, `chore/`, `ci/`, `docs/`, `test/`), always from up-to-date `main`,
  never from an unmerged branch. Open a PR; never merge it.

## Known pitfalls (each one has caught us)

- **Session timezone.** Snowflake's default is America/Los_Angeles. A plain date-string filter
  (`< '2024-01-01'`) or an NTZ → TZ cast follows the session timezone (64 rows instead of 33). The account
  default is now UTC, but sessions can override it: write explicit offsets and use the macros.
- **JSON null is not SQL NULL.** `parse_json(attributes):x is not null` is true for JSON `null` (3,875 instead
  of 34). Cast first (`:x::varchar`) or use `is_null_value()`.
- **dlt adds no metadata columns here.** The loader hands dlt Arrow tables, so there's no `_DLT_LOAD_ID` or
  `_DLT_ID`. Check columns in Snowflake rather than assuming.
- **Partial parse can hide a change.** A `dbt_project.yml` flag change seemed to work only because the partial
  parse reused the cached manifest. After changing project config, flags, packages or macros, re-verify with
  `--no-partial-parse`.
- **"Latest change" must be the latest change to that attribute.** `max_by(to_plan, effective_at)` picked the
  latest change of any kind, so a frequency switch after an upgrade gave a null plan (179 false mismatches).
  Filter to rows that set the attribute first.
