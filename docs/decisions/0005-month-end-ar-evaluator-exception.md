# 0005. Let month-end AR read payments directly and through the invoice summary

- **Status:** Proposed
- **Date:** 2026-11-17
- **Related:** [0004](0004-conformed-calendar-evaluator-exception.md), `int_invoice_month_end_balances`,
  `int_invoice_payment_summary`, `seeds/dbt_project_evaluator_exceptions.csv`

## Context

`dbt_project_evaluator` flags `fct_rejoining_of_upstream_concepts` when a model reads a parent both directly and
through another model. `int_invoice_month_end_balances` (accounts receivable at each reporting month-end) reads
`stg_billing__payments` directly and through `int_invoice_payment_summary`.

The two reads serve different grains. The summary is one row per invoice, as of the end of the data: it supplies
`paid_at`, `written_off_at`, `due_at` and the amount due, which decide whether an invoice is owed at a cutoff.
The balance at each cutoff needs every payment's timestamp, to sum only what was received before it (295
invoices were paid in more than one payment), and that detail is gone once payments are aggregated per invoice.

The obvious restructure doesn't remove the rejoin. Without the summary, the model would need write-off dates from
`int_invoice_delinquency_periods`, which also reads payments, and it would repeat the summary's paid and
written-off rules.

The model is verified independently: an AR roll-forward (opening + invoiced − received − written off = closing)
reconciles in all 34 months, and the latest month-end equals the source's open, partially paid and past-due
invoices (146 invoices, $279,000.97).

## Decision

We add an exception to the project's evaluator exceptions seed for `fct_rejoining_of_upstream_concepts`, matched
on `child = int_invoice_month_end_balances`, extending the exception policy set in ADR 0004.

## Alternatives considered

- **Restructure the model to read only one of the two.** Lost: it would copy the paid and written-off rules into
  a second model and still rejoin payments through `int_invoice_delinquency_periods`.
- **Match the exception on `parent = stg_billing__payments`.** Lost: it would excuse every future rejoin of
  payments anywhere in the project, not just this one.

## Consequences

- The evaluator check passes again; the full build's only warnings are the two documented raw-source duplicates.
- Any other model that rejoins payments is still flagged.
- Scoping by child excuses this model for any parent, not only payments. A new rejoin added to this model later
  wouldn't be flagged, so review its inputs when changing it.
- Revisit if a model of payments received per month-end cutoff is ever built: the AR model could read that instead
  of raw payments and drop the exception.
