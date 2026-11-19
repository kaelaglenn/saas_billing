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

_Filled in after the comparison._
