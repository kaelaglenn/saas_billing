"""Compare the dbt models with the generator's answer key (data/truth/).

Run once, at the end of the project; results are written up in docs/answer_key_comparison.md. On a real team
there is no answer key, so nothing in the dbt project reads data/truth/.

Reads the marts and staging models from Snowflake (read only), copies them into an in-memory DuckDB, and
compares them with the answer key's Parquet files there. Every comparison is a full outer join, so it reports
rows on both sides, rows only in ours, rows only in the key, and value differences among the matched rows.

    uv run python scripts/compare_answer_key.py                          # production (ANALYTICS)
    uv run python scripts/compare_answer_key.py --database ANALYTICS_DEV --schema DBT_KAELA   # a dev schema

Connects with the same environment variables as the dev dbt target (SNOWFLAKE_ACCOUNT, SNOWFLAKE_USER,
SNOWFLAKE_PRIVATE_KEY_PATH), as role DEVELOPER.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path

import duckdb
import snowflake.connector

TRUTH = Path(__file__).resolve().parents[1] / "data" / "truth"

MARTS = [
    "dim_subscription_history",
    "dim_subscriptions",
    "fct_subscription_months",
    "fct_mrr_bridge",
    "fct_trials",
]


def load_ours(db: duckdb.DuckDBPyConnection, database: str, marts: str, staging: str) -> None:
    """Copy our models into DuckDB as tables named like the models."""
    conn = snowflake.connector.connect(
        account=os.environ["SNOWFLAKE_ACCOUNT"],
        user=os.environ["SNOWFLAKE_USER"],
        private_key_file=os.environ["SNOWFLAKE_PRIVATE_KEY_PATH"],
        role="DEVELOPER",
        warehouse="TRANSFORMING_WH",
        database=database,
    )
    queries = {name: f"select * from {marts}.{name}" for name in MARTS}
    queries["stg_event_ids"] = f"select event_id as id from {staging}.stg_billing__subscription_events"
    queries["stg_payment_ids"] = f"select payment_id as id from {staging}.stg_billing__payments"
    queries["raw_payments"] = "select count(*) as n from raw.billing.payments"
    try:
        for name, sql in queries.items():
            arrow = conn.cursor().execute(sql).fetch_arrow_all()
            arrow = arrow.rename_columns([c.lower() for c in arrow.column_names])
            db.register(f"_{name}", arrow)
            db.execute(f"create table {name} as select * from _{name}")
            print(f"  loaded {name}: {arrow.num_rows:,} rows")
    finally:
        conn.close()


def load_truth(db: duckdb.DuckDBPyConnection) -> None:
    for name in ["subscription_history", "mrr_monthly", "monthly_summary", "churn_events", "seeded_anomalies"]:
        db.execute(f"create view key_{name} as select * from '{TRUTH / f'{name}.parquet'}'")


def show(db: duckdb.DuckDBPyConnection, title: str, sql: str) -> None:
    print(f"\n== {title}")
    result = db.sql(sql)
    for row in result.fetchall():
        print("  " + ", ".join(f"{col}={val}" for col, val in zip(result.columns, row)))


def compare(db: duckdb.DuckDBPyConnection) -> None:
    show(
        db,
        "Subscription history (expect every row matched, no differences)",
        """
        select count_if(o.subscription_id is not null and k.subscription_id is not null) as n_both,
            count_if(k.subscription_id is null) as n_only_ours,
            count_if(o.subscription_id is null) as n_only_key,
            count_if(k.subscription_id is not null and o.subscription_id is not null and (
                o.subscription_status is distinct from k.status or o.plan is distinct from k.plan
                or o.seats is distinct from k.seats or o.billing_frequency is distinct from k.billing_frequency
                or o.mrr_cents is distinct from k.mrr_cents or o.valid_to is distinct from k.valid_to
                or o.is_current is distinct from k.is_current)) as n_value_diffs
        from dim_subscription_history as o
        full join key_subscription_history as k
            on o.subscription_id = k.subscription_id and o.valid_from = k.valid_from
        """,
    )
    show(
        db,
        "Current state (expect every subscription matched, no differences)",
        """
        select count_if(o.subscription_id is not null and k.subscription_id is not null) as n_both,
            count_if(k.subscription_id is null) as n_only_ours,
            count_if(o.subscription_id is null) as n_only_key,
            count_if(k.subscription_id is not null and o.subscription_id is not null and (
                o.subscription_status is distinct from k.status or o.plan is distinct from k.plan
                or o.seats is distinct from k.seats or o.billing_frequency is distinct from k.billing_frequency
                or o.mrr_cents is distinct from k.mrr_cents)) as n_value_diffs
        from dim_subscriptions as o
        full join (select * from key_subscription_history where is_current) as k using (subscription_id)
        """,
    )
    show(
        db,
        "Month-end MRR (known: 1 movement difference, A; rows only ours by design, B)",
        """
        select count_if(o.subscription_id is not null and k.subscription_id is not null) as n_both,
            count_if(k.subscription_id is null) as n_only_ours,
            count_if(o.subscription_id is null) as n_only_key,
            count_if(k.subscription_id is not null and o.subscription_id is not null and (
                o.subscription_status is distinct from k.status or o.plan is distinct from k.plan
                or o.seats is distinct from k.seats or o.billing_frequency is distinct from k.billing_frequency
                or o.mrr_cents is distinct from k.mrr_cents)) as n_state_diffs,
            count_if(k.subscription_id is not null and o.subscription_id is not null
                and o.movement_type is distinct from k.movement_type) as n_movement_diffs
        from fct_subscription_months as o
        full join key_mrr_monthly as k
            on o.subscription_id = k.subscription_id and o.month_end_date_et = k.month_end_date
        """,
    )
    show(
        db,
        "Rows only in our month-end MRR, by status (B)",
        """
        select o.subscription_status, o.movement_type, count(*) as n_rows, sum(o.mrr_cents) as mrr_cents
        from fct_subscription_months as o
        anti join key_mrr_monthly as k
            on o.subscription_id = k.subscription_id and o.month_end_date_et = k.month_end_date
        group by all order by n_rows desc
        """,
    )
    db.execute(
        """
        create view our_monthly as
        with trial_starts as (
            select trial_start_month_et as month_start, count(*) as n from fct_trials group by 1
        ),
        conversions as (
            select date_trunc('month', timezone('America/New_York', converted_at))::date as month_start,
                count(*) as n
            from fct_trials where trial_outcome = 'converted' group by 1
        )
        select strftime(b.month_start_date_et, '%Y-%m') as ym,
            coalesce(ts.n, 0) as trial_starts,
            coalesce(cv.n, 0) as conversions,
            b.reactivated_subscriptions as reactivations,
            b.voluntarily_churned_subscriptions as churn_cancelled,
            b.involuntarily_churned_subscriptions as churn_lapsed,
            b.starting_subscriptions as starting_active_subscriptions,
            b.ending_subscriptions as ending_active_subscriptions,
            b.ending_mrr_cents as total_mrr_cents
        from fct_mrr_bridge as b
        left join trial_starts as ts on ts.month_start = b.month_start_date_et
        left join conversions as cv on cv.month_start = b.month_start_date_et
        """
    )
    columns = [
        "trial_starts", "conversions", "reactivations", "churn_cancelled", "churn_lapsed",
        "starting_active_subscriptions", "ending_active_subscriptions", "total_mrr_cents",
    ]  # fmt: skip
    diffs = ", ".join(f"count_if(o.{c} is distinct from k.{c}) as {c}" for c in columns)
    show(
        db,
        "Monthly summary: months differing per column (known: churn_lapsed, C)",
        f"""
        select count(*) as n_months_both, {diffs}
        from our_monthly as o
        join (select "month" as ym, * exclude ("month") from key_monthly_summary) as k using (ym)
        """,
    )
    show(
        db,
        "Churn events (known: lapse reason is a different column, D)",
        """
        select count_if(o.subscription_id is not null and k.subscription_id is not null) as n_both,
            count_if(k.subscription_id is null) as n_only_ours,
            count_if(o.subscription_id is null) as n_only_key,
            count_if(o.end_reason is distinct from k.churn_type) as n_type_diffs,
            count_if(o.ended_at is distinct from k.effective_at) as n_effective_diffs,
            count_if(k.churn_type = 'cancelled' and o.cancel_requested_at is distinct from k.requested_at)
                as n_requested_diffs
        from (select * from dim_subscriptions where end_reason in ('cancelled', 'lapsed')) as o
        full join key_churn_events as k using (subscription_id)
        """,
    )
    show(
        db,
        "Seeded anomalies: records kept in staging (remove types should keep 0 records and all related)",
        """
        with kept as (select id from stg_event_ids union all select id from stg_payment_ids)
        select anomaly_type, count(*) as n,
            count_if(record_id in (select id from kept)) as n_record_kept,
            count_if(related_record_id in (select id from kept)) as n_related_kept
        from key_seeded_anomalies group by 1 order by 1
        """,
    )
    show(
        db,
        "Payments double load (expect raw - staged = 209)",
        "select (select n from raw_payments) as raw_rows, (select count(*) from stg_payment_ids) as staged_rows",
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--database", default="ANALYTICS")
    parser.add_argument("--schema", help="one schema holding every model (dev and CI); default: MARTS and STAGING")
    args = parser.parse_args()

    db = duckdb.connect()
    db.execute("set timezone = 'UTC'")
    print(f"Reading models from {args.database}")
    load_ours(db, args.database, args.schema or "MARTS", args.schema or "STAGING")
    load_truth(db)
    compare(db)


if __name__ == "__main__":
    main()
