# 0002. Report in Eastern Time; store and compute in UTC

- **Status:** Accepted
- **Date:** 2026-10-23 (naming convention added 2026-10-25)
- **Related:** [PR #13](https://github.com/kaelaglenn/saas_billing/pull/13),
  [PR #15](https://github.com/kaelaglenn/saas_billing/pull/15), `int_reporting_months`, `to_reporting_date()`

## Context

The business reports in Eastern Time: months, month-end MRR, and anything bucketed by date. Source timestamps
are UTC (except `accounts`, which stores naive ET). The month-end cutoff in UTC moves with daylight saving time
(04:00 or 05:00 UTC), and the data's Jan 1, 2024 00:00 UTC cutover is Dec 31, 7 p.m. ET. A `DATE` carries no
timezone, so a column like `month_start_date` doesn't say which calendar it belongs to.

## Decision

The reporting timezone is defined once, `vars.reporting_timezone: America/New_York`. Timestamps stay UTC
(`timestamp_tz`, named `*_at`) and are converted only where a reporting date or period is needed, through
`to_reporting_date()`. Dates and months in the reporting timezone are named `*_date_et` / `*_month_et`.

## Alternatives considered

- **Unsuffixed date names** (`month_start_date`, the original names). Renamed in PR #15 because the name must
  state the timezone a `DATE` can't carry. Done before any consumers existed; contracts enforce the new names.
- Other options (e.g. converting at ingestion) weren't recorded at the time.

## Consequences

- Month boundaries are correct across DST transitions (checked: cutoffs only at 04:00 or 05:00 UTC, months tile
  with no gaps).
- December 2023 becomes an opening-balance month (state known, activity not), and September 2026 is provisional:
  its cutoff falls after the latest data.
- Changing the variable changes every reporting date; the `_et` suffix would then be wrong.
