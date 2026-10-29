---
name: new-staging-model
description: Build a dbt staging model for a raw source table, profiling the data first. Use when asked to stage, add, or model a new raw/source table (stg_<source>__<table>). Not for intermediate models or marts.
argument-hint: "[source table]"
---

# New staging model

Staging is one model per source table: rename, cast, deduplicate. No joins, no aggregations, no business logic.
The data decides the design, so profile before writing any SQL.

## 1. Profile the source

Read [docs/raw_sources.md](../../../docs/raw_sources.md) for what's already known about `$ARGUMENTS`. Then run
the queries in [profiling.md](profiling.md) (read-only, `--target dev`):

1. Columns: types, null counts, distinct counts
2. Duplicates: exact copies vs rows sharing a key but differing
3. Any key collisions, row by row
4. JSON columns: keys, JSON `null` vs SQL `NULL`, varying types
5. Timezone of each naive timestamp, checked against a column known to be UTC

Decide the grain and natural key from the data and the source's behavior (append-only log or current-state
table), not from the column names alone.

## 2. Record findings

Add or update the table's section in `docs/raw_sources.md`: grain, keys, timestamps and timezone, nulls,
duplicates (with counts), anomalies. Keep its existing format.

## 3. Stop for review

**Always stop here**, even if nothing looks unusual. Show the user the profile and a proposed design:

- Grain and natural key
- Dedup rule (what's removed, how many rows, why it's safe)
- Column renames and casts
- Tests to add, with severities

Wait for their answer before writing SQL.

## 4. Draft with codegen

From `transform/`:

```bash
uv run --no-sync dbt run-operation codegen.generate_base_model --args '{source_name: billing, table_name: <table>}' --target dev
```

If the table isn't declared in `_billing__sources.yml` yet, add it first (description, source tests).
`codegen.generate_source` needs `database_name: RAW`, since it defaults to the target's database.

## 5. Shape to house style

Follow the existing models in `models/staging/billing/` (e.g. `stg_billing__payments.sql`):

- CTEs `source → deduplicated → renamed` (add `parsed` for JSON)
- Columns grouped with comments: ids, strings, numerics, booleans, timestamps
- Renames: generic names get the entity (`status` → `payment_status`), timestamps end in `_at` (UTC
  `timestamp_tz`), money in `_cents`, booleans `is_` / `has_`; naive timestamps through `naive_to_utc()`
- JSON: cast every extracted value (`:key::varchar`) so JSON `null` becomes SQL `NULL`
- The dedup CTE has a comment saying what it removes and why it's safe

Then `uv run --no-sync dbt run-operation codegen.generate_model_yaml --args '{model_names: [stg_billing__<table>]}' --target dev`
for the YAML skeleton, and write real descriptions.

## 6. Tests

- Natural key: `unique` + `not_null` (or `dbt_utils.unique_combination_of_columns`), severity `error`
- `accepted_values` on every category column, `relationships` to other staging models
- Source-level tests on the raw table for known issues the model fixes: severity `warn`, with a comment
- Conditional completeness where a column should be set only for some rows

## 7. Reconcile and build

Staging rows must equal raw rows minus the documented duplicates. Show the three numbers. Then:

```bash
uv run --no-sync dbt build --select stg_billing__<table> --target dev
uv run --no-sync dbt build --no-partial-parse --target dev
```

Finish with the `verify-change` skill before reporting results.
