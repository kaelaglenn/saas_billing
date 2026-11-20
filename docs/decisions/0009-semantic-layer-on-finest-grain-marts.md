# 0009. Build the Semantic Layer on the finest-grain marts, with balances semi-additive and time in Eastern Time

- **Status:** Proposed
- **Date:** 2026-11-20
- **Related:** `models/semantic_layer/`, `dim_dates`, `fct_subscription_months`, `fct_ar_month_end_balances`,
  `fct_mrr_bridge`, [ADR 0002](0002-report-in-eastern-time-store-in-utc.md),
  [ADR 0003](0003-trial-conversion-on-matured-trials.md)

## Context

We added the dbt Semantic Layer (MetricFlow) so the project's metrics have one governed definition each:
20 metrics across MRR, trials, billing and card dunning. Three choices shape every metric:

- **Which marts to build on.** The marts include rollups that already hold monthly totals (`fct_mrr_bridge`,
  `fct_ar_rollforward`) and finer facts underneath them (`fct_subscription_months`, one row per subscription
  per month-end; `fct_ar_month_end_balances`, one row per open invoice per month-end). Only the finer facts
  carry `account_id`, which is what lets a metric join to `dim_accounts` for industry, size band and customer
  status.
- **How balances add up.** MRR, paying subscriptions and accounts receivable are balances (stocks), not
  activity (flows). They add across subscriptions or invoices at one month-end, but not across month-ends.
  Removing the semi-additive setting made Q1 2024 MRR 249,462,560 cents, three month-ends added together,
  instead of the correct 84,704,880.
- **Which timezone.** MetricFlow groups by its own `metric_time`, so the time dimension each semantic model
  uses decides which month an event lands in.

## Decision

We define semantic models on the finest-grain marts, never on rollups, and mark MRR, paying subscriptions and
ending AR as semi-additive over their month-end date (`non_additive_dimension`, `window_choice: max`). Every
time dimension is a `*_date_et` column, so metrics report in Eastern Time like the marts, and `dim_dates`
(one row per Eastern Time date, built from the reporting calendar) is the time spine.

## Alternatives considered

- **Semantic models on the rollups (`fct_mrr_bridge`, `fct_ar_rollforward`).** Lost: they have one row per
  month and no `account_id`, so no metric built on them could be sliced by an account attribute. Each new
  slice would need another rollup table, which is what a semantic layer is meant to avoid.
- **Plain sums for MRR and AR.** Lost: correct for a single month but wrong for any longer period, as the
  Q1 2024 result above shows, and the error is silent.
- **UTC time dimensions (`*_at`).** Lost: events near midnight would land in a different month than in the
  marts and the bridge (ADR 0002), so the same metric would disagree with the tables it comes from.
- **A semantic model on `dim_subscriptions`.** Not added: it describes the current plan and frequency, while
  `fct_subscription_months` describes them as they were at each month-end. Exposing both would give two
  different "plan" dimensions.

## Consequences

- Any metric can be sliced by any account attribute through the shared `account` entity, and new
  account-level dimensions become available to every metric at once.
- Verified: MRR, paying subscriptions and every movement match `fct_mrr_bridge` in 34 of 34 months; MRR and
  paying subscriptions match the answer key in 33 of 33; billing, AR, trial and dunning metrics match their
  marts.
- Queries scan the finer facts rather than small rollups. Fine at this volume; revisit if query cost matters.
- The semi-additive settings are easy to remove by accident, and plain dbt tests don't catch it. Revisit with
  a CI check (`mf validate-configs` or a metric-vs-bridge comparison) if the metrics are used in production.
- `dbt-metricflow` is pinned to 0.15.0 to match the MetricFlow version already locked. Upgrade both together.
- `mf` reads `target/semantic_manifest.json`, not the YAML, so run `dbt parse` after editing metrics.
