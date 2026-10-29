# 0001. Renewals as checkpoints when replaying subscription events

- **Status:** Accepted
- **Date:** 2026-10-22
- **Related:** [PR #11](https://github.com/kaelaglenn/saas_billing/pull/11), `int_subscription_state_changes`,
  `int_subscription_history`, `int_subscription_checkpoint_reconciliation`

## Context

Subscription history is rebuilt by replaying `subscription_events` in order (event sourcing). Some changes are
immediate (seat increases, upgrades); others are scheduled and only take effect at the next renewal (seat
decreases, downgrades, billing-frequency switches). Scheduled changes stay in the event log even when they never
happen: 34 have an `effective_at` after the subscription lapsed, and 146 more were scheduled for the same period
end as a cancellation, which drops them. Seat changes carry a `seat_delta`, not an absolute count. The `renewed`
event records the full post-renewal state, including every scheduled change that actually applied.

## Decision

We treat full-state events (`trial_started`, `subscription_imported`, `subscription_started`, `renewed`) as
checkpoints that reset
plan, seats and billing frequency, and apply only immediate changes between checkpoints. Scheduled changes are
not replayed. Seats at any instant = the last checkpoint's seats + the immediate `seat_delta`s since.

## Alternatives considered

- **Replay every change at its `effective_at`.** Would apply scheduled changes that never took effect, unless
  each one's outcome were derived first, and it would duplicate what the `renewed` event already records.

## Consequences

- Scheduled changes that never happened are skipped without special handling.
- Correctness depends on renewal events carrying the true post-change state. This is guarded by
  `int_subscription_checkpoint_reconciliation`: every renewal must equal the previous checkpoint plus every
  immediate and scheduled change in between, computed independently from change requests (85,793 / 85,793
  reconciled at the time).
- Changes at the same instant need an explicit order (`sort_order`: checkpoint → immediate → past_due → ending).
