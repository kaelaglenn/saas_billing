"""Integrity checks on the clean raw tables (hard) and calibration targets (soft)."""

from __future__ import annotations

import json
from dataclasses import dataclass

import pandas as pd

from .simulate import Simulator

DECREASE_DIRECTIONS = {"decrease", "downgrade", "switch"}


@dataclass
class Check:
    name: str
    passed: bool
    detail: str
    hard: bool = True


def _price_lookup(sim: Simulator, plan: pd.Series, frequency: pd.Series) -> pd.Series:
    return pd.Series([sim.price(p, f) for p, f in zip(plan, frequency)], index=plan.index)


def integrity_checks(sim: Simulator, raw: dict[str, pd.DataFrame]) -> list[Check]:
    subs, events = raw["subscriptions"], raw["subscription_events"]
    invoices, lines, payments = raw["invoices"], raw["invoice_line_items"], raw["payments"]
    checks = []

    # 1. Amounts reconcile, and only annual subscriptions pay by invoice.
    line_sum = lines.groupby("invoice_id")["amount_cents"].sum()
    due = invoices.set_index("invoice_id")["amount_due_cents"]
    bad_totals = (due != line_sum.reindex(due.index)).sum()
    checks.append(Check("invoice amount_due = sum of line items", bad_totals == 0, f"{bad_totals} mismatches"))

    expected = subs["seats"] * _price_lookup(sim, subs["plan"], subs["billing_frequency"])
    bad_subs = (subs["subscription_amount_cents"] != expected).sum()
    attrs = events["attributes"].map(json.loads)
    full_state = events["event_type"].isin(["subscription_imported", "subscription_started", "renewed"])
    ev = pd.DataFrame(list(attrs[full_state]), index=events.index[full_state])
    ev_expected = ev["seats"] * _price_lookup(sim, ev["plan"], ev["billing_frequency"])
    bad_events = (events.loc[full_state, "subscription_amount_cents"] != ev_expected).sum()
    checks.append(Check("subscription_amount_cents = seats x per-seat price",
                        bad_subs + bad_events == 0, f"{bad_subs} subscriptions, {bad_events} events"))

    monthly_invoice_subs = ((subs["billing_frequency"] == "monthly") & (subs["payment_method"] == "invoice")).sum()
    invoice_lines = lines.merge(invoices[["invoice_id", "payment_method"]], on="invoice_id")
    monthly_invoice_lines = ((invoice_lines["payment_method"] == "invoice")
                             & (invoice_lines["billing_frequency"] == "monthly")).sum()
    checks.append(Check("no monthly subscription pays by invoice",
                        monthly_invoice_subs + monthly_invoice_lines == 0,
                        f"{monthly_invoice_subs} subscriptions, {monthly_invoice_lines} invoice lines"))

    # 2. Succeeded payments never exceed the amount due.
    paid = payments[payments["status"] == "succeeded"].groupby("invoice_id")["amount_cents"].sum()
    overpaid = (paid > invoices.set_index("invoice_id")["amount_due_cents"].reindex(paid.index)).sum()
    checks.append(Check("succeeded payments <= amount due", overpaid == 0, f"{overpaid} overpaid invoices"))

    # 3. No events after a subscription ends.
    ended = events.merge(subs[["subscription_id", "ended_at"]], on="subscription_id")
    late_events = (ended["requested_at"] > ended["ended_at"]).sum()
    checks.append(Check("no events after ended_at", late_events == 0, f"{late_events} events"))

    # 4. At most one live subscription per account at any moment.
    life = subs.assign(begin=subs["trial_started_at"].fillna(subs["started_at"]),
                       finish=subs["ended_at"].fillna(pd.Timestamp.max.tz_localize("UTC")))
    life = life.sort_values(["account_id", "begin"])
    prev_finish = life.groupby("account_id")["finish"].shift()
    overlaps = (life["begin"] < prev_finish).sum()
    checks.append(Check("no account has two live subscriptions", overlaps == 0, f"{overlaps} overlaps"))

    # 5. Each plan_updated changes one dimension; scheduled changes land on a period end.
    updates = events[events["event_type"] == "plan_updated"]
    upd_attrs = attrs[updates.index]
    multi = sum(
        len({k.split("_", 1)[1] for k in a if k.startswith(("from_", "to_"))}) != 1
        or a["change_type"] not in {"plan", "seats", "billing_frequency"}
        or f"to_{a['change_type']}" not in a
        for a in upd_attrs
    )
    checks.append(Check("plan_updated changes exactly one dimension", multi == 0, f"{multi} events"))

    scheduled = updates[[a["direction"] in DECREASE_DIRECTIONS for a in upd_attrs]]
    renewals = set(zip(events.loc[events["event_type"] == "renewed", "subscription_id"],
                       events.loc[events["event_type"] == "renewed", "effective_at"]))
    sub_end = subs.set_index("subscription_id")
    end_ts = pd.Timestamp(sim.end)
    bad_schedule = 0
    for sub_id, eff in zip(scheduled["subscription_id"], scheduled["effective_at"]):
        row = sub_end.loc[sub_id]
        on_boundary = eff == eff.normalize()
        landed = ((sub_id, eff) in renewals
                  or (row["status"] == "cancelled" and row["ended_at"] == eff)
                  or (row["status"] == "lapsed" and row["ended_at"] < eff)
                  or eff >= end_ts)
        bad_schedule += not (on_boundary and landed)
    checks.append(Check("scheduled decreases take effect at a period end", bad_schedule == 0,
                        f"{bad_schedule} of {len(scheduled)} scheduled changes"))
    return checks


def target_checks(sim: Simulator, summary: pd.DataFrame) -> list[Check]:
    t = sim.cfg["targets"]
    scale = sim.cfg["scale"]
    checks = []
    ending = summary["ending_active_subscriptions"].iloc[-1]
    lo, hi = (v * scale for v in t["ending_active_subscriptions"])
    checks.append(Check("ending active subscriptions", lo <= ending <= hi,
                        f"{ending:,} (target {lo:,.0f}-{hi:,.0f})", hard=False))
    churned = (summary["churn_cancelled"] + summary["churn_lapsed"]).sum()
    churn = churned / summary["starting_active_subscriptions"].sum()
    lo, hi = t["blended_monthly_logo_churn"]
    checks.append(Check("blended monthly logo churn", lo <= churn <= hi,
                        f"{churn:.2%} (target {lo:.1%}-{hi:.1%})", hard=False))
    share = summary["churn_lapsed"].sum() / churned
    lo, hi = t["involuntary_share_of_churn"]
    checks.append(Check("involuntary share of churn", lo <= share <= hi,
                        f"{share:.1%} (target {lo:.0%}-{hi:.0%})", hard=False))
    dst = sum(n["anomaly_type"] == "dst_repeated_hour_change" for n in sim.notes)
    checks.append(Check("plan changes inside the repeated November ET hour", dst > 0, f"{dst} events",
                        hard=False))
    return checks
