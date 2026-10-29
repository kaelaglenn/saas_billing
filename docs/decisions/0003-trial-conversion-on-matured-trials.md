# 0003. Measure trial conversion on matured trials only

- **Status:** Accepted
- **Date:** 2026-10-25
- **Related:** [PR #15](https://github.com/kaelaglenn/saas_billing/pull/15), `fct_trials`,
  `vars.trial_maturity_buffer_days`

## Context

Conversion rates by trial-start cohort look artificially low for recent cohorts, because many of their trials
haven't finished (right-censoring):

| Cohort | Trials | Naive conversion |
|---|---|---|
| 2026-07 | 657 | 16.3% |
| 2026-08 | 727 | 13.9% |
| 2026-09 | 1,007 | 7.3% |

Conversions happen throughout the trial (median day 14, latest day 29), and source events arrive up to 5 days
late, so a trial can look expired before its conversion lands.

## Decision

A trial is matured once its trial period plus `trial_maturity_buffer_days` (5) has passed as of the data
watermark. `fct_trials.is_matured` flags it, and conversion rates use matured trials only (15.9% overall at the
time).

## Alternatives considered

- **Naive conversion over all trials.** Understates recent cohorts, as above.
- The buffer value is a starting assumption; other values weren't evaluated.

## Consequences

- The most recent cohorts have no conversion rate until they mature.
- Using the watermark rather than `current_timestamp()` keeps results deterministic.
- Revisit the buffer after measuring how conversion timing and event lateness are distributed.
