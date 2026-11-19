# Answer-key comparison

The generator writes an answer key to `data/truth/`: what the messy raw data *should* say. Until now nothing in
the project read it. On a real team there is no answer key, so the models were built only from the raw data,
business rules, and checks against the source's own state (see `docs/raw_sources.md` and the ADRs).

This file records the comparison done once at the end. The plan was written and committed **before** the
answer key was opened, so it can't have been shaped by it.

- **Models compared:** tag `pre-answer-key` (commit `a078350`), production as deployed from it.
- **Fixes found by the comparison** go in separate PRs, each labelled "found by the answer key", so what we found
  on our own stays distinguishable from what the key told us.

## Plan (written before reading the answer key)

### What we compare

Where the answer key has the same thing at the same grain, compare per entity (rows missing on either side, then
mismatched values). Otherwise compare the aggregate.

| # | Area | Our model | Grain | Values |
|---|---|---|---|---|
| 1 | Clean source rows | `stg_billing__*` | one row per entity per table | row counts after dedup; natural keys present on both sides |
| 2 | Subscription current state | `dim_subscriptions` | subscription | status, plan, seats, billing frequency, MRR |
| 3 | Subscription history | `dim_subscription_history` | subscription × validity period | the state at each month-end |
| 4 | Month-end MRR | `fct_subscription_months` | subscription × month-end | MRR at the cutoff |
| 5 | MRR movements | `fct_mrr_bridge` | month | starting and ending MRR, new, expansion, reactivation, contraction, churned; subscription counts |
| 6 | Trials | `fct_trials` | trial | outcome (converted / expired / in progress), conversion date |
| 7 | Customers | `dim_accounts` | account | customer status |
| 8 | Invoices | `fct_invoices` | invoice | payment outcome, amount paid, written off, paid and written-off dates |
| 9 | Accounts receivable | `fct_ar_month_end_balances`, `fct_ar_rollforward` | invoice × month-end; month | balance, aging bucket; ending AR by month |
| 10 | Card dunning | `fct_card_dunning_cases` | dunning case | outcome, recovery date |

### What counts as a match

- **Counts and cents: exact.** Money is integer cents; there's no rounding to tolerate.
- **Dates: same reporting date** in America/New_York (ADR 0002). If the key uses another timezone or month
  boundary, convert it before comparing and note it, rather than calling it a mismatch.
- **Per-entity comparisons check both directions** (in ours, not the key; in the key, not ours) and report how
  many rows matched, so a comparison can't pass on an empty join.

### How we classify each mismatch

1. **Our bug:** the raw data and our own documented rules say the key is right. Fix it.
2. **Different, defensible definition:** both readings fit the data, for example where an ADR made a choice
   (renewal checkpoints, trial maturity, reporting timezone). Document it; change only if the key's definition is
   the better business rule.
3. **Not knowable from the raw data:** the key uses information the raw data never contains, such as which messy
   rows the generator injected. Document it, and don't model toward it.

## Results

Compared on 2026-11-19: production marts and staging (built from `pre-answer-key`) against `data/truth/`. Only
`data/truth/` was read. The generator's `truth.py` and `messiness.py` stayed unread; nothing below needed them.

**No bugs found.** Every answer-key row has a matching row in our models. The differences are three definition
choices, each explained below.

### What the answer key covers

The key has five files: `subscription_history`, `mrr_monthly`, `monthly_summary`, `churn_events` and
`seeded_anomalies`. It has nothing on invoices, payments, AR or dunning, so plan areas 8–10 rest on the checks
made while building them (source invoice status, lapse events, roll-forward identities; see PRs #18 and #19).
It also has no per-trial or per-account file, so areas 6 and 7 are compared only through the monthly counts.

| # | Area | Key | Matched | Differences |
|---|---|---|---|---|
| 1 | Clean source rows | `seeded_anomalies` (2,625) | all 5 anomaly types handled as the key says | none |
| 2 | Subscription current state | `subscription_history` where current (30,516) | 30,516 of 30,516, every attribute | none |
| 3 | Subscription history | `subscription_history` (80,116) | 80,116 of 80,116, every attribute and both validity bounds | none |
| 4 | Month-end MRR | `mrr_monthly` (150,883) | 150,883 of 150,883 on status, plan, seats, frequency, MRR | 1 row's movement (A); 49,258 rows only ours, by design (B) |
| 5 | MRR movements | `monthly_summary` (33 months) | ending MRR, starting and ending subscriptions, reactivations, cancellations: all 33 months | lapsed churn lower by 13 across 12 months (C) |
| 6 | Trials | `monthly_summary` | trial starts and conversions: all 33 months | none |
| — | Churn events | `churn_events` (3,088) | 3,088 of 3,088 on type, requested, effective, reporting date | lapse reason (D) |
| 7–10 | Customers, invoices, AR, dunning | no key | — | — |

### Area 1: every seeded anomaly handled correctly

| Anomaly | Key | Staging |
|---|---|---|
| Retried webhooks: same content, new `event_id` (remove) | 784 | 784 removed, 784 originals kept |
| Payments loaded twice (remove one copy) | 209 | raw 104,814 → staged 104,605: 209 removed, each payment kept once |
| Real second identical seat increase on the same day (keep both) | 60 pairs | all 120 events kept |
| Seat change in the repeated DST hour | 4 | kept, with correct times (history matches exactly) |
| Late-arriving events | 1,568 | all kept |

The lookalikes are the trap: deduplicating on content would have dropped 60 real seat increases. The
convention of removing exact copies only, with a natural-key test, kept them.

### Differences, classified

- **A. `sub_001882`, January 2024: different, defensible definition.** Imported 2024-01-01 00:00 UTC at 8,700
  cents and upgraded to 11,600 at 00:13 UTC, which is 19:13 on December 31 in Eastern Time. Reporting in ET
  ([ADR 0002](decisions/0002-report-in-eastern-time-store-in-utc.md)) puts the upgrade in December, before the
  first reporting month, so it's in our opening balance. The key counts a 2,900-cent January expansion. Same
  ending MRR every month. Keep ours.
- **B. Rows only in our `fct_subscription_months`: by design.** 45,391 trialing or expired-trial months at 0 MRR,
  3,854 rows for the December 2023 opening-balance month, and the 13 subscriptions in C. None carry MRR outside
  the opening month.
- **C. 13 subscriptions that converted and lapsed in the same month: different, defensible definition.** The
  key counts each as a new subscription and a lapse in that month. Our bridge counts subscriptions at
  month-ends, so one that is never live at a month-end appears in neither. Both satisfy starting + new +
  reactivated − churned = ending in every month, and the net effect is 0. `fct_trials` counts them as
  conversions on both sides. The cost is that our bridge's involuntary churn (and so logo churn rate) is lower
  by 1–2 in 12 of 33 months.
- **D. Lapse reason: different column, not a bug.** The key gives lapses a reason from how the customer paid
  (`payment_failed` for card, 547; `invoice_unpaid` for invoice payment, 85). Our `cancel_reason` is the reason a
  customer gave when asking to cancel, so it's null for lapses (4 lapsed subscriptions had asked to cancel
  first). The key's reason follows from `payment_method`, which we already have.

### Not knowable from the raw data

Nothing. Every difference above can be explained from the raw data and our documented rules.
