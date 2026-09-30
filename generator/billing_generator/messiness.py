"""Inject data-quality problems into the raw tables only, logging every record touched.

Runs after validation, on its own random stream, so the simulation and ground truth are unaffected.
"""

from __future__ import annotations

import numpy as np
import pandas as pd


def inject(raw: dict[str, pd.DataFrame], cfg: dict) -> tuple[dict[str, pd.DataFrame], list[dict]]:
    m = cfg["messiness"]
    rng = np.random.default_rng([cfg["seed"], 1])
    out = dict(raw)
    anomalies: list[dict] = []

    events = raw["subscription_events"].copy()
    n = len(events)
    picks = rng.permutation(n)
    n_late = round(n * m["late_arrival_rate"])
    n_dup = round(n * m["event_duplicate_rate"])
    late_idx, dup_idx = picks[:n_late], picks[n_late:n_late + n_dup]

    # Late arrival: ingested 1-5 days after the customer acted.
    lo, hi = m["late_arrival_days"]
    late_lag = pd.to_timedelta(rng.uniform(lo * 86400, hi * 86400, size=n_late).astype(int), unit="s")
    rows = events.index[late_idx]
    events.loc[rows, "ingested_at"] = events.loc[rows, "requested_at"] + pd.Series(late_lag, index=rows)
    anomalies += [
        {"anomaly_type": "late_arriving_event", "table_name": "subscription_events", "record_id": eid,
         "related_record_id": None, "detail": f"ingested {lag} after requested_at"}
        for eid, lag in zip(events.loc[rows, "event_id"], late_lag)
    ]

    # Retried webhooks: same payload, new event_id, ingested seconds to hours later.
    dups = events.iloc[np.sort(dup_idx)].copy()
    next_id = int(events["event_id"].str[4:].astype(int).max()) + 1
    dups["event_id"] = [f"evt_{i:07d}" for i in range(next_id, next_id + len(dups))]
    lo, hi = m["event_duplicate_delay_seconds"]
    dups["ingested_at"] = dups["ingested_at"] + pd.to_timedelta(rng.integers(lo, hi, size=len(dups)), unit="s")
    anomalies += [
        {"anomaly_type": "duplicate_event_retried_webhook", "table_name": "subscription_events",
         "record_id": new, "related_record_id": old, "detail": "re-emitted with a new event_id; remove"}
        for new, old in zip(dups["event_id"], events.iloc[np.sort(dup_idx)]["event_id"])
    ]
    out["subscription_events"] = (pd.concat([events, dups]).sort_values(["ingested_at", "event_id"])
                                  .reset_index(drop=True))

    # Double-loaded payments: identical rows, same payment_id.
    payments = raw["payments"]
    n_pay = round(len(payments) * m["payment_double_load_rate"])
    doubled = payments.iloc[np.sort(rng.choice(len(payments), size=n_pay, replace=False))]
    anomalies += [
        {"anomaly_type": "duplicate_payment_double_load", "table_name": "payments", "record_id": pid,
         "related_record_id": pid, "detail": "identical row loaded twice; remove"}
        for pid in doubled["payment_id"]
    ]
    out["payments"] = (pd.concat([payments, doubled]).sort_values(["attempted_at", "payment_id"], kind="stable")
                       .reset_index(drop=True))
    return out, anomalies
