# 0008. The MRR bridge counts subscriptions at month-ends, so a same-month convert-and-lapse is neither new nor churned

- **Status:** Proposed
- **Date:** 2026-11-19
- **Related:** `fct_mrr_bridge`, `fct_subscription_months`, `fct_trials`,
  [answer-key comparison](../answer_key_comparison.md) (difference C)

## Context

`fct_mrr_bridge` explains each month's change in MRR and in live subscriptions: ending = starting + new +
reactivated − churned. It is built from `fct_subscription_months`, one row per subscription per month-end.

The answer-key comparison found 13 subscriptions that converted from a trial and then lapsed (unpaid after
dunning) within the same Eastern Time month. They are never live at a month-end. The answer key counts each one
as a new subscription and a lapse in that month; our bridge counts neither.

- Both versions balance in every one of the 33 months, and MRR is identical: the 13 never carry MRR at a
  month-end.
- The difference is in counts only: our involuntary churn, and so logo churn rate, is lower by 1 or 2 in 12 of
  33 months (13 in total).
- `fct_trials` counts all 13 as conversions, on both sides.

## Decision

We keep the bridge's counts based on month-end states: a subscription counts as new, reactivated or churned in a
month only if its state at the month-end changes. One that converts and lapses between two month-ends appears in
the trial conversion count but not in the bridge.

## Alternatives considered

- **Count every new and churn event in the month, as the answer key does.** Lost: the bridge would no longer be
  built from month-end snapshots, and its new and churned counts would include subscriptions that were never in
  any month-end base. A bridge that reconciles month-end to month-end is the standard form, and it keeps
  subscription counts consistent with the MRR they explain.

## Consequences

- The bridge's subscription counts and MRR always describe the same month-end states.
- Logo churn rate from the bridge slightly understates churn events: 13 lapses over 33 months aren't counted.
  Anyone who needs every lapse, for example to analyze failed first payments, should count churn events
  (`dim_subscriptions.ended_at`, `end_reason`) rather than the bridge.
- `fct_mrr_bridge`'s description should say this, so the difference from an event count isn't a surprise.
- Revisit if conversions that lapse before a month-end become common (for example from a change to trial or
  dunning length), since the gap would then be material.
