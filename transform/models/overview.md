{% docs __overview__ %}

# saas_billing

Billing analytics for a fictional B2B SaaS company: subscriptions, MRR, trials, invoices, collections and card
dunning. Messy synthetic source data is loaded into Snowflake with dlt and modeled here, in dbt, the way a data
team would: every change through a pull request, slim CI, and a production deploy on merge.

[Source code](https://github.com/kaelaglenn/saas_billing) ·
[Design decisions (ADRs)](https://github.com/kaelaglenn/saas_billing/tree/main/docs/decisions) ·
[Case study](https://kaelaglenn.com/projects/saas-billing)

## Start here

| Model | What it answers |
|---|---|
| [fct_mrr_bridge](#!/model/model.saas_billing.fct_mrr_bridge) | How MRR moved each month: starting + new + expansion + reactivation + contraction + churned = ending |
| [fct_subscription_months](#!/model/model.saas_billing.fct_subscription_months) | Each subscription's state and MRR at every month-end (periodic snapshot) |
| [fct_trials](#!/model/model.saas_billing.fct_trials) | Trial outcomes and conversion, measured on matured trials only (accumulating snapshot) |
| [fct_invoices](#!/model/model.saas_billing.fct_invoices) | Each invoice from issue to payment or write-off (accumulating snapshot) |
| [fct_ar_rollforward](#!/model/model.saas_billing.fct_ar_rollforward) | How accounts receivable moved each month, with aging at month-end |
| [fct_card_dunning_cases](#!/model/model.saas_billing.fct_card_dunning_cases) | Failed card charges and how dunning (weekly retries) turned out |
| [dim_accounts](#!/model/model.saas_billing.dim_accounts) | Customers: company attributes and customer status |

Open any model and use the lineage button (bottom right) to see where it comes from and what reads it.

## Layers

- **Staging** (`stg_`): one view per raw table. Renames and types columns, converts naive timestamps to UTC, and
  removes exact duplicates only; a natural-key test fails on anything else.
- **Intermediate** (`int_`): replays the subscription event log into an SCD Type 2 history, then derives month-end
  states, past-due and delinquency periods, payment summaries and dunning outcomes.
- **Marts** (`dim_`, `fct_`): tables with enforced contracts and public access. Each fact's description names its
  grain and type.
- **Semantic Layer**: semantic models and governed metrics (MRR and its movements, trial conversion, collections,
  ending AR, card recovery) on the finest-grain marts. MRR and AR are balances, so over time they take the
  month-end value instead of summing.

## Conventions

| Pattern | Meaning |
|---|---|
| `*_at` | Timestamp in UTC |
| `*_date_et`, `*_month_et` | Date or month in the reporting timezone, America/New_York |
| `*_cents` | Money, integer US cents |
| `is_*`, `has_*` | Boolean |

## How it was checked

- **Data tests** on every model's keys and relationships, plus singular tests that reconcile the models against
  the source's own current-state tables.
- **Unit tests** on the logic real data rarely exercises: MRR movement classification, AR aging boundaries, dunning
  outcomes and history replay.
- **An answer key, used once.** The data generator also writes the true answers. The models were built without
  them, then compared after modeling froze: no bugs, with every remaining difference a documented definition choice
  ([comparison](https://github.com/kaelaglenn/saas_billing/blob/main/docs/answer_key_comparison.md)).

The data is synthetic and fixed (January 2024 through September 2026), so these docs describe the latest
production build.

{% enddocs %}
