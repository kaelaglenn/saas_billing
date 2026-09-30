# Billing Data Generator Spec — B2B SaaS Portfolio Project

## 1. Purpose and outputs

Generate realistic, deliberately messy billing and subscription data for a fictional B2B SaaS company, to be modeled in dbt as a portfolio project. The generator also writes a separate ground truth answer key so the dbt models can be tested against known results.

**Build approach (instructions for Claude Code)**

- Python 3 with numpy and pandas. Put every rate, mix, and probability in a single config.yaml so tuning never means editing code.

- Deterministic: one fixed random seed (default 42) produces identical output on every run.

- Simulate day by day as an event-driven state machine. Each subscription's state changes only through events, and invoices and payments are derived from those events. This keeps the tables consistent with each other.

- Build in stages with tests at each stage: (1) clean simulation with no messiness, (2) validation checks passing, (3) data-quality problems (section 7: duplicates and late-arriving records) injected as a separate step that only touches the raw output. Business complexity such as mid-period changes, dunning, and partial payments is part of the simulation itself, so it is reflected in the ground truth.

- Amounts are integer cents everywhere. Whenever rounding is needed, round in the customer's favor (charges round down).

**Output files**

- data/raw/: accounts, subscriptions, subscription_events, invoices, invoice_line_items, payments, each as Parquet and CSV.

- data/truth/: the ground truth files described in section 8. These are never loaded as dbt sources.

- data/truth/seeded_anomalies: a manifest listing every injected piece of messiness and the record IDs it touched.

**Data window:** Jan 1, 2024 through Sep 30, 2026. The company and many customers existed before 2024; the data simply starts then (see Opening state in section 3).

## 2. Pricing and plans

| Plan    | Monthly, per seat     | Annual, per seat (10% off) |
|---------|-----------------------|----------------------------|
| Pro     | \$19.00 (1,900 cents) | \$205.20 (20,520 cents)    |
| Premium | \$29.00 (2,900 cents) | \$313.20 (31,320 cents)    |

- USD only, no tax, no discounts or coupons other than the annual discount.

- Every seat on a subscription is on the same plan. No seat minimum.

- Price per billing period = seats × per-seat price for that plan and frequency.

## 3. Subscription lifecycle rules

One account per customer. An account holds at most one live subscription at a time. A returning customer keeps their account and gets a new subscription.

**Trials**

- Every new customer starts a 30-day free trial on a chosen plan and seat count. No invoices during the trial.

- 16% of trials convert. Conversion can happen any day during the trial and is effective immediately. The paid subscription's billing anchor is the conversion date.

- Trials that don't convert end at day 30 with a trial_expired event.

- Returning customers do not get a new trial.

**Billing periods and renewal**

- Billing periods start and end at 00:00 UTC. The company reports in America/New_York (ET), so a renewal at 00:00 UTC falls on the evening before in ET.

- A subscription that starts at any time on date D has its first period end at 00:00 UTC on the day after the anniversary of D, with D taken as a UTC date. So the customer gets the rest of the start day free, and every later period runs midnight to midnight UTC.

- Monthly anniversaries on days 29–31 clamp to the last day of shorter months (Jan 31 → Feb 28 → Mar 31).

- At each period end the subscription renews automatically: a renewed event and a new renewal invoice.

**Mid-period changes (event type plan_updated)**

Each plan_updated event changes exactly one dimension: plan, seats, or billing frequency. Every change event carries requested_at and effective_at.

- **Increases** (plan upgrade or added seats): effective immediately (effective_at = requested_at). Billed as a prorated charge for the rest of the current period (section 4).

- **Decreases** (plan downgrade or removed seats): effective at the next renewal (effective_at = current period end). No refund. The customer keeps full access until then.

- **Billing frequency changes**: effective at the next renewal. No refund in v1. Invoice payment is only allowed with annual billing, so an invoice-paying customer who switches to monthly moves to card payment at that renewal.

- A customer can make several changes in one period, including an increase and a decrease of seats. Apply them in time order. A later decrease is measured against the seat count at the renewal it takes effect on.

**Voluntary cancellation (event type cancelled)**

- requested_at is when the customer cancels; effective_at is the current period end. No refund in v1. Access continues until effective_at.

- Record a cancellation reason in the event attributes (for example price, switched tool, company closed, no longer needed).

**Involuntary cancellation (event type lapsed)**

- Triggered by the dunning rules in section 4, effective at the moment the final payment attempt fails (cards) or the invoice reaches 60 days past due (invoices).

**Reactivation**

- A churned account (either cancelled or lapsed) can return: a new subscription with a new subscription_id on the same account_id, started with a subscription_started event that has is_reactivation = true in its attributes.

**Opening state (Jan 1, 2024)**

- Accounts created before 2024 appear in accounts with their real creation dates (2019–2023).

- Each subscription active on Jan 1, 2024 gets a subscription_imported event at 2024-01-01 00:00 UTC recording its plan, seats, frequency, payment method, and current period end. This represents the billing system's historical cutover.

- No invoices or payments before 2024. An imported subscription's first invoice is its first renewal in 2024.

**Event types:** trial_started, trial_expired, subscription_started, subscription_imported, plan_updated, renewed, cancelled, lapsed.

## 4. Billing, proration, and payment rules

**Invoices**

- A **renewal invoice** is issued at the start of every paid period (including the first period after conversion or reactivation). Its line item reflects the plan, seats, and frequency in effect at that moment, including any decreases scheduled for that renewal.

- A **proration invoice** is issued immediately for each increase (upgrade or added seats), one line item per change.

- Payment method is set per subscription: card or invoice. Invoice payment is only available with annual billing; monthly subscriptions always pay by card.

**Proration (to the day, in the customer's favor)**

- remaining_days = whole days from 00:00 UTC on the day after the change to the period end. The day of the change is free.

- period_days = total days in the current period.

- Added seats: floor(added_seats × per_seat_price × remaining_days / period_days).

- Plan upgrade: floor(seats × (new_price − old_price) × remaining_days / period_days).

- Prices use the subscription's current frequency (annual prorations use annual per-seat prices).

**Card payments and retries (dunning)**

- Cards are charged when the invoice is issued. That moment is the due date.

- On failure, retry weekly: attempt 2 at +7 days, attempt 3 at +14 days. The subscription is past_due from the first failure and keeps full access.

- Recovery paths: a later retry succeeds, or the customer updates their card between attempts, which triggers an immediate successful attempt.

- If attempt 3 fails, the subscription lapses at that moment (lapsed event, 14 days after the due date).

**Invoice payments (cheque or bank transfer)**

- Terms are Net 30: due_at = issued_at + 30 days.

- After due_at with a balance remaining, the subscription is past_due and keeps access.

- Partial payments are allowed. Each payment is its own row. The subscription stays past_due until the full amount is paid.

- If the invoice is still not fully paid at 60 days past due (90 days after issue), the subscription lapses and the invoice is marked uncollectible.

**Overlaps**

- Changes while past_due are allowed and work normally. New proration invoices add to the amount owed.

- A scheduled decrease or cancellation is dropped if the subscription lapses first.

## 5. Volume, growth, and seasonality

Targets are outcomes to calibrate toward, not exact values. All numbers live in config.yaml.

**Size and growth**

- About 3,850 active paid subscriptions on Jan 1, 2024, growing to about 5,000 by Sep 30, 2026 (roughly 10% net growth per year).

- Blended monthly logo churn around 2–3%, a realistic range for SMB SaaS. Gross new paid customers each month must replace that churn plus the growth, which means roughly 800–900 trial starts in an average month at 16% conversion.

**Churn drivers**

- Monthly-billed customers: about 2.2% cancel voluntarily each month.

- Annual customers can only leave at renewal: about 12% cancel at each renewal.

- Card charges: about 5% fail on the first attempt. Of those, about 45% recover on a retry, 30% recover after a card update, and 25% lapse.

- Invoices: about 70% paid by the due date, 27% paid late (some in partial payments), 3% never paid (lapse).

- Together, involuntary churn (lapsed) should be roughly 20–25% of all churn.

- Reactivation: about 10% of churned accounts return within 18 months, skewed toward lapsed accounts (roughly 18% of lapsed accounts versus 8% of voluntarily cancelled ones). Many lapses are accidental, like an expired card or a missed invoice, so those customers are more likely to come back.

**Customer mix at signup**

- Plan: 65% Pro, 35% Premium.

- Frequency: 70% monthly, 30% annual.

- Payment method: all monthly subscriptions pay by card. About 40% of annual subscriptions pay by invoice (roughly 12% of all customers), skewed toward accounts with 20+ seats.

- Seats: right-skewed (log-normal), median about 6, range 1–250.

- Accounts also get an industry and a company size band for segmentation.

**Monthly change rates per active subscription**

- Add seats 4%, remove seats 2%, plan upgrade 1.2%, plan downgrade 0.6%, billing frequency switch 0.5%.

- About 15% of subscriptions with a seat change make a second, opposite seat change in the same period.

**Seasonality and variability (multipliers on trial starts)**

| Jan  | Feb  | Mar  | Apr  | May  | Jun  | Jul  | Aug  | Sep  | Oct  | Nov  | Dec  |
|------|------|------|------|------|------|------|------|------|------|------|------|
| 1.00 | 1.00 | 1.15 | 1.20 | 1.20 | 1.15 | 0.95 | 0.90 | 1.15 | 1.00 | 0.90 | 0.70 |

- Multiply each month by random noise (mean 1.0, standard deviation about 0.10) so no two months or years match.

- Draw a separate baseline per year (±8%) so year-over-year growth varies.

- Add one configurable shock: churn about 30% higher for two consecutive months in mid-2025. It gives the data a story to find.

## 6. Table schemas

All timestamps are UTC except accounts, which stores naive local ET datetimes with no offset (a deliberate source quirk). IDs are prefixed strings. Money is integer cents.

**accounts** (one row per customer)

| Column | Type | Notes |
|----|----|----|
| account_id | string | acct_000001 |
| company_name | string | Synthetic |
| industry | string | For segmentation |
| company_size_band | string | For example 1–10, 11–50, 51–200, 201+ |
| created_at | datetime (naive ET) | 2019–2026 |
| updated_at | datetime (naive ET) | Last change to the row |

**subscriptions** (current state only, overwritten on every change like an application database)

| Column | Type | Notes |
|----|----|----|
| subscription_id | string | sub_000001 |
| account_id | string |  |
| status | string | trialing, active, past_due, cancelled, lapsed, trial_expired |
| plan | string | pro, premium (current) |
| seats | int | Current |
| billing_frequency | string | monthly, annual (current) |
| subscription_amount_cents | int | Amount charged each billing period at the current plan, seats, and frequency (seats × per-seat price). Not the same as MRR for annual plans. |
| payment_method | string | card, invoice |
| trial_started_at | timestamp | Null for reactivations and imported subscriptions |
| started_at | timestamp | Paid start (conversion or reactivation) |
| current_period_start | timestamp |  |
| current_period_end | timestamp |  |
| cancel_requested_at | timestamp | Null unless a cancellation is pending or done |
| ended_at | timestamp | Null unless cancelled, lapsed, or trial expired |
| updated_at | timestamp |  |

**subscription_events** (append-only history)

| Column | Type | Notes |
|----|----|----|
| event_id | string | evt\_… |
| subscription_id | string |  |
| account_id | string |  |
| event_type | string | See section 3 |
| requested_at | timestamp | When the customer or system acted |
| effective_at | timestamp | When it takes effect |
| attributes | JSON string | For example change_type, from/to values, reason, is_reactivation |
| ingested_at | timestamp | When the row landed in the warehouse (later than requested_at) |
| subscription_amount_cents | int | Per-period amount in effect once this event takes effect. Null for trial events. |

**invoices**

| Column | Type | Notes |
|----|----|----|
| invoice_id | string | inv\_… |
| account_id, subscription_id | string |  |
| invoice_type | string | renewal, proration |
| payment_method | string | card, invoice |
| issued_at | timestamp |  |
| due_at | timestamp | Equals issued_at for cards, +30 days for invoices |
| amount_due_cents | int | Sum of line items |
| status | string | open, paid, partially_paid, past_due, uncollectible (current) |

**invoice_line_items**

| Column | Type | Notes |
|----|----|----|
| line_item_id | string |  |
| invoice_id | string |  |
| line_type | string | subscription, seat_proration, plan_proration |
| plan, billing_frequency | string |  |
| quantity | int | Seats charged |
| unit_price_cents | int | Per seat, per period |
| service_period_start, service_period_end | timestamp |  |
| amount_cents | int |  |

**payments** (one row per attempt or received payment)

| Column | Type | Notes |
|----|----|----|
| payment_id | string | pay\_… |
| invoice_id, account_id | string |  |
| method | string | card, cheque, bank_transfer |
| attempted_at | timestamp |  |
| attempt_number | int | 1–3 for card retries; null for invoice payments |
| amount_cents | int | May be less than the balance for partial payments |
| status | string | succeeded, failed |
| failure_reason | string | For example insufficient_funds, card_expired, card_declined |

## 7. Seeded messiness

Applied as a final step to data/raw/ only, and logged in data/truth/seeded_anomalies. The simulation's business rules (late payments, dunning, scheduled changes) already create realistic complexity; this section adds data-quality problems on top.

**Timezones**

- accounts stores naive ET datetimes while every other table is UTC. Joining on raw dates without converting shifts accounts created late in the evening by a day.

- Billing periods start at 00:00 UTC, which is 7 or 8 p.m. ET the evening before, depending on daylight saving time. A renewal at 00:00 UTC on the 1st belongs to the previous month in ET reporting, so deriving months with DATE(ts) in UTC instead of ET puts it in the wrong month.

- Make sure the data includes renewals and changes across both DST transitions each year, including at least one plan change inside the repeated 1:00–2:00 a.m. ET hour in November.

**True duplicates (should be removed)**

- About 0.5% of subscription_events re-emitted with a new event_id, identical requested_at, effective_at, and attributes, and a later ingested_at (seconds to hours later), simulating a retried webhook.

- About 0.2% of payments rows loaded twice with the same payment_id, simulating a double load.

**Legitimate look-alikes (must be kept)**

- About 1% of seat increases are followed by a second, identical increase from the same account on the same day. These are genuine: they have different requested_at values and each has its own proration line item.

**Late arrival**

- About 1% of events arrive late: ingested_at is 1–5 days after requested_at, so an incremental model filtering on ingested_at must use a lookback window.

**Business-rule complexity already produced by the simulation**

- Scheduled decreases and cancellations (effective_at later than requested_at).

- Multiple changes per period, including opposite seat changes.

- Card failures, retries, card updates, and lapses.

- Late and partial invoice payments, and uncollectible invoices.

- Reactivations on existing accounts with new subscription IDs.

- Imported subscriptions with no history before Jan 1, 2024.

## 8. Ground truth, MRR definition, and validation

**MRR definition**

- Monthly subscriptions: seats × monthly per-seat price.

- Annual subscriptions: seats × annual per-seat price (with the 10% discount) ÷ 12.

- Measured at the end of each month in ET (the reporting timezone).

- Trials contribute 0. past_due subscriptions still count until they lapse.

- Increases count from effective_at (immediately); decreases and cancellations count from their later effective_at, not from when they were requested.

**Ground truth files (data/truth/)**

- mrr_monthly: one row per subscription per month-end: MRR in cents, plan, seats, frequency, status, and movement type (new, expansion, contraction, churn, reactivation, unchanged).

- subscription_history: the true plan, seats, frequency, and status over time as valid-from / valid-to ranges (what a correct SCD Type 2 model should reproduce).

- churn_events: every churn with its type (cancelled or lapsed) and effective date.

- monthly_summary: per month, trial starts, conversions, reactivations, churn by type, ending active subscriptions, and total MRR.

- seeded_anomalies: every injected duplicate and late-arriving record, with IDs.

**Validation checks the generator must pass before writing output** (run on clean data before messiness is injected)

- Every invoice's amount_due_cents equals the sum of its line items, every subscription_amount_cents equals seats × the per-seat price for its plan and frequency, and no monthly subscription pays by invoice.

- Succeeded payments on an invoice never exceed the amount due.

- No subscription has events after its ended_at except a reactivation on a new subscription.

- No account has two live subscriptions at the same time.

- Every plan_updated changes exactly one dimension, and every decrease has effective_at at a period end.

- Ending active subscriptions and churn rates fall within the targets in section 5; print a summary table after each run.

## 9. Out of scope for v1, and assumptions to confirm

**Out of scope for v1**

- All refunds: annual-to-monthly switch refunds and exception refunds on cancellation come in v2. When added, a refund is cash back to the original payment method, recorded as a negative row in payments linked to the original payment.

- Account credits, taxes, other currencies, and coupons.

- Reversing a scheduled downgrade or cancellation before it takes effect.

- Product usage events (Alder-inspired) and a sales pipeline: planned v2 sources.

- Loading into a warehouse. The generator only writes files, so the same data works in BigQuery or DuckDB.

**Assumptions made in this spec (confirm or change)**

- [x] "5,000 customers at the end" means about 5,000 active paid subscriptions on Sep 30, 2026, not counting trials.

- [ ] Blended monthly churn of 2–3% (rather than 4% per year, which would be unusually low for SMB SaaS).

- [x] "Midnight after the signup anniversary" means the customer gets the rest of the start day free, and periods run 00:00 UTC to 00:00 UTC.

- [ ] Monthly anniversaries on days 29–31 clamp to the last day of shorter months.

- [ ] Pre-2024 subscriptions enter the data through one subscription_imported event each on Jan 1, 2024, with no earlier invoices.

- [ ] ET is also the reporting timezone for months and MRR.

- [ ] Returning customers don't get a second free trial.

- [ ] Scheduled decreases and cancellations are dropped if the subscription lapses first.
