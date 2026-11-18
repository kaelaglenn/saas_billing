-- Transaction fact: one row per payment attempt, failed or succeeded. Card
-- attempts are charges for the full amount due; cheque and bank transfer
-- payments (invoice payment terms) never fail and can be partial. Only
-- succeeded attempts are money received.

with

payments as (

    select * from {{ ref('stg_billing__payments') }}

),

invoices as (

    select
        invoice_id,
        subscription_id
    from {{ ref('stg_billing__invoices') }}

),

final as (

    select
        payments.payment_id,
        payments.invoice_id,
        invoices.subscription_id,
        payments.account_id,
        payments.payment_method,
        payments.payment_status,
        payments.failure_reason,
        payments.attempt_number,
        payments.amount_cents as attempted_amount_cents,
        iff(
            payments.payment_status = 'succeeded', payments.amount_cents, 0
        ) as received_amount_cents,
        payments.payment_status = 'succeeded' as is_succeeded,
        payments.attempted_at,
        {{ to_reporting_date('payments.attempted_at') }} as attempted_date_et,
        date_trunc(
            'month', {{ to_reporting_date('payments.attempted_at') }}
        ) as attempted_month_et
    from payments
    inner join invoices
        on payments.invoice_id = invoices.invoice_id

)

select * from final
