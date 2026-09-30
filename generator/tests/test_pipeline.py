"""End-to-end checks on a small-scale run. Each stage of the pipeline is tested separately."""

import json

import pandas as pd
import pytest

from billing_generator.cli import generate, load_config

SCALE = 0.05


@pytest.fixture(scope="module")
def result():
    return generate(load_config(scale=SCALE))


def test_integrity_checks_pass(result):
    failed = [c for c in result["checks"] if c.hard and not c.passed]
    assert not failed, failed


def test_deterministic(result):
    again = generate(load_config(scale=SCALE))
    for name, frame in result["raw"].items():
        pd.testing.assert_frame_equal(frame, again["raw"][name])
    for name, frame in result["truth"].items():
        pd.testing.assert_frame_equal(frame, again["truth"][name])


def test_different_seed_changes_output(result):
    other = generate(load_config(scale=SCALE, seed=7))
    assert not result["raw"]["subscriptions"].equals(other["raw"]["subscriptions"])


def test_amounts_are_integer_cents(result):
    raw = result["raw"]
    for table, col in [("invoices", "amount_due_cents"), ("invoice_line_items", "amount_cents"),
                       ("payments", "amount_cents"), ("subscriptions", "subscription_amount_cents")]:
        assert pd.api.types.is_integer_dtype(raw[table][col]), (table, col)


def test_accounts_are_naive_and_other_tables_utc(result):
    raw = result["raw"]
    assert raw["accounts"]["created_at"].dt.tz is None
    assert str(raw["subscription_events"]["requested_at"].dt.tz) == "UTC"


def test_mrr_bridge_reconciles(result):
    mrr = result["truth"]["mrr_monthly"]
    totals = mrr.groupby("month_end_date")["mrr_cents"].sum()
    changes = mrr.groupby("month_end_date")["mrr_change_cents"].sum()
    assert (totals.diff().iloc[1:] == changes.iloc[1:]).all()


def test_mrr_uses_annual_divided_by_twelve(result):
    mrr = result["truth"]["mrr_monthly"]
    annual = mrr[(mrr["billing_frequency"] == "annual") & (mrr["mrr_cents"] > 0)]
    per_seat = (annual["mrr_cents"] / annual["seats"]).unique()
    assert set(per_seat) <= {20520 / 12, 31320 / 12}


def test_history_ranges_do_not_overlap(result):
    hist = result["truth"]["subscription_history"]
    nxt = hist.groupby("subscription_id")["valid_from"].shift(-1)
    assert (hist["valid_to"].dropna() == nxt.dropna()).all()
    assert hist.groupby("subscription_id")["is_current"].sum().eq(1).all()


def test_messiness_matches_manifest(result):
    clean, raw = result["clean"], result["raw"]
    anomalies = result["truth"]["seeded_anomalies"]
    counts = anomalies["anomaly_type"].value_counts()
    assert len(raw["subscription_events"]) - len(clean["subscription_events"]) == counts[
        "duplicate_event_retried_webhook"]
    assert len(raw["payments"]) - len(clean["payments"]) == counts["duplicate_payment_double_load"]
    assert raw["payments"]["payment_id"].duplicated().sum() == counts["duplicate_payment_double_load"]


def test_duplicate_events_match_their_originals(result):
    events = result["raw"]["subscription_events"].set_index("event_id")
    dups = result["truth"]["seeded_anomalies"].query("anomaly_type == 'duplicate_event_retried_webhook'")
    same = ["subscription_id", "event_type", "requested_at", "effective_at", "attributes"]
    for new, old in zip(dups["record_id"], dups["related_record_id"]):
        assert events.loc[new, same].equals(events.loc[old, same])
        assert events.loc[new, "ingested_at"] > events.loc[old, "ingested_at"]


def test_lookalike_increases_are_distinct_and_billed(result):
    events = result["clean"]["subscription_events"].set_index("event_id")
    looks = result["truth"]["seeded_anomalies"].query("anomaly_type == 'legit_lookalike_seat_increase'")
    for new, old in zip(looks["record_id"], looks["related_record_id"]):
        a, b = events.loc[old], events.loc[new]
        assert a["requested_at"] < b["requested_at"]
        assert a["requested_at"].date() == b["requested_at"].date()
        assert json.loads(a["attributes"])["seat_delta"] == json.loads(b["attributes"])["seat_delta"]


def test_raw_does_not_leak_truth(result):
    assert not set(result["raw"]) & set(result["truth"])
