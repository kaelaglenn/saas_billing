"""Billing period and proration math. All instants are timezone-aware UTC datetimes."""

from __future__ import annotations

import calendar
from datetime import UTC, date, datetime, timedelta

DAY = timedelta(days=1)
MONTHS_PER_PERIOD = {"monthly": 1, "annual": 12}


def midnight(d: date) -> datetime:
    return datetime(d.year, d.month, d.day, tzinfo=UTC)


def next_midnight(ts: datetime) -> datetime:
    """00:00 UTC on the day after ts."""
    return midnight(ts.date()) + DAY


def ceil_midnight(ts: datetime) -> datetime:
    return ts if ts == midnight(ts.date()) else next_midnight(ts)


def add_months(d: date, months: int) -> date:
    """Shift by whole months, clamping days 29-31 to the end of shorter months."""
    m0 = d.month - 1 + months
    year, month = d.year + m0 // 12, m0 % 12 + 1
    return date(year, month, min(d.day, calendar.monthrange(year, month)[1]))


def period_end(anchor: date, index: int, frequency: str) -> datetime:
    """End of billing period `index`: 00:00 UTC the day after the index-th anniversary of anchor.

    Always computed from the original anchor so clamping never drifts (Jan 31 -> Feb 28 -> Mar 31).
    """
    return midnight(add_months(anchor, index * MONTHS_PER_PERIOD[frequency])) + DAY


def period_days(start: datetime, end: datetime) -> int:
    """Billable days in a period. A mid-day start's remaining hours are free."""
    return (end - ceil_midnight(start)).days


def remaining_days(change_at: datetime, end: datetime) -> int:
    """Whole days from 00:00 UTC after the change to period end. The change day is free."""
    return max(0, (end - next_midnight(change_at)).days)


def prorate(units: int, unit_price_cents: int, remaining: int, total: int) -> int:
    """Prorated charge in integer cents, rounded down (in the customer's favor)."""
    return (units * unit_price_cents * remaining) // total
