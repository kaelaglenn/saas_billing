"""Load data/raw/*.parquet into the RAW database (schema BILLING) and verify row counts.

Every run replaces the tables: the generator always rewrites the full history, so the warehouse should mirror
the files exactly. Duplicates and late-arriving rows are part of the source data and are loaded as-is.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import dlt
import pyarrow as pa
import pyarrow.parquet as pq

TABLES = [
    "accounts",
    "subscriptions",
    "subscription_events",
    "invoices",
    "invoice_line_items",
    "payments",
]


def naive_timestamp_hints(table: pa.Table) -> dict:
    """dlt treats naive timestamps as UTC by default. Keep them naive so the accounts quirk survives the load."""
    return {
        f.name: {"data_type": "timestamp", "timezone": False}
        for f in table.schema
        if pa.types.is_timestamp(f.type) and f.type.tz is None
    }


@dlt.source(name="billing")
def billing_raw(data_dir: Path):
    for table in TABLES:
        arrow = pq.read_table(data_dir / f"{table}.parquet")
        yield dlt.resource(arrow, name=table, write_disposition="replace", columns=naive_timestamp_hints(arrow))


def row_counts(pipeline: dlt.Pipeline) -> dict[str, int]:
    with pipeline.sql_client() as client:
        return {
            table: client.execute_sql(f"SELECT COUNT(*) FROM {client.make_qualified_table_name(table)}")[0][0]
            for table in TABLES
        }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-dir", type=Path, default=Path("data/raw"))
    parser.add_argument("--destination", default="snowflake", help="any dlt destination, e.g. duckdb for local tests")
    parser.add_argument("--dataset", default="billing", help="target schema")
    parser.add_argument("--pipelines-dir", type=Path, help="where dlt keeps local pipeline state")
    args = parser.parse_args(argv)

    missing = [t for t in TABLES if not (args.data_dir / f"{t}.parquet").exists()]
    if missing:
        print(f"Missing {missing} in {args.data_dir}. Run `uv run generate-billing-data` first.", file=sys.stderr)
        return 1

    pipeline = dlt.pipeline(
        pipeline_name="billing_raw",
        destination=args.destination,
        dataset_name=args.dataset,
        pipelines_dir=str(args.pipelines_dir) if args.pipelines_dir else None,
    )
    pipeline.run(billing_raw(args.data_dir))

    expected = {t: pq.ParquetFile(args.data_dir / f"{t}.parquet").metadata.num_rows for t in TABLES}
    loaded = row_counts(pipeline)
    ok = True
    for table in TABLES:
        match = loaded[table] == expected[table]
        ok &= match
        print(f"  [{'PASS' if match else 'FAIL'}] {args.dataset}.{table:<20} {loaded[table]:>9,} rows")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
