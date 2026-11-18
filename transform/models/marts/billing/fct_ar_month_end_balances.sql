-- Periodic snapshot: accounts receivable at each reporting month-end, one row
-- per invoice still owed at the cutoff (issued, not fully paid, not written
-- off), with its balance and aging bucket. Rules live in
-- int_invoice_month_end_balances.

with

balances as (

    select * from {{ ref('int_invoice_month_end_balances') }}

),

final as (

    select
        invoice_month_id,
        invoice_id,
        subscription_id,
        account_id,
        payment_method,
        month_start_date_et,
        month_end_date_et,
        aging_bucket,
        amount_due_cents,
        balance_cents,
        days_past_due,
        is_month_closed,
        due_at,
        month_ended_at
    from balances

)

select * from final
