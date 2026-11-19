"""Export the data behind the charts on the portfolio case-study page (kaelaglenn.com/projects/saas-billing).

Reads production marts (read only) and writes one small JSON file per chart. The page's build turns them into
SVG charts, so the published site never queries Snowflake: it keeps working, at no cost, when the warehouse is
suspended. The page is declared as the `portfolio_case_study` exposure in transform/models/exposures.yml.

Business rules stay in dbt. These queries only select and count what the marts already define (trial maturity,
dunning outcomes, month-end MRR movements), so every number on the page traces back to a tested model.

    uv run python scripts/export_site_charts.py --out ../kaelaglenn-site/content/saas-billing

Output is deterministic (sorted keys, no export timestamp): re-exporting unchanged data produces no diff.
"""

from __future__ import annotations

import argparse
import json
from datetime import date, datetime
from decimal import Decimal
from pathlib import Path

from _snowflake import connect

CHARTS = {
    "mrr_bridge": {
        "source": "marts.fct_mrr_bridge",
        "description": "Monthly MRR movements, month-end to month-end. The opening month has no movements.",
        "sql": """
            select month_label, is_opening_balance, is_month_closed,
                starting_mrr_cents, new_mrr_cents, expansion_mrr_cents, reactivation_mrr_cents,
                contraction_mrr_cents, churned_mrr_cents, net_new_mrr_cents, ending_mrr_cents,
                starting_subscriptions, new_subscriptions, reactivated_subscriptions, churned_subscriptions,
                ending_subscriptions
            from marts.fct_mrr_bridge
            order by month_start_date_et
        """,
    },
    "trial_conversion": {
        "source": "marts.fct_trials",
        "description": (
            "Trials by start month. Conversion rate counts matured trials only (ADR 0003); a cohort is complete "
            "once every trial in it has matured."
        ),
        "sql": """
            select start_month, trials, matured_trials, converted_matured_trials,
                matured_trials = trials as is_cohort_matured,
                round(converted_matured_trials / nullif(matured_trials, 0), 4) as conversion_rate
            from (
                select to_char(trial_start_month_et, 'YYYY-MM') as start_month,
                    count(*) as trials,
                    count_if(is_matured) as matured_trials,
                    count_if(is_matured and trial_outcome = 'converted') as converted_matured_trials
                from marts.fct_trials
                group by 1
            )
            order by start_month
        """,
    },
    "dunning_outcomes": {
        "source": "marts.fct_card_dunning_cases",
        "description": "Card invoices whose first charge failed, by how the case ended.",
        "sql": """
            select
                case
                    when dunning_outcome = 'recovered_on_retry' then 'retry_day_' || days_to_recover
                    else dunning_outcome
                end as outcome,
                count(*) as cases
            from marts.fct_card_dunning_cases
            group by 1
            order by cases desc
        """,
    },
    "headline": {
        "source": "marts: dim_subscriptions, dim_accounts, fct_invoices, fct_payments, dim_subscription_history, "
        "fct_mrr_bridge",
        "description": "Counts for the page's headline stats.",
        "sql": """
            select
                (select count(*) from marts.dim_subscriptions) as subscriptions,
                (select count(*) from marts.dim_accounts) as accounts,
                (select count(*) from marts.fct_invoices) as invoices,
                (select count(*) from marts.fct_payments) as payment_attempts,
                (select count(*) from marts.dim_subscription_history) as subscription_history_rows,
                (select max(month_label) from marts.fct_mrr_bridge where is_month_closed) as latest_closed_month,
                (select ending_mrr_cents from marts.fct_mrr_bridge where is_month_closed
                    order by month_start_date_et desc limit 1) as latest_closed_month_mrr_cents,
                (select min(month_label) from marts.fct_mrr_bridge where not is_opening_balance)
                    as first_reported_month,
                (select max(month_label) from marts.fct_mrr_bridge) as last_reported_month
        """,
    },
}


def to_json_value(value):
    if isinstance(value, Decimal):
        return int(value) if value == value.to_integral_value() else float(value)
    if isinstance(value, (date, datetime)):
        return value.isoformat()
    return value


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", required=True, type=Path, help="folder to write <chart>.json into")
    parser.add_argument("--database", default="ANALYTICS")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)

    conn = connect(args.database)
    try:
        for name, chart in CHARTS.items():
            cursor = conn.cursor().execute(chart["sql"])
            columns = [c[0].lower() for c in cursor.description]
            rows = [{col: to_json_value(v) for col, v in zip(columns, row)} for row in cursor.fetchall()]
            data = {"values": rows[0]} if name == "headline" else {"rows": rows}
            payload = {"source": chart["source"], "description": chart["description"], **data}
            path = args.out / f"{name}.json"
            path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
            print(f"  wrote {path} ({len(rows)} rows)")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
