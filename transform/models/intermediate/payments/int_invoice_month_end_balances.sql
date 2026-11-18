{{ config(materialized='table') }}

-- Accounts receivable at each reporting month-end: one row per invoice per
-- month-end cutoff at which money was owed on it (issued, not yet fully paid,
-- not yet written off). Input for AR aging. Written-off invoices leave
-- receivables at write-off.

with

months as (

    select * from {{ ref('int_reporting_months') }}

),

invoices as (

    select * from {{ ref('int_invoice_payment_summary') }}

),

succeeded_payments as (

    select
        invoice_id,
        attempted_at,
        amount_cents
    from {{ ref('stg_billing__payments') }}
    where payment_status = 'succeeded'

),

-- invoices still owed at each cutoff
owed as (

    select
        invoices.invoice_id,
        invoices.subscription_id,
        invoices.account_id,
        invoices.payment_method,
        invoices.amount_due_cents,
        invoices.due_at,
        months.month_start_date_et,
        months.month_end_date_et,
        months.month_ended_at,
        months.is_month_closed
    from invoices
    inner join months
        on
            invoices.issued_at < months.month_ended_at
            and coalesce(invoices.paid_at, '9999-12-31'::timestamp_tz)
            >= months.month_ended_at
            and coalesce(invoices.written_off_at, '9999-12-31'::timestamp_tz)
            >= months.month_ended_at

),

paid_before_cutoff as (

    select
        owed.invoice_id,
        owed.month_start_date_et,
        coalesce(sum(succeeded_payments.amount_cents), 0) as paid_cents
    from owed
    left join succeeded_payments
        on
            owed.invoice_id = succeeded_payments.invoice_id
            and owed.month_ended_at > succeeded_payments.attempted_at
    group by owed.invoice_id, owed.month_start_date_et

),

with_balance as (

    select
        owed.*,
        owed.amount_due_cents - paid_before_cutoff.paid_cents as balance_cents,
        -- any part of a day past due counts as a day
        iff(
            owed.month_ended_at <= owed.due_at,
            0,
            ceil(
                datediff('second', owed.due_at, owed.month_ended_at) / 86400
            )
        )::number(38, 0) as days_past_due
    from owed
    inner join paid_before_cutoff
        on
            owed.invoice_id = paid_before_cutoff.invoice_id
            and owed.month_start_date_et
            = paid_before_cutoff.month_start_date_et

),

final as (

    select
        {{ dbt_utils.generate_surrogate_key(
            ['invoice_id', 'month_start_date_et']
        ) }} as invoice_month_id,
        invoice_id,
        subscription_id,
        account_id,
        payment_method,
        month_start_date_et,
        month_end_date_et,
        case
            when days_past_due = 0 then 'current'
            when days_past_due <= 30 then '1-30'
            when days_past_due <= 60 then '31-60'
            when days_past_due <= 90 then '61-90'
            else '90+'
        end as aging_bucket,
        amount_due_cents,
        balance_cents,
        days_past_due,
        is_month_closed,
        due_at,
        month_ended_at
    from with_balance

)

select * from final
