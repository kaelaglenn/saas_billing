-- Accumulating snapshot: one row per invoice, with its milestones (issued,
-- due, first payment, fully paid, became overdue, written off) and how it
-- turned out. Outcome rules live in int_invoice_payment_summary.

with

invoices as (

    select * from {{ ref('int_invoice_payment_summary') }}

),

final as (

    select
        invoice_id,
        subscription_id,
        account_id,
        invoice_type,
        payment_method,
        payment_outcome,
        amount_due_cents,
        amount_paid_cents,
        outstanding_cents,
        written_off_cents,
        succeeded_payment_count,
        card_attempt_count,
        failed_attempt_count,
        days_to_pay,
        has_partial_payments,
        overdue_from is not null as has_been_overdue,
        issued_at,
        due_at,
        first_payment_at,
        paid_at,
        overdue_from as became_overdue_at,
        written_off_at,
        {{ to_reporting_date('issued_at') }} as issued_date_et,
        date_trunc(
            'month', {{ to_reporting_date('issued_at') }}
        ) as issued_month_et,
        {{ to_reporting_date('due_at') }} as due_date_et,
        {{ to_reporting_date('paid_at') }} as paid_date_et,
        {{ to_reporting_date('written_off_at') }} as written_off_date_et
    from invoices

)

select * from final
