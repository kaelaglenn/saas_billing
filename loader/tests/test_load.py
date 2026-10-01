"""Load a small generated dataset into DuckDB to check the loader without warehouse credentials."""

import duckdb
import pyarrow.parquet as pq
import pytest

from billing_generator.cli import generate, load_config, write
from raw_loader.load import TABLES, main


@pytest.fixture(scope="module")
def loaded(tmp_path_factory):
    root = tmp_path_factory.mktemp("load")
    raw_dir, db = root / "raw", root / "billing_raw.duckdb"
    write(generate(load_config(scale=0.02))["raw"], raw_dir, csv=False)
    with pytest.MonkeyPatch.context() as mp:
        mp.setenv("DESTINATION__DUCKDB__CREDENTIALS", str(db))
        exit_code = main(["--data-dir", str(raw_dir), "--destination", "duckdb",
                          "--pipelines-dir", str(root / "state")])
    return exit_code, raw_dir, duckdb.connect(str(db), read_only=True)


def test_load_succeeds_with_matching_row_counts(loaded):
    exit_code, _, _ = loaded
    assert exit_code == 0


def test_all_tables_present(loaded):
    _, _, con = loaded
    names = {r[0] for r in con.execute(
        "select table_name from information_schema.tables where table_schema = 'billing'").fetchall()}
    assert set(TABLES) <= names


def test_timestamp_quirk_survives_load(loaded):
    _, _, con = loaded
    types = dict(con.execute(
        "select table_name || '.' || column_name, data_type from information_schema.columns "
        "where table_schema = 'billing'"
    ).fetchall())
    assert types["accounts.created_at"] == "TIMESTAMP"  # naive local ET, as in the source
    assert types["subscription_events.requested_at"] == "TIMESTAMP WITH TIME ZONE"


def test_source_duplicates_are_loaded_as_is(loaded):
    _, raw_dir, con = loaded
    ids = pq.read_table(raw_dir / "payments.parquet", columns=["payment_id"]).column(0).to_pylist()
    expected = len(ids) - len(set(ids))
    loaded_dupes = con.execute("select count(*) - count(distinct payment_id) from billing.payments").fetchone()[0]
    assert expected > 0 and loaded_dupes == expected
