# Independent evidence in this project

Evidence is independent when it isn't derived from the code under test. These are the sources we've used, and
the checks already automated.

## Source-system facts maintained separately from the event log

| Source | What it independently states | Already checked by |
|---|---|---|
| `subscriptions` (current-state table) | Each subscription's current status, plan, seats, frequency, `cancel_requested_at`, `ended_at` | `assert_subscription_history_current_matches_source`, `assert_latest_month_end_matches_source`, `assert_cancellation_outcomes_match_source` |
| `subscriptions` × `plan_prices` | Current MRR = seats × list price for live subscriptions | `assert_mrr_bridge_latest_month_matches_source` |
| `invoices.status` | paid / uncollectible / past_due / open as of the end of the window | `assert_invoice_delinquency_matches_source_status` |
| Raw row counts | Staging rows = raw rows − documented duplicates | Manual; numbers in `docs/raw_sources.md` |

## Reconciliation by a different path

| Check | Why it's independent |
|---|---|
| `int_subscription_checkpoint_reconciliation` | Each renewal = previous checkpoint + every change in between, computed from change requests, not from the history model |
| Cross-mart totals (e.g. `dim_accounts` customers and MRR = latest `fct_mrr_bridge` month) | Two models reach the same number through different joins |
| Accounting identities (`starting + net_new = ending` in the bridge) | `net_new` is summed from movement types; starting and ending come from totals |

## Not independent

- A test comparing a model to its own input or a rollup of itself (true by construction)
- A count checked against a number the same query produced
- The answer key (`data/truth/`). It's off limits, not evidence.
