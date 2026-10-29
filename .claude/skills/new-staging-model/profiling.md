# Profiling queries

Read-only. Run each from `transform/` with:

```bash
uv run --no-sync dbt show --target dev --limit 100 --inline "<query>"
```

Replace `<table>`, `<key>` and `<json_column>`. Every query reads the source through `source()`, so it hits
`RAW.BILLING` exactly as the staging model will.

## 1. Columns: type, nulls, distinct values

One row per column. `data_type` shows `timestamp_ntz` vs `timestamp_tz` (naive vs offset-aware).

```sql
{% set rel = source('billing', '<table>') %}
{% for c in adapter.get_columns_in_relation(rel) %}
select
    '{{ c.name | lower }}' as column_name,
    '{{ c.data_type | lower }}' as data_type,
    count(*) as row_count,
    count(*) - count({{ c.name }}) as null_count,
    count(distinct {{ c.name }}) as distinct_count
from {{ rel }}
{% if not loop.last %}union all{% endif %}
{% endfor %}
```

## 2. Duplicates: exact copies vs key collisions

If `key_count = distinct_row_count`, every duplicate is an exact copy and `select distinct` (or a
`row_number()` on all columns) is safe. If not, some rows share a key but differ: list them (query 3) and decide
with the user before deduplicating.

```sql
{% set rel = source('billing', '<table>') %}
select
    count(*) as row_count,
    count(distinct <key>) as key_count,
    (select count(*) from (select distinct * from {{ rel }})) as distinct_row_count
from {{ rel }}
```

For a composite natural key, use `count(distinct <col_a>, <col_b>)`.

## 3. Rows sharing a key but differing

```sql
{% set rel = source('billing', '<table>') %}
with rows_hashed as (
    select *, hash(*) as row_hash from {{ rel }}
),
colliding_keys as (
    select <key> from rows_hashed group by <key> having count(distinct row_hash) > 1
)
select rows_hashed.*
from rows_hashed
inner join colliding_keys using (<key>)
order by <key>
```

Snowflake allows `hash(*)` only in a SELECT list, so hash first, then group.

## 4. JSON shape

For a JSON text column: each key, how often it appears, how often it's JSON `null` (not SQL `NULL`), and whether
its type varies.

```sql
{% set rel = source('billing', '<table>') %}
select
    f.key as json_key,
    count(*) as present_count,
    count_if(is_null_value(f.value)) as json_null_count,
    count(distinct typeof(f.value)) as type_count
from {{ rel }} as src,
    lateral flatten(input => parse_json(src.<json_column>)) as f
group by 1
order by 1
```

Break it down by a type column (e.g. `event_type`) when the keys depend on it.

## 5. Timezone

There's no generic query. For each `timestamp_ntz` column, find a column written at the same moment that is
known to be UTC, and compare candidate conversions on matching rows, the way PR #7 checked
`accounts.created_at` against `subscriptions.trial_started_at`. Use `naive_to_utc()`, never a cast to
`timestamp_tz` (that uses the session timezone).
