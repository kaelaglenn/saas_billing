"""Event-driven, day-by-day simulation of the billing system.

Produces clean data only. Subscription state changes only through events; invoices and payments are
derived from those events. Scheduled work (renewals, trial ends, payment retries, invoice deadlines)
lives in a priority queue; random customer actions are drawn each day and pushed into the same queue
at random times, so everything is processed in strict time order.
"""

from __future__ import annotations

import heapq
import itertools
import math
from dataclasses import dataclass, field
from datetime import date, datetime, time, timedelta
from zoneinfo import ZoneInfo

import numpy as np

from .billing_calendar import (
    DAY,
    UTC,
    add_months,
    midnight,
    next_midnight,
    period_days,
    period_end,
    prorate,
    remaining_days,
)

LIVE_STATUSES = ("active", "past_due")
CHANGE_TYPES = ("add_seats", "remove_seats", "plan_upgrade", "plan_downgrade", "frequency_switch")

ADJECTIVES = [
    "Blue", "Bright", "Cedar", "Clear", "Copper", "Crimson", "Delta", "Evergreen", "Golden", "Granite",
    "Harbor", "Iron", "Juniper", "Lunar", "Maple", "Meridian", "Nimble", "North", "Oak", "Onyx",
    "Pacific", "Pine", "Prairie", "Quantum", "Quiet", "Rapid", "Red", "River", "Silver", "Solar",
    "Stone", "Summit", "Swift", "Tidal", "True", "Union", "Urban", "Vertex", "Willow", "Zenith",
]
NOUNS = [
    "Analytics", "Bridge", "Canopy", "Circuit", "Compass", "Craft", "Dynamics", "Forge", "Foundry",
    "Grove", "Harvest", "Health", "Horizon", "Insights", "Ledger", "Logic", "Metrics", "Mill", "Networks",
    "Orbit", "Partners", "Path", "Peak", "Pixel", "Point", "Retail", "Ridge", "Signal", "Studio",
    "Systems", "Thread", "Works", "Ventures", "Wave", "Yard", "Loop", "Labs", "Supply", "Media", "Hub",
]
FORMS = ["Inc", "LLC", "Co", "Group", "Ltd", "Corp", "Collective", "PBC"]
SIZE_BANDS = [(10, "1-10"), (50, "11-50"), (200, "51-200"), (math.inf, "201+")]


@dataclass
class Subscription:
    subscription_id: str
    account_id: str
    status: str
    plan: str
    seats: int
    billing_frequency: str
    payment_method: str
    is_reactivation: bool = False
    previous_subscription_id: str | None = None
    trial_started_at: datetime | None = None
    started_at: datetime | None = None
    current_period_start: datetime | None = None
    current_period_end: datetime | None = None
    anchor: date | None = None
    period_index: int = 0
    cancel_requested_at: datetime | None = None
    cancel_reason: str | None = None
    ended_at: datetime | None = None
    updated_at: datetime | None = None
    pending: list[dict] = field(default_factory=list)
    delinquent: set[str] = field(default_factory=set)
    open_invoices: set[str] = field(default_factory=set)
    last_state: tuple | None = None


def _counter(prefix: str, width: int):
    it = itertools.count(1)
    return lambda: f"{prefix}_{next(it):0{width}d}"


def _monthly_to_daily(p_month: float) -> float:
    return 1.0 - (1.0 - p_month) ** (12 / 365.25)


class Simulator:
    def __init__(self, cfg: dict):
        self.cfg = cfg
        self.rng = np.random.default_rng(cfg["seed"])
        self.tz = ZoneInfo(cfg["window"]["reporting_timezone"])
        self.start = midnight(date.fromisoformat(cfg["window"]["start_date"]))
        self.last_day = date.fromisoformat(cfg["window"]["end_date"])
        # Data runs through the end of the last day in the reporting timezone.
        self.end = datetime.combine(self.last_day + DAY, time(0), tzinfo=self.tz).astimezone(UTC)
        self.prices = cfg["prices_cents"]

        self._queue: list = []
        self._seq = itertools.count()
        self._acct_id = _counter("acct", 6)
        self._sub_id = _counter("sub", 6)
        self._evt_id = _counter("evt", 7)
        self._inv_id = _counter("inv", 7)
        self._li_id = _counter("li", 7)
        self._pay_id = _counter("pay", 7)

        self.accounts: dict[str, dict] = {}
        self.subs: dict[str, Subscription] = {}
        self.live: dict[str, Subscription] = {}  # paid and not ended (active or past_due)
        self.account_live: dict[str, str | None] = {}
        self.events: list[dict] = []
        self.invoices: dict[str, dict] = {}
        self.line_items: list[dict] = []
        self.payments: list[dict] = []
        self.history: list[tuple] = []
        self.churn: list[dict] = []
        self.notes: list[dict] = []  # simulation-produced records the answer key should call out

        self._trial_volume = self._draw_trial_volume()
        chg = cfg["changes"]
        self._daily_change_p = np.array(
            [
                _monthly_to_daily(chg["add_seats"]),
                _monthly_to_daily(chg["remove_seats"]),
                _monthly_to_daily(chg["plan_upgrade"]),
                _monthly_to_daily(chg["plan_downgrade"]),
                _monthly_to_daily(chg["frequency_switch"]),
            ]
        )
        self._daily_cancel_p = _monthly_to_daily(cfg["churn"]["monthly_voluntary_cancel"])

    # ------------------------------------------------------------------ helpers

    def price(self, plan: str, frequency: str) -> int:
        return self.prices[plan][frequency]

    def mrr(self, sub: Subscription) -> int:
        if sub.status not in LIVE_STATUSES:
            return 0
        if sub.billing_frequency == "monthly":
            return sub.seats * self.price(sub.plan, "monthly")
        return sub.seats * self.price(sub.plan, "annual") // 12

    def amount(self, sub: Subscription) -> int:
        return sub.seats * self.price(sub.plan, sub.billing_frequency)

    def _choice(self, weights: dict) -> str:
        keys = list(weights)
        p = np.array([weights[k] for k in keys], dtype=float)
        return keys[self.rng.choice(len(keys), p=p / p.sum())]

    def _rand_between(self, a: datetime, b: datetime) -> datetime:
        """Random instant in [a, b), to the second."""
        span = int((b - a).total_seconds())
        return a + timedelta(seconds=int(self.rng.integers(0, max(span, 1))))

    def _shock(self, ts: datetime) -> float:
        shock = self.cfg["churn"]["shock"]
        return shock["multiplier"] if ts.astimezone(self.tz).strftime("%Y-%m") in shock["months"] else 1.0

    def _push(self, ts: datetime, kind: str, **payload):
        heapq.heappush(self._queue, (ts, next(self._seq), kind, payload))

    def _draw_trial_volume(self) -> dict:
        t = self.cfg["trials"]
        volume, year_base = {}, {}
        month = self.start.date().replace(day=1)
        while month <= self.last_day:
            if month.year not in year_base:
                r = t["yearly_baseline_range"]
                year_base[month.year] = 1 + self.rng.uniform(-r, r)
            years_in = (month.year - self.start.year) + (month.month - 1) / 12
            noise = max(0.5, self.rng.normal(1.0, t["monthly_noise_sd"]))
            volume[(month.year, month.month)] = (
                t["base_monthly_starts"]
                * self.cfg["scale"]
                * (1 + t["annual_volume_growth"]) ** years_in
                * t["seasonality"][month.month - 1]
                * year_base[month.year]
                * noise
            )
            month = add_months(month, 1)
        return volume

    def _draw_seats(self) -> int:
        s = self.cfg["signup_mix"]["seats"]
        seats = round(self.rng.lognormal(math.log(s["median"]), s["sigma"]))
        return int(min(max(seats, s["min"]), s["max"]))

    def _draw_payment_method(self, frequency: str, seats: int) -> str:
        if frequency == "monthly":
            return "card"
        ip = self.cfg["signup_mix"]["invoice_payment"]
        p = ip["prob_large_account"] if seats >= ip["large_account_min_seats"] else ip["prob_small_account"]
        return "invoice" if self.rng.random() < p else "card"

    def _draw_config(self, premium_share: float, annual_share: float) -> tuple[str, int, str, str]:
        plan = "premium" if self.rng.random() < premium_share else "pro"
        frequency = "annual" if self.rng.random() < annual_share else "monthly"
        seats = self._draw_seats()
        return plan, seats, frequency, self._draw_payment_method(frequency, seats)

    def _seat_delta(self, sub: Subscription) -> int:
        return 1 + int(self.rng.poisson(self.cfg["changes"]["seat_change_size_per_seat"] * sub.seats))

    # ------------------------------------------------------------ record keeping

    def _new_account(self, created_at: datetime, seats: int) -> str:
        acct_id = self._acct_id()
        lo, hi = self.cfg["accounts"]["employees_per_seat"]
        employees = seats * self.rng.uniform(lo, hi)
        band = next(label for limit, label in SIZE_BANDS if employees <= limit)
        name = (
            f"{ADJECTIVES[self.rng.integers(len(ADJECTIVES))]} "
            f"{NOUNS[self.rng.integers(len(NOUNS))]} {FORMS[self.rng.integers(len(FORMS))]}"
        )
        self.accounts[acct_id] = {
            "account_id": acct_id,
            "company_name": name,
            "industry": self._choice(self.cfg["accounts"]["industries"]),
            "company_size_band": band,
            "created_at": created_at,
            "updated_at": created_at,
        }
        self.account_live[acct_id] = None
        return acct_id

    def _new_sub(self, account_id: str, plan: str, seats: int, frequency: str, method: str,
                 status: str, **kwargs) -> Subscription:
        sub = Subscription(self._sub_id(), account_id, status, plan, seats, frequency, method, **kwargs)
        self.subs[sub.subscription_id] = sub
        self.account_live[account_id] = sub.subscription_id
        self._touch_account(account_id, sub.started_at or sub.trial_started_at)
        return sub

    def _touch_account(self, account_id: str, ts: datetime):
        """Accounts rows change only when a subscription starts or ends on them."""
        acct = self.accounts[account_id]
        acct["updated_at"] = max(acct["updated_at"], ts)

    def _record(self, sub: Subscription, ts: datetime):
        """Append a truth-history row whenever plan, seats, frequency, or status changes."""
        sub.updated_at = ts
        state = (sub.status, sub.plan, sub.seats, sub.billing_frequency)
        if state == sub.last_state:
            return
        sub.last_state = state
        self.history.append(
            (sub.subscription_id, sub.account_id, ts, sub.status, sub.plan, sub.seats,
             sub.billing_frequency, self.mrr(sub))
        )

    def _emit(self, sub: Subscription, event_type: str, requested_at: datetime,
              effective_at: datetime, attributes: dict, amount: int | None) -> str:
        event_id = self._evt_id()
        lag = timedelta(seconds=int(1 + self.rng.exponential(20)))
        self.events.append(
            {
                "event_id": event_id,
                "subscription_id": sub.subscription_id,
                "account_id": sub.account_id,
                "event_type": event_type,
                "requested_at": requested_at,
                "effective_at": effective_at,
                "attributes": attributes,
                "ingested_at": requested_at + lag,
                "subscription_amount_cents": amount,
            }
        )
        return event_id

    def _state_attrs(self, sub: Subscription) -> dict:
        return {
            "plan": sub.plan,
            "seats": sub.seats,
            "billing_frequency": sub.billing_frequency,
            "payment_method": sub.payment_method,
            "current_period_start": sub.current_period_start,
            "current_period_end": sub.current_period_end,
        }

    def _projected(self, sub: Subscription) -> tuple[str, int, str]:
        """Plan, seats, frequency at the next renewal given the changes pending today."""
        plan, seats, frequency = sub.plan, sub.seats, sub.billing_frequency
        for change in sub.pending:
            if change["kind"] == "seats":
                seats += change["delta"]
            elif change["kind"] == "plan":
                plan = change["to"]
            else:
                frequency = change["to"]
        return plan, seats, frequency

    # ------------------------------------------------------------------- main loop

    def run(self) -> Simulator:
        self._create_opening_state()
        day = self.start.date()
        while day <= self.last_day:
            self._schedule_trial_starts(day)
            self._schedule_customer_actions(day)
            self._schedule_dst_changes(day)
            self._drain(midnight(day) + DAY)
            day += DAY
        self._drain(self.end)
        return self

    def _drain(self, until: datetime):
        while self._queue and self._queue[0][0] < until:
            ts, _, kind, payload = heapq.heappop(self._queue)
            getattr(self, f"_on_{kind}")(ts, payload)

    # ---------------------------------------------------------------- opening state

    def _create_opening_state(self):
        o = self.cfg["opening_state"]
        created_from = date.fromisoformat(o["account_created_from"])
        created_to = date.fromisoformat(o["account_created_to"])
        n = round(o["active_subscriptions"] * self.cfg["scale"])
        for _ in range(n):
            plan, seats, frequency, method = self._draw_config(o["premium_share"], o["annual_share"])
            months = 1 if frequency == "monthly" else 12
            horizon = 31 if frequency == "monthly" else 366
            current_end = self.start.date() + timedelta(days=int(self.rng.integers(1, horizon + 1)))
            anchor = current_end - DAY  # period index 0 ends at current_end
            # Original start: a whole number of periods before the anchor, after the earliest creation date.
            max_back = 1
            while add_months(anchor, -(max_back + 1) * months) >= created_from + timedelta(days=45):
                max_back += 1
            back = int(self.rng.integers(1, max_back + 1))
            start_day = add_months(anchor, -back * months)
            started_at = midnight(start_day) + timedelta(seconds=int(self.rng.integers(0, 86400)))
            created_at = started_at - timedelta(seconds=int(self.rng.integers(0, 45 * 86400)))
            created_at = min(created_at, midnight(created_to))
            acct = self._new_account(created_at, seats)
            sub = self._new_sub(acct, plan, seats, frequency, method, "active", started_at=started_at)
            sub.anchor, sub.period_index = anchor, 0
            sub.current_period_end = period_end(anchor, 0, frequency)
            sub.current_period_start = started_at if back == 1 else period_end(anchor, -1, frequency)
            self.live[sub.subscription_id] = sub
            # Monthly cancellations already pending at cutover carry over (like cancel_at_period_end).
            elapsed = (self.start - sub.current_period_start) / (sub.current_period_end - sub.current_period_start)
            if frequency == "monthly" and self.rng.random() < self.cfg["churn"]["monthly_voluntary_cancel"] * elapsed:
                sub.cancel_requested_at = self._rand_between(sub.current_period_start, self.start)
                sub.cancel_reason = self._choice(self.cfg["churn"]["cancel_reasons"])
            self._emit(sub, "subscription_imported", self.start, self.start,
                       {**self._state_attrs(sub), "started_at": started_at,
                        "cancel_requested_at": sub.cancel_requested_at, "cancel_reason": sub.cancel_reason},
                       self.amount(sub))
            self._record(sub, self.start)
            self._push(sub.current_period_end, "period_end", sub_id=sub.subscription_id)
            self._maybe_schedule_annual_cancel(sub, self.start)

    # ------------------------------------------------------------ daily scheduling

    def _schedule_trial_starts(self, day: date):
        days_in_month = (add_months(day.replace(day=1), 1) - day.replace(day=1)).days
        lam = self._trial_volume[(day.year, day.month)] / days_in_month
        for _ in range(int(self.rng.poisson(lam))):
            self._push(self._rand_between(midnight(day), midnight(day) + DAY), "trial_start")

    def _schedule_customer_actions(self, day: date):
        subs = list(self.live.values())
        if not subs:
            return
        day_start = midnight(day)
        cancel_p = self._daily_cancel_p * self._shock(day_start + timedelta(hours=12))
        draws = self.rng.random((len(subs), 6))
        hits = draws < np.append(cancel_p, self._daily_change_p)
        for i, j in zip(*np.nonzero(hits)):
            ts = self._rand_between(day_start, day_start + DAY)
            sub_id = subs[i].subscription_id
            if j == 0:
                self._push(ts, "cancel_request", sub_id=sub_id, annual=False)
            else:
                self._push(ts, "change", sub_id=sub_id, type=CHANGE_TYPES[j - 1])

    def _schedule_dst_changes(self, day: date):
        """Force seat increases inside both passes of the repeated 1-2 a.m. ET hour in November."""
        if day.month != 11 or day.weekday() != 6 or day.day > 7:
            return
        candidates = [s for s in self.live.values() if s.cancel_requested_at is None]
        for hour in (5, 6):  # 01:xx EDT = 05:xx UTC, then 01:xx EST = 06:xx UTC
            sub = candidates[int(self.rng.integers(len(candidates)))]
            ts = midnight(day) + timedelta(hours=hour, seconds=int(self.rng.integers(0, 3600)))
            self._push(ts, "change", sub_id=sub.subscription_id, type="add_seats", dst_forced=True)

    # -------------------------------------------------------------------- trials

    def _on_trial_start(self, ts: datetime, p: dict):
        mix = self.cfg["signup_mix"]
        plan, seats, frequency, method = self._draw_config(mix["premium_share"], mix["annual_share"])
        acct = self._new_account(ts, seats)
        sub = self._new_sub(acct, plan, seats, frequency, method, "trialing", trial_started_at=ts)
        trial_end = ts + timedelta(days=self.cfg["trials"]["length_days"])
        sub.current_period_start, sub.current_period_end = ts, trial_end
        self._emit(sub, "trial_started", ts, ts,
                   {"plan": plan, "seats": seats, "billing_frequency": frequency, "trial_ends_at": trial_end},
                   None)
        self._record(sub, ts)
        if self.rng.random() < self.cfg["trials"]["conversion_rate"]:
            self._push(self._rand_between(ts, trial_end), "trial_convert", sub_id=sub.subscription_id)
        else:
            self._push(trial_end, "trial_expire", sub_id=sub.subscription_id)

    def _on_trial_convert(self, ts: datetime, p: dict):
        sub = self.subs[p["sub_id"]]
        sub.status, sub.started_at = "active", ts
        self._begin_paid(sub, ts, {"is_reactivation": False})

    def _on_trial_expire(self, ts: datetime, p: dict):
        sub = self.subs[p["sub_id"]]
        sub.status, sub.ended_at = "trial_expired", ts
        self.account_live[sub.account_id] = None
        self._touch_account(sub.account_id, ts)
        self._emit(sub, "trial_expired", ts, ts, {}, None)
        self._record(sub, ts)

    def _begin_paid(self, sub: Subscription, ts: datetime, attrs: dict):
        """First paid period after a trial conversion or a reactivation. The billing anchor is ts."""
        sub.anchor, sub.period_index = ts.date(), 1
        sub.current_period_start = ts
        sub.current_period_end = period_end(sub.anchor, 1, sub.billing_frequency)
        self.live[sub.subscription_id] = sub
        self._emit(sub, "subscription_started", ts, ts, {**attrs, **self._state_attrs(sub)}, self.amount(sub))
        self._record(sub, ts)
        self._push(sub.current_period_end, "period_end", sub_id=sub.subscription_id)
        self._issue_renewal_invoice(sub, ts)
        self._maybe_schedule_annual_cancel(sub, ts)

    # ------------------------------------------------------------------ renewals

    def _on_period_end(self, ts: datetime, p: dict):
        sub = self.subs[p["sub_id"]]
        if sub.subscription_id not in self.live or sub.current_period_end != ts:
            return
        if sub.cancel_requested_at is not None:
            sub.status, sub.ended_at, sub.pending = "cancelled", ts, []
            self._end(sub, ts, "cancelled", reason=sub.cancel_reason)
            return

        frequency_changed = False
        for change in sub.pending:  # applied in the order requested
            if change["kind"] == "seats":
                sub.seats += change["delta"]
            elif change["kind"] == "plan":
                sub.plan = change["to"]
            else:
                sub.billing_frequency = change["to"]
                frequency_changed = True
                if sub.billing_frequency == "monthly":
                    sub.payment_method = "card"
        sub.pending = []
        assert sub.seats >= 1, sub

        if frequency_changed:  # re-anchor so the new cadence renews at this same midnight
            sub.anchor, sub.period_index = (ts - DAY).date(), 1
        else:
            sub.period_index += 1
        sub.current_period_start = ts
        sub.current_period_end = period_end(sub.anchor, sub.period_index, sub.billing_frequency)
        self._emit(sub, "renewed", ts, ts, self._state_attrs(sub), self.amount(sub))
        self._record(sub, ts)
        self._push(sub.current_period_end, "period_end", sub_id=sub.subscription_id)
        self._issue_renewal_invoice(sub, ts)
        self._maybe_schedule_annual_cancel(sub, ts)

    def _maybe_schedule_annual_cancel(self, sub: Subscription, now: datetime):
        if sub.billing_frequency != "annual":
            return
        p = self.cfg["churn"]["annual_renewal_cancel"] * self._shock(sub.current_period_end)
        if self.rng.random() >= p:
            return
        lo, hi = self.cfg["churn"]["annual_cancel_notice_days"]
        notice = timedelta(days=float(self.rng.uniform(lo, hi)))
        ts = max(sub.current_period_end - notice, now + timedelta(minutes=1))
        if ts < sub.current_period_end:
            self._push(ts, "cancel_request", sub_id=sub.subscription_id, annual=True,
                       period_end=sub.current_period_end)

    # ------------------------------------------------------------- cancellation

    def _on_cancel_request(self, ts: datetime, p: dict):
        sub = self.live.get(p["sub_id"])
        if sub is None or sub.cancel_requested_at is not None:
            return
        if p["annual"] and p["period_end"] != sub.current_period_end:
            return
        if not p["annual"] and sub.billing_frequency != "monthly":
            return
        sub.cancel_requested_at = ts
        sub.cancel_reason = self._choice(self.cfg["churn"]["cancel_reasons"])
        self._emit(sub, "cancelled", ts, sub.current_period_end, {"reason": sub.cancel_reason}, 0)
        self._record(sub, ts)

    def _end(self, sub: Subscription, ts: datetime, churn_type: str, **extra):
        self.live.pop(sub.subscription_id, None)
        self.account_live[sub.account_id] = None
        self._touch_account(sub.account_id, ts)
        self._record(sub, ts)
        self.churn.append(
            {
                "subscription_id": sub.subscription_id,
                "account_id": sub.account_id,
                "churn_type": churn_type,
                "requested_at": sub.cancel_requested_at if churn_type == "cancelled" else ts,
                "effective_at": ts,
                "billing_frequency": sub.billing_frequency,
                "payment_method": sub.payment_method,
                **extra,
            }
        )
        r = self.cfg["reactivation"]
        p = r["prob_after_lapsed"] if churn_type == "lapsed" else r["prob_after_cancelled"]
        if self.rng.random() < p:
            days = float(self.rng.beta(1.3, 2.5)) * r["window_months"] * 30.44
            self._push(ts + timedelta(days=max(days, 1.0)), "reactivate",
                       account_id=sub.account_id, previous=sub.subscription_id)

    def _lapse(self, sub: Subscription, ts: datetime, reason: str, invoice_id: str):
        """Involuntary churn. Drops any scheduled decreases or cancellation and voids unpaid invoices."""
        sub.status, sub.ended_at, sub.pending = "lapsed", ts, []
        self._emit(sub, "lapsed", ts, ts, {"reason": reason, "invoice_id": invoice_id}, 0)
        for inv_id in sorted(sub.open_invoices):
            self.invoices[inv_id]["status"] = "uncollectible"
        sub.open_invoices.clear()
        sub.delinquent.clear()
        self._end(sub, ts, "lapsed", reason=reason)

    def _on_reactivate(self, ts: datetime, p: dict):
        if self.account_live[p["account_id"]] is not None:
            return
        prev = self.subs[p["previous"]]
        if self.rng.random() < self.cfg["reactivation"]["keep_previous_config"]:
            plan, seats, frequency = prev.plan, prev.seats, prev.billing_frequency
            method = self._draw_payment_method(frequency, seats)
        else:
            mix = self.cfg["signup_mix"]
            plan, seats, frequency, method = self._draw_config(mix["premium_share"], mix["annual_share"])
        sub = self._new_sub(p["account_id"], plan, seats, frequency, method, "active", started_at=ts,
                            is_reactivation=True, previous_subscription_id=prev.subscription_id)
        self._begin_paid(sub, ts, {"is_reactivation": True, "previous_subscription_id": prev.subscription_id})

    # -------------------------------------------------------------- plan changes

    def _on_change(self, ts: datetime, p: dict):
        sub = self.live.get(p["sub_id"])
        if sub is None or sub.cancel_requested_at is not None:
            return
        kind = p["type"]
        pending_kinds = {c["kind"] for c in sub.pending}
        if kind == "add_seats":
            self._increase_seats(sub, ts, p)
        elif kind == "remove_seats":
            self._decrease_seats(sub, ts, p)
        elif kind == "plan_upgrade" and sub.plan == "pro":
            self._upgrade(sub, ts)
        elif kind == "plan_downgrade" and sub.plan == "premium" and "plan" not in pending_kinds:
            self._schedule_change(sub, ts, "plan", "premium", "pro", "downgrade")
        elif kind == "frequency_switch" and "billing_frequency" not in pending_kinds:
            new = "annual" if sub.billing_frequency == "monthly" else "monthly"
            self._schedule_change(sub, ts, "billing_frequency", sub.billing_frequency, new, "switch")

    def _followups(self, sub: Subscription, ts: datetime, p: dict, k: int, opposite: str):
        """Occasionally schedule an opposite seat change later in the same period."""
        if p.get("followup"):
            return
        if self.rng.random() < self.cfg["changes"]["opposite_seat_change_share"]:
            latest = sub.current_period_end - timedelta(hours=1)
            if latest > ts + timedelta(hours=1):
                when = self._rand_between(ts + timedelta(hours=1), latest)
                self._push(when, "change", sub_id=sub.subscription_id, type=opposite, followup=True,
                           k=int(self.rng.integers(1, k + 1)))

    def _increase_seats(self, sub: Subscription, ts: datetime, p: dict):
        k = p.get("k") or self._seat_delta(sub)
        old = sub.seats
        sub.seats += k
        event_id = self._emit(
            sub, "plan_updated", ts, ts,
            {"change_type": "seats", "direction": "increase", "from_seats": old, "to_seats": sub.seats,
             "seat_delta": k},
            self.amount(sub),
        )
        self._record(sub, ts)
        unit = self.price(sub.plan, sub.billing_frequency)
        rem = remaining_days(ts, sub.current_period_end)
        total = period_days(sub.current_period_start, sub.current_period_end)
        self._issue_invoice(sub, ts, "proration", [{
            "line_type": "seat_proration", "plan": sub.plan, "billing_frequency": sub.billing_frequency,
            "quantity": k, "unit_price_cents": unit, "service_period_start": next_midnight(ts),
            "service_period_end": sub.current_period_end, "amount_cents": prorate(k, unit, rem, total),
        }])
        if p.get("dst_forced"):
            self.notes.append({"anomaly_type": "dst_repeated_hour_change", "table_name": "subscription_events",
                               "record_id": event_id, "related_record_id": None,
                               "detail": "seat increase inside the repeated 1-2 a.m. ET hour"})
        if p.get("lookalike_of"):
            self.notes.append({"anomaly_type": "legit_lookalike_seat_increase",
                               "table_name": "subscription_events", "record_id": event_id,
                               "related_record_id": p["lookalike_of"],
                               "detail": "genuine second identical increase on the same day; keep both"})
            return
        day_end = next_midnight(ts)
        if (self.rng.random() < self.cfg["changes"]["lookalike_seat_increase_share"]
                and rem > 0 and day_end - ts > timedelta(minutes=2)):
            when = self._rand_between(ts + timedelta(minutes=1), day_end)
            self._push(when, "change", sub_id=sub.subscription_id, type="add_seats", k=k,
                       lookalike_of=event_id, followup=True)
        self._followups(sub, ts, p, k, "remove_seats")

    def _decrease_seats(self, sub: Subscription, ts: datetime, p: dict):
        plan, projected, frequency = self._projected(sub)
        k = min(p.get("k") or self._seat_delta(sub), projected - 1)
        if k < 1:
            return
        sub.pending.append({"kind": "seats", "delta": -k, "requested_at": ts})
        self._emit(
            sub, "plan_updated", ts, sub.current_period_end,
            {"change_type": "seats", "direction": "decrease", "from_seats": projected,
             "to_seats": projected - k, "seat_delta": -k},
            (projected - k) * self.price(plan, frequency),
        )
        self._record(sub, ts)
        self._followups(sub, ts, p, k, "add_seats")

    def _upgrade(self, sub: Subscription, ts: datetime):
        old_unit = self.price("pro", sub.billing_frequency)
        new_unit = self.price("premium", sub.billing_frequency)
        sub.plan = "premium"
        self._emit(sub, "plan_updated", ts, ts,
                   {"change_type": "plan", "direction": "upgrade", "from_plan": "pro", "to_plan": "premium"},
                   self.amount(sub))
        self._record(sub, ts)
        rem = remaining_days(ts, sub.current_period_end)
        total = period_days(sub.current_period_start, sub.current_period_end)
        self._issue_invoice(sub, ts, "proration", [{
            "line_type": "plan_proration", "plan": "premium", "billing_frequency": sub.billing_frequency,
            "quantity": sub.seats, "unit_price_cents": new_unit - old_unit,
            "service_period_start": next_midnight(ts), "service_period_end": sub.current_period_end,
            "amount_cents": prorate(sub.seats, new_unit - old_unit, rem, total),
        }])

    def _schedule_change(self, sub: Subscription, ts: datetime, dimension: str, old: str, new: str,
                         direction: str):
        sub.pending.append({"kind": dimension, "to": new, "requested_at": ts})
        plan, seats, frequency = self._projected(sub)
        self._emit(sub, "plan_updated", ts, sub.current_period_end,
                   {"change_type": dimension, "direction": direction, f"from_{dimension}": old,
                    f"to_{dimension}": new},
                   seats * self.price(plan, frequency))
        self._record(sub, ts)

    # ------------------------------------------------------------------ invoices

    def _issue_renewal_invoice(self, sub: Subscription, ts: datetime):
        unit = self.price(sub.plan, sub.billing_frequency)
        self._issue_invoice(sub, ts, "renewal", [{
            "line_type": "subscription", "plan": sub.plan, "billing_frequency": sub.billing_frequency,
            "quantity": sub.seats, "unit_price_cents": unit, "service_period_start": sub.current_period_start,
            "service_period_end": sub.current_period_end, "amount_cents": sub.seats * unit,
        }])

    def _issue_invoice(self, sub: Subscription, ts: datetime, invoice_type: str, lines: list[dict]):
        amount = sum(line["amount_cents"] for line in lines)
        if amount <= 0:  # a change on the last day of a period prorates to zero; nothing to bill
            return
        inv_id = self._inv_id()
        by_invoice = sub.payment_method == "invoice"
        inv = {
            "invoice_id": inv_id,
            "account_id": sub.account_id,
            "subscription_id": sub.subscription_id,
            "invoice_type": invoice_type,
            "payment_method": sub.payment_method,
            "issued_at": ts,
            "due_at": ts + timedelta(days=self.cfg["invoice_payments"]["net_days"]) if by_invoice else ts,
            "amount_due_cents": amount,
            "paid_cents": 0,
            "status": "open",
        }
        self.invoices[inv_id] = inv
        for line in lines:
            self.line_items.append({"line_item_id": self._li_id(), "invoice_id": inv_id, **line})
        sub.open_invoices.add(inv_id)
        if by_invoice:
            self._plan_invoice_payments(inv)
        else:
            self._plan_card_payments(inv)

    def _balance(self, inv: dict) -> int:
        return inv["amount_due_cents"] - inv["paid_cents"]

    def _apply_payment(self, inv: dict, amount: int, ts: datetime):
        inv["paid_cents"] += amount
        if self._balance(inv) > 0:
            return
        inv["status"] = "paid"
        sub = self.subs[inv["subscription_id"]]
        sub.open_invoices.discard(inv["invoice_id"])
        sub.delinquent.discard(inv["invoice_id"])
        if sub.status == "past_due" and not sub.delinquent:
            sub.status = "active"
            self._record(sub, ts)

    def _mark_delinquent(self, inv: dict, ts: datetime):
        sub = self.subs[inv["subscription_id"]]
        if sub.subscription_id not in self.live:
            return
        sub.delinquent.add(inv["invoice_id"])
        if sub.status == "active":
            sub.status = "past_due"
            self._record(sub, ts)

    # --- cards: charged at issue; weekly retries; card update triggers an immediate attempt

    def _plan_card_payments(self, inv: dict):
        c = self.cfg["card_payments"]
        t0 = inv["issued_at"]
        week = timedelta(days=c["retry_interval_days"])
        inv_id = inv["invoice_id"]
        if self.rng.random() >= c["first_attempt_failure"] * self._shock(t0):
            self._on_card_attempt(t0, {"invoice_id": inv_id, "attempt": 1, "success": True})
            return
        self._on_card_attempt(t0, {"invoice_id": inv_id, "attempt": 1, "success": False})
        outcome = self._choice(c["outcome_after_failure"])
        if outcome == "recover_on_retry":
            if self.rng.random() < c["retry_success_on_attempt_2"]:
                self._push(t0 + week, "card_attempt", invoice_id=inv_id, attempt=2, success=True)
            else:
                self._push(t0 + week, "card_attempt", invoice_id=inv_id, attempt=2, success=False)
                self._push(t0 + 2 * week, "card_attempt", invoice_id=inv_id, attempt=3, success=True)
        elif outcome == "recover_after_card_update":
            hour = timedelta(hours=1)
            if self.rng.random() < c["card_update_before_attempt_2"]:
                when = self._rand_between(t0 + hour, t0 + week - hour)
                self._push(when, "card_attempt", invoice_id=inv_id, attempt=2, success=True, card_update=True)
            else:
                self._push(t0 + week, "card_attempt", invoice_id=inv_id, attempt=2, success=False)
                when = self._rand_between(t0 + week + hour, t0 + 2 * week - hour)
                self._push(when, "card_attempt", invoice_id=inv_id, attempt=3, success=True, card_update=True)
        else:
            self._push(t0 + week, "card_attempt", invoice_id=inv_id, attempt=2, success=False)
            self._push(t0 + 2 * week, "card_attempt", invoice_id=inv_id, attempt=3, success=False, final=True)

    def _on_card_attempt(self, ts: datetime, p: dict):
        inv = self.invoices[p["invoice_id"]]
        if inv["status"] in ("uncollectible", "paid"):
            return
        amount = self._balance(inv)
        self.payments.append({
            "payment_id": self._pay_id(),
            "invoice_id": inv["invoice_id"],
            "account_id": inv["account_id"],
            "method": "card",
            "attempted_at": ts,
            "attempt_number": p["attempt"],
            "amount_cents": amount,
            "status": "succeeded" if p["success"] else "failed",
            "failure_reason": None if p["success"] else self._choice(self.cfg["card_payments"]["failure_reasons"]),
        })
        if p["success"]:
            self._apply_payment(inv, amount, ts)
            return
        self._mark_delinquent(inv, ts)
        if p.get("final"):
            inv["status"] = "uncollectible"
            sub = self.subs[inv["subscription_id"]]
            sub.open_invoices.discard(inv["invoice_id"])
            if sub.subscription_id in self.live:
                self._lapse(sub, ts, "payment_failed", inv["invoice_id"])

    # --- invoices: Net 30, partial payments allowed, lapse at 60 days past due

    def _plan_invoice_payments(self, inv: dict):
        c = self.cfg["invoice_payments"]
        issued, due = inv["issued_at"], inv["due_at"]
        lapse_at = due + timedelta(days=c["lapse_days_past_due"])
        amount = inv["amount_due_cents"]
        hour = timedelta(hours=1)
        outcome = self._choice(c["outcome"])
        plan: list[tuple[datetime, int]] = []
        if outcome == "on_time":
            plan.append((self._rand_between(issued + hour, due - hour), amount))
        elif outcome == "late":
            last = self._rand_between(due + hour, due + timedelta(days=c["late_payment_max_days_past_due"]))
            if self.rng.random() < c["late_partial_share"] and amount > 1:
                cuts = sorted({int(x) for x in self.rng.integers(1, amount, size=int(self.rng.integers(1, 3)))})
                parts = np.diff([0, *cuts, amount]).tolist()
                times = sorted(self._rand_between(issued + hour, last) for _ in cuts) + [last]
                plan.extend(zip(times, parts))
            else:
                plan.append((last, amount))
        elif self.rng.random() < c["never_partial_share"]:
            partial = int(amount * self.rng.uniform(0.2, 0.6))
            if partial > 0:
                plan.append((self._rand_between(issued + hour, lapse_at - DAY), partial))
        for when, part in plan:
            self._push(when, "invoice_payment", invoice_id=inv["invoice_id"], amount=int(part))
        self._push(due, "invoice_due", invoice_id=inv["invoice_id"])
        self._push(lapse_at, "invoice_lapse", invoice_id=inv["invoice_id"])

    def _on_invoice_payment(self, ts: datetime, p: dict):
        inv = self.invoices[p["invoice_id"]]
        if inv["status"] in ("uncollectible", "paid"):
            return
        amount = min(p["amount"], self._balance(inv))
        self.payments.append({
            "payment_id": self._pay_id(),
            "invoice_id": inv["invoice_id"],
            "account_id": inv["account_id"],
            "method": self._choice(self.cfg["invoice_payments"]["methods"]),
            "attempted_at": ts,
            "attempt_number": None,
            "amount_cents": amount,
            "status": "succeeded",
            "failure_reason": None,
        })
        self._apply_payment(inv, amount, ts)

    def _on_invoice_due(self, ts: datetime, p: dict):
        inv = self.invoices[p["invoice_id"]]
        if inv["status"] not in ("uncollectible", "paid") and self._balance(inv) > 0:
            self._mark_delinquent(inv, ts)

    def _on_invoice_lapse(self, ts: datetime, p: dict):
        inv = self.invoices[p["invoice_id"]]
        if inv["status"] in ("uncollectible", "paid") or self._balance(inv) <= 0:
            return
        inv["status"] = "uncollectible"
        sub = self.subs[inv["subscription_id"]]
        sub.open_invoices.discard(inv["invoice_id"])
        if sub.subscription_id in self.live:
            self._lapse(sub, ts, "invoice_unpaid", inv["invoice_id"])
