from datetime import date, datetime

import pytest

from billing_generator.billing_calendar import (
    UTC,
    add_months,
    period_days,
    period_end,
    prorate,
    remaining_days,
)


def ts(*args):
    return datetime(*args, tzinfo=UTC)


@pytest.mark.parametrize(
    "start, months, expected",
    [
        (date(2024, 1, 31), 1, date(2024, 2, 29)),  # leap year clamp
        (date(2025, 1, 31), 1, date(2025, 2, 28)),
        (date(2025, 1, 31), 2, date(2025, 3, 31)),  # clamping never drifts
        (date(2024, 2, 29), 12, date(2025, 2, 28)),
        (date(2024, 12, 15), 1, date(2025, 1, 15)),
        (date(2024, 3, 31), -1, date(2024, 2, 29)),
    ],
)
def test_add_months_clamps(start, months, expected):
    assert add_months(start, months) == expected


def test_first_period_ends_midnight_after_anniversary():
    # Converted Jan 15 at 10:00 UTC: first period ends 00:00 UTC Feb 16.
    assert period_end(date(2024, 1, 15), 1, "monthly") == ts(2024, 2, 16)
    assert period_end(date(2024, 1, 15), 1, "annual") == ts(2025, 1, 16)


def test_month_end_anchor_follows_spec_example():
    anchor = date(2025, 1, 31)
    ends = [period_end(anchor, i, "monthly") for i in (1, 2, 3)]
    assert ends == [ts(2025, 3, 1), ts(2025, 4, 1), ts(2025, 5, 1)]  # Feb 28, Mar 31, Apr 30 + 1 day


def test_period_days_frees_rest_of_start_day():
    assert period_days(ts(2024, 1, 15, 10), ts(2024, 2, 16)) == 31
    assert period_days(ts(2024, 2, 16), ts(2024, 3, 16)) == 29


def test_remaining_days_frees_change_day():
    end = ts(2024, 2, 16)
    assert remaining_days(ts(2024, 2, 1, 23, 59), end) == 14
    assert remaining_days(ts(2024, 2, 15, 12), end) == 0


def test_prorate_rounds_down_in_customers_favor():
    # 14 seats x $10 upgrade difference x 29 of 31 days = 13,096.77 -> 13,096
    assert prorate(14, 1000, 29, 31) == 13096
    assert prorate(1, 1900, 31, 31) == 1900
