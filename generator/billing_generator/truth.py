"""Ground-truth answer key built from the simulator's own state history (never from raw tables)."""

from __future__ import annotations

import pandas as pd

from .simulate import Simulator

STATE_COLUMNS = ["status", "plan", "seats", "billing_frequency"]


def subscription_history(sim: Simulator) -> pd.DataFrame:
    """True SCD Type 2 ranges of plan, seats, frequency, and status per subscription."""
    hist = pd.DataFrame(
        sim.history,
        columns=["subscription_id", "account_id", "valid_from", *STATE_COLUMNS, "mrr_cents"],
    )
    hist["valid_from"] = pd.to_datetime(hist["valid_from"], utc=True)
    hist["_order"] = range(len(hist))
    hist = hist.sort_values(["subscription_id", "valid_from", "_order"])
    # Several changes at one instant (e.g. conversion then an immediate card failure) keep the last.
    hist = hist.drop_duplicates(["subscription_id", "valid_from"], keep="last")
    same_as_prev = (hist[STATE_COLUMNS] == hist.groupby("subscription_id")[STATE_COLUMNS].shift()).all(axis=1)
    hist = hist[~same_as_prev].drop(columns="_order")
    hist["valid_to"] = hist.groupby("subscription_id")["valid_from"].shift(-1)
    hist["is_current"] = hist["valid_to"].isna()
    return hist.reset_index(drop=True)


def month_cutoffs(sim: Simulator) -> list[tuple[pd.Period, pd.Timestamp]]:
    """(reporting month, first instant of the next month in reporting tz, as UTC)."""
    months = pd.period_range(sim.start.strftime("%Y-%m"), sim.last_day.strftime("%Y-%m"), freq="M")
    return [
        (m, pd.Timestamp((m + 1).start_time.date(), tz=sim.tz).tz_convert("UTC"))
        for m in months
    ]


def _state_at(hist: pd.DataFrame, cutoff: pd.Timestamp, inclusive: bool = False) -> pd.DataFrame:
    mask = hist["valid_from"] <= cutoff if inclusive else hist["valid_from"] < cutoff
    return hist[mask].groupby("subscription_id").tail(1).set_index("subscription_id")


def mrr_monthly(sim: Simulator, hist: pd.DataFrame) -> pd.DataFrame:
    """One row per subscription per reporting month-end where MRR is non-zero now or last month.

    The first month compares against the imported opening state on Jan 1, 2024.
    """
    reactivations = {s.subscription_id for s in sim.subs.values() if s.is_reactivation}
    prev = _state_at(hist, pd.Timestamp(sim.start), inclusive=True)["mrr_cents"]
    frames = []
    for month, cutoff in month_cutoffs(sim):
        snap = _state_at(hist, cutoff)
        cur = snap["mrr_cents"]
        ids = cur.index.union(prev.index)
        frame = snap.reindex(ids)[["account_id", *STATE_COLUMNS]].copy()
        frame["previous_mrr_cents"] = prev.reindex(ids).fillna(0).astype(int)
        frame["mrr_cents"] = cur.reindex(ids).fillna(0).astype(int)
        frame = frame[(frame["mrr_cents"] > 0) | (frame["previous_mrr_cents"] > 0)]
        frame.insert(0, "month_end_date", month.end_time.date())
        before, after = frame["previous_mrr_cents"], frame["mrr_cents"]
        started = (before == 0) & (after > 0)
        frame["movement_type"] = "unchanged"
        frame.loc[after > before, "movement_type"] = "expansion"
        frame.loc[after < before, "movement_type"] = "contraction"
        frame.loc[started, "movement_type"] = "new"
        frame.loc[started & frame.index.isin(reactivations), "movement_type"] = "reactivation"
        frame.loc[(before > 0) & (after == 0), "movement_type"] = "churn"
        frame["mrr_change_cents"] = after - before
        frames.append(frame.reset_index(names="subscription_id"))
        prev = cur
    out = pd.concat(frames, ignore_index=True)
    out["seats"] = out["seats"].astype(int)
    return out


def churn_events(sim: Simulator) -> pd.DataFrame:
    churn = pd.DataFrame(sim.churn)
    for col in ("requested_at", "effective_at"):
        churn[col] = pd.to_datetime(churn[col], utc=True)
    churn["effective_date_reporting_tz"] = churn["effective_at"].dt.tz_convert(sim.tz).dt.date
    return churn


def monthly_summary(sim: Simulator, mrr: pd.DataFrame, churn: pd.DataFrame) -> pd.DataFrame:
    def et_month(series: pd.Series) -> pd.Series:
        return pd.to_datetime(series, utc=True).dt.tz_convert(sim.tz).dt.tz_localize(None).dt.to_period("M")

    subs = pd.DataFrame([
        {"trial_started_at": s.trial_started_at, "started_at": s.started_at, "is_reactivation": s.is_reactivation}
        for s in sim.subs.values()
    ])
    months = [m for m, _ in month_cutoffs(sim)]
    trials = et_month(subs["trial_started_at"].dropna()).value_counts()
    converted = subs[subs["trial_started_at"].notna() & subs["started_at"].notna()]
    conversions = et_month(converted["started_at"]).value_counts()
    reactivations = et_month(subs.loc[subs["is_reactivation"], "started_at"]).value_counts()
    churn_month = et_month(churn["effective_at"])
    cancelled = churn_month[churn["churn_type"] == "cancelled"].value_counts()
    lapsed = churn_month[churn["churn_type"] == "lapsed"].value_counts()

    live = mrr[mrr["mrr_cents"] > 0]
    live_month = pd.PeriodIndex(pd.to_datetime(live["month_end_date"]), freq="M")
    ending = live.groupby(live_month).size()
    total_mrr = live.groupby(live_month)["mrr_cents"].sum()

    summary = pd.DataFrame({"month": months}).set_index("month")
    for name, series in [("trial_starts", trials), ("conversions", conversions),
                         ("reactivations", reactivations), ("churn_cancelled", cancelled),
                         ("churn_lapsed", lapsed), ("ending_active_subscriptions", ending),
                         ("total_mrr_cents", total_mrr)]:
        summary[name] = series.reindex(summary.index).fillna(0).astype(int)
    opening = sum(1 for s in sim.subs.values() if s.trial_started_at is None and not s.is_reactivation)
    summary["starting_active_subscriptions"] = (
        summary["ending_active_subscriptions"].shift(1).fillna(opening).astype(int)
    )
    churned = summary["churn_cancelled"] + summary["churn_lapsed"]
    summary["logo_churn_rate"] = (churned / summary["starting_active_subscriptions"]).round(4)
    summary["involuntary_share_of_churn"] = (summary["churn_lapsed"] / churned.where(churned > 0)).round(4)
    summary = summary.reset_index()
    summary["month"] = summary["month"].astype(str)
    return summary


def build_truth(sim: Simulator) -> dict[str, pd.DataFrame]:
    hist = subscription_history(sim)
    mrr = mrr_monthly(sim, hist)
    churn = churn_events(sim)
    return {
        "subscription_history": hist,
        "mrr_monthly": mrr,
        "churn_events": churn,
        "monthly_summary": monthly_summary(sim, mrr, churn),
    }
