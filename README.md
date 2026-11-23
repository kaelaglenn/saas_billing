# saas_billing

Billing analytics for a fictional B2B SaaS company (subscriptions, MRR, invoices, collections and card dunning),
built end to end the way a data team would: messy synthetic source data, loaded into Snowflake with dlt, modeled
in dbt, and shipped through pull requests with slim CI and production deploys.

**Case study:** [kaelaglenn.com/projects/saas-billing](https://kaelaglenn.com/projects/saas-billing): charts,
key decisions, and how I worked with an AI agent.

```
generator (Python) ──▶ data/raw ──dlt──▶ Snowflake RAW.BILLING ──dbt──▶ ANALYTICS (marts + Semantic Layer)
                   └─▶ data/truth  (answer key, kept out of modeling; compared once at the end)
```

## Results

- **No bugs against the answer key.** The generator writes a ground-truth answer key that the models never saw.
  After modeling froze (tag `pre-answer-key`), a full comparison matched 30,516 of 30,516 current subscriptions,
  80,116 of 80,116 history rows, and month-end MRR in all 33 months. The few remaining differences are
  documented definition choices ([comparison](docs/answer_key_comparison.md)).
- **32 dbt models** (6 staging, 12 intermediate, 14 marts) with enforced contracts on every mart.
- **317 data tests and 4 unit tests**, including 7 singular tests that reconcile the models against the
  source's own current-state tables. The unit tests were mutation-tested: 12 deliberate bugs, all caught.
- **19 governed metrics** in the dbt Semantic Layer, with MRR and AR handled as balances (semi-additive).
- **Architecture decision records** for the main design choices and the alternatives they beat
  ([docs/decisions](docs/decisions/)).

## Where to look

| To see | Start with |
|---|---|
| Lineage, model and column docs | [dbt docs site](https://kaelaglenn.github.io/saas_billing/) (rebuilt with every production deploy) |
| How the messy source was profiled | [docs/raw_sources.md](docs/raw_sources.md) |
| Judgment calls | ADRs [0001](docs/decisions/0001-renewals-as-checkpoints-in-event-replay.md) (event replay), [0003](docs/decisions/0003-trial-conversion-on-matured-trials.md) (trial conversion), [0008](docs/decisions/0008-mrr-bridge-counts-month-end-states.md) (MRR bridge) |
| The core modeling | [int_subscription_history](transform/models/intermediate/subscriptions/int_subscription_history.sql) (event log → SCD Type 2), [fct_mrr_bridge](transform/models/marts/subscriptions/fct_mrr_bridge.sql) |
| Testing | [singular tests](transform/tests/), [unit tests](transform/models/marts/subscriptions/_subscriptions__unit_tests.yml) |
| Metrics | [semantic models and metrics](transform/models/semantic_layer/) |
| CI/CD | [workflows](.github/workflows/), [ADR 0007](docs/decisions/0007-slim-ci-against-prod-manifest.md) (slim CI) |

## The model

- **Staging:** one view per raw table. Removes exact duplicates only, with a natural-key test so anything else
  fails instead of vanishing.
- **Intermediate:** replays the subscription event log into an SCD Type 2 history, then derives month-end states,
  past-due and delinquency periods, invoice payment summaries and dunning outcomes.
- **Marts:** `dim_accounts`, `dim_subscriptions` and the reporting calendar; facts named for their grain and type,
  such as `fct_subscription_months` (periodic snapshot), `fct_mrr_bridge`, `fct_trials` and `fct_invoices`
  (accumulating snapshots), `fct_payments` (transaction) and `fct_ar_rollforward`.
- **Conventions:** `*_at` is UTC; `*_date_et` is a date in the reporting timezone (America/New_York); money is
  integer `*_cents` ([ADR 0002](docs/decisions/0002-report-in-eastern-time-store-in-utc.md)).

## Stack

Python data generator · dlt · Snowflake · dbt Core 1.12 (dbt_utils, dbt_expectations, dbt_project_evaluator) ·
MetricFlow · SQLFluff · pre-commit · GitHub Actions. Built with [Claude Code](CLAUDE.md), with guardrails in
[.claude/](.claude/): no production targets, no merging, no reading the answer key.

## Run it

Requires [uv](https://docs.astral.sh/uv/). Generating data and running the tests needs no warehouse:

```bash
uv sync
```

```bash
uv run generate-billing-data
```

```bash
uv run pytest
```

To load Snowflake and run dbt: [snowflake/README.md](snowflake/README.md), then
[docs/development.md](docs/development.md) (setup, conventions, querying metrics, CI/CD). How the source data is
simulated: [docs/generator.md](docs/generator.md).
