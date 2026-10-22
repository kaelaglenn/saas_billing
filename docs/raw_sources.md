# Raw sources

Profile of the six tables in `RAW.BILLING`, from queries against the loaded data (seed 42, data through
Sep 30, 2026 ET). Counts are exact for that dataset; the generator is deterministic, so they only change if the
config does.

There are two layers to keep apart:

- **Source system behavior** is what the simulated billing application does: some tables update rows in place
  (mutable), others only ever add rows (append-only).
- **Warehouse arrival** is the same for every table: the generator writes a full snapshot as of the end of the
  window and dlt replaces each table on every load. So for mutable tables, `RAW` holds only the latest state.
  An invoice's earlier `past_due` status, or a subscription's previous plan, is not recoverable from those
  tables; history survives only in the append-only `subscription_events` and `payments`.

## Overview

| Table | Grain | Key | Key unique in raw? | Source behavior |
|---|---|---|---|---|
| `accounts` | one row per customer | `account_id` | ✅ yes (30,273) | mutable: `updated_at` changes when a subscription starts or ends |
| `subscriptions` | one row per subscription; an account can have several over time, at most one live | `subscription_id` | ✅ yes (30,516) | mutable: current state, overwritten on every change |
| `subscription_events` | one row per event | `event_id` (surrogate); natural key is `subscription_id, event_type, requested_at, effective_at, attributes` | `event_id` ✅ yes; natural key ❌ **no**: 784 retried-webhook copies | append-only event log |
| `invoices` | one row per invoice | `invoice_id` | ✅ yes (97,299) | mutable: amounts fixed, `status` changes |
| `invoice_line_items` | one row per invoice line | `line_item_id` | ✅ yes (97,299) | append-only |
| `payments` | one row per card attempt or received invoice payment | `payment_id` | ❌ **no**: 209 rows loaded twice (104,814 rows, 104,605 distinct) | append-only |

## Timestamps

Every timestamp is `TIMESTAMP_TZ` in **UTC** except `accounts`, which stores **naive America/New_York** local
time as `TIMESTAMP_NTZ`. The company reports in ET, so UTC timestamps need converting before they're bucketed
into days or months: billing periods start at 00:00 UTC, which is 7 or 8 p.m. ET the evening before.

| Table | Timestamps | Timezone |
|---|---|---|
| `accounts` | `created_at`, `updated_at` | naive ET (`TIMESTAMP_NTZ`) |
| `subscriptions` | `trial_started_at`, `started_at`, `current_period_start`, `current_period_end`, `cancel_requested_at`, `ended_at`, `updated_at` | UTC |
| `subscription_events` | `requested_at` (customer or system acted), `effective_at` (change takes effect), `ingested_at` (landed in the warehouse) | UTC |
| `invoices` | `issued_at`, `due_at` | UTC |
| `invoice_line_items` | `service_period_start`, `service_period_end` | UTC |
| `payments` | `attempted_at` | UTC |

## Nulls, duplicates, and anomalies by table

**accounts**
- No nulls.
- Naive ET timestamps: converting to UTC needs `convert_timezone('America/New_York', 'UTC', created_at)`;
  comparing them directly with UTC columns shifts late-evening rows by a day.
- 3 accounts have `created_at` inside the repeated 1–2 a.m. hour on a November fall-back day, so their true UTC
  instant is ambiguous. Snowflake resolves them to the first (EDT) occurrence; for all 3 the true instant was
  the second (EST), so they convert one hour early. The source doesn't record which occurrence it was, so this
  can't be corrected. Casting `TIMESTAMP_NTZ` to `TIMESTAMP_TZ` instead uses the session timezone and gets
  every row wrong; see the `naive_to_utc` macro.

**subscriptions**
- Nulls all follow from status:

  | Column | Null when | Count |
  |---|---|---|
  | `trial_started_at` | imported on Jan 1, 2024 (3,850) or a reactivation (243): neither had a trial | 4,093 |
  | `started_at` | never paid: `trialing` (933) or `trial_expired` (21,377) | 22,310 |
  | `ended_at` | still live: `active`, `past_due`, `trialing` | 6,051 |
  | `cancel_requested_at` | no cancellation requested | 27,998 |
- `cancel_requested_at` is set on 58 `active` subscriptions (cancellation pending at their period end) and on
  4 `lapsed` ones (they lapsed before the cancellation took effect), so it doesn't by itself mean cancelled.
- Trials carry `subscription_amount_cents` (the would-be price) and use `current_period_start/end` for the trial
  window.
- Imported subscriptions have `started_at` and `current_period_start` before 2024, but no history before Jan 1, 2024.
- 239 accounts have more than one subscription (reactivations get a new `subscription_id`).

**subscription_events**
- `subscription_amount_cents` is null for trial events only (`trial_started`, `trial_expired`): 48,042 rows.
  For scheduled changes it's the amount projected when requested; `renewed` events carry the realized amount.
- **Duplicates**: 784 retried webhooks: same content, new `event_id`, later `ingested_at`. Spread across every
  event type (412 of them `renewed`).
- **Late arrivals**: 1,568 events ingested 1–5 days after `requested_at`; 5 were ingested after the data window
  ended. Incremental models filtering on `ingested_at` need a lookback window.
- **Scheduled changes**: 4,556 `plan_updated` (decreases, downgrades, frequency switches) and 2,495 `cancelled`
  events have `effective_at` later than `requested_at`. 488 take effect after the data window.
- **Changes that never happened**: scheduled events stay in the log even when they never took effect. 34 have
  `effective_at` after the subscription lapsed (30 `plan_updated`, 4 `cancelled`), and 146 more `plan_updated`
  events were scheduled for the same period end as a cancellation, which drops them (no renewal happens). See
  `int_subscription_change_requests.outcome`.
- `attributes` is a JSON string whose keys depend on `event_type`. Missing values are JSON `null`, which is not
  SQL `NULL`: `parse_json(attributes):x is not null` is true for them. Use `is_null_value()`, or cast first.
- 34 `subscription_imported` rows (33 subscriptions; one row is a retried-webhook copy) carry a pending
  `cancel_requested_at` in `attributes`, the only record of cancellations requested before the cutover.
- Genuine look-alikes to keep: 60 seat increases repeated by the same account on the same day, with different
  `requested_at` values and separate proration invoices.

**invoices**
- No nulls.
- Every invoice has exactly one line item today. That's a generator choice, so models shouldn't rely on it.
- `due_at` equals `issued_at` for card invoices (charged immediately) and is 30 days later for invoice payment.
- `status` is as of the end of the window: card `paid` 93,594 / `uncollectible` 548 / `past_due` 54; invoice
  payment `paid` 2,921 / `uncollectible` 90 / `open` 58 / `past_due` 29 / `partially_paid` 5.
- No paid date column; derive it from `payments`.

**invoice_line_items**
- No nulls, no duplicates.
- A first period that starts mid-day has `service_period_start` at the conversion time; every other boundary is
  00:00 UTC. Proration lines start at 00:00 UTC the day after the change.

**payments**
- **Duplicates**: 209 rows loaded twice, identical in every column. Remove with `select distinct` or by
  `payment_id`.
- `attempt_number` is null for invoice payments (`cheque`, `bank_transfer`): 3,400 rows.
- `failure_reason` is null for every succeeded payment and set for every failed one (7,633 failed card attempts).
- Failed attempts record the amount that was attempted; only `succeeded` rows are money received.
- 295 invoices were paid in more than one succeeded payment (partial payments).
