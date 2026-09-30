# saas_billing

Billing analytics for a fictional B2B SaaS company, built the way a data team would build it from scratch:
a deterministic source-data generator with a ground-truth answer key, loaded into Snowflake and modeled with
dbt, with CI/CD on GitHub Actions.

```
generator (Python) ──▶ data/raw/*.parquet ──dlt──▶ Snowflake RAW ──dbt──▶ Snowflake ANALYTICS
                   └─▶ data/truth/*.parquet  (answer key for dbt tests, never a dbt source)
```

## Roadmap

- [x] Billing data generator with validation, ground truth, and seeded messiness ([spec](docs/billing_data_generator_spec.md))
- [ ] Snowflake bootstrap: databases, roles, warehouses, key-pair service users, resource monitor
- [ ] dlt pipeline: `data/raw` → Snowflake `RAW`
- [ ] dbt project: sources, staging, SCD2 subscription history, MRR and movements, invoices and collections
- [ ] Tests against the answer key in `data/truth`
- [ ] CI/CD: SQLFluff, slim CI into per-PR schemas, prod deploys on merge, scheduled runs, docs on Pages

## Quickstart

Requires [uv](https://docs.astral.sh/uv/).

```bash
uv sync
uv run generate-billing-data          # writes data/raw and data/truth (about 10 seconds)
uv run pytest                         # calendar math + an end-to-end run at 5% scale
```

Options: `--seed`, `--scale` (e.g. `0.1` for a fast 10% dataset), `--output-dir`, `--no-csv`.
Every rate, mix, and probability lives in [generator/config.yaml](generator/config.yaml).

## Generator

The pipeline runs in stages so each can be tested on its own:

1. **Simulate** ([simulate.py](generator/billing_generator/simulate.py)) — day-by-day, event-driven state machine.
   Scheduled work (renewals, trial ends, card retries, invoice deadlines) sits in a priority queue; random
   customer actions are drawn daily and queued at random times, so everything is processed in time order.
2. **Validate** ([validate.py](generator/billing_generator/validate.py)) — integrity checks on clean data. Any
   failure stops the run before anything is written. Calibration targets print as PASS/WARN.
3. **Ground truth** ([truth.py](generator/billing_generator/truth.py)) — built from the simulator's own state
   history, never from the raw tables.
4. **Messiness** ([messiness.py](generator/billing_generator/messiness.py)) — duplicates and late arrivals
   injected into `data/raw` only, on a separate random stream, with every touched record logged.

### Outputs

| `data/raw/` (dbt sources) | `data/truth/` (answer key) |
|---|---|
| accounts, subscriptions, subscription_events, invoices, invoice_line_items, payments | subscription_history, mrr_monthly, churn_events, monthly_summary, seeded_anomalies |

`data/` is git-ignored; regenerate it any time. The same seed always produces identical files.

### Implementation decisions (beyond the spec)

These are source-system behaviors the dbt models need to handle:

- **Seat changes carry a `seat_delta`.** A scheduled decrease applies at renewal against whatever the seat
  count is then, so seats at any instant = the last full-state event (`subscription_imported`,
  `subscription_started`, `renewed`) plus deltas that took effect since. Plan and frequency changes carry
  absolute `from_*`/`to_*` values.
- **`subscription_amount_cents` on a scheduled change is the projection at request time**, the way a webhook
  would report it. `renewed` events carry the realized amount and full state.
- **Dropped scheduled changes stay in the event log.** If a subscription lapses before a scheduled decrease or
  cancellation, the event still exists with an `effective_at` after `ended_at`. It never took effect.
- **Pending cancellations carry over at cutover.** Some imported monthly subscriptions already had a
  cancellation pending on Jan 1, 2024; it appears only as `cancel_requested_at` in the
  `subscription_imported` attributes.
- **Zero-amount prorations aren't invoiced.** A change on the last day of a period prorates to 0 days.
- **A cancelled subscription with an unpaid invoice** keeps going through dunning; if collection fails, the
  invoice becomes `uncollectible` but no `lapsed` event is emitted (the subscription already ended).
- **Upgrade/downgrade rates apply to eligible subscriptions only**: upgrades to Pro subscriptions,
  downgrades to Premium subscriptions.
- **Seats can exceed 250** through seat increases; 1–250 is the range at signup.
- **The data window ends at midnight ET on Sep 30, 2026** (2026-10-01 04:00 UTC), so renewals at 00:00 UTC
  on Oct 1 (Sep 30 evening in ET) are included.
- **`accounts.updated_at`** changes only when a subscription on the account starts or ends.
- **`mrr_monthly` for Jan 2024** compares against the imported opening state, so imported subscriptions show
  as `unchanged` rather than `new`.
- **`seeded_anomalies`** also lists the genuine same-day look-alike seat increases (keep both) and the
  forced plan changes inside the repeated November 1–2 a.m. ET hour.
