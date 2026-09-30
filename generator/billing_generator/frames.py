"""Turn simulator state into the six raw source tables (clean, before messiness)."""

from __future__ import annotations

import json
from datetime import datetime

import pandas as pd

from .simulate import Simulator

TIMESTAMP_COLUMNS = {
    "subscriptions": ["trial_started_at", "started_at", "current_period_start", "current_period_end",
                      "cancel_requested_at", "ended_at", "updated_at"],
    "subscription_events": ["requested_at", "effective_at", "ingested_at"],
    "invoices": ["issued_at", "due_at"],
    "invoice_line_items": ["service_period_start", "service_period_end"],
    "payments": ["attempted_at"],
}


def _json_default(value):
    if isinstance(value, datetime):
        return value.strftime("%Y-%m-%dT%H:%M:%SZ")
    raise TypeError(type(value))


def _utc(frame: pd.DataFrame, columns: list[str]) -> pd.DataFrame:
    for col in columns:
        frame[col] = pd.to_datetime(frame[col], utc=True)
    return frame


def _invoice_status(inv: dict, as_of: datetime) -> str:
    if inv["status"] in ("uncollectible", "paid"):
        return inv["status"]
    if as_of > inv["due_at"]:
        return "past_due"
    return "partially_paid" if inv["paid_cents"] > 0 else "open"


def build_raw(sim: Simulator) -> dict[str, pd.DataFrame]:
    accounts = pd.DataFrame(list(sim.accounts.values()))
    for col in ("created_at", "updated_at"):  # source quirk: naive local ET, no offset
        accounts[col] = (pd.to_datetime(accounts[col], utc=True)
                         .dt.tz_convert(sim.tz).dt.tz_localize(None).dt.floor("s"))

    subscriptions = pd.DataFrame([
        {
            "subscription_id": s.subscription_id,
            "account_id": s.account_id,
            "status": s.status,
            "plan": s.plan,
            "seats": s.seats,
            "billing_frequency": s.billing_frequency,
            "subscription_amount_cents": sim.amount(s),
            "payment_method": s.payment_method,
            "trial_started_at": s.trial_started_at,
            "started_at": s.started_at,
            "current_period_start": s.current_period_start,
            "current_period_end": s.current_period_end,
            "cancel_requested_at": s.cancel_requested_at,
            "ended_at": s.ended_at,
            "updated_at": s.updated_at,
        }
        for s in sim.subs.values()
    ])

    events = pd.DataFrame(sim.events)
    events["attributes"] = [json.dumps(a, sort_keys=True, default=_json_default) for a in events["attributes"]]
    events["subscription_amount_cents"] = events["subscription_amount_cents"].astype("Int64")

    invoices = pd.DataFrame([
        {**{k: v for k, v in inv.items() if k != "paid_cents"}, "status": _invoice_status(inv, sim.end)}
        for inv in sim.invoices.values()
    ])
    line_items = pd.DataFrame(sim.line_items)
    payments = pd.DataFrame(sim.payments)
    payments["attempt_number"] = payments["attempt_number"].astype("Int64")

    raw = {
        "accounts": accounts,
        "subscriptions": subscriptions,
        "subscription_events": events,
        "invoices": invoices,
        "invoice_line_items": line_items,
        "payments": payments,
    }
    for table, cols in TIMESTAMP_COLUMNS.items():
        _utc(raw[table], cols)
    return raw
