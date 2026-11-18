-- One row per invoice: what was paid, when it was fully paid, and how it
-- turned out.
--   payment_outcome
--     paid_on_time: fully paid and never overdue (card: the first charge
--                   succeeded; invoice: paid by due_at)
--     paid_late:    fully paid after being overdue
--     written_off:  overdue, then written off (dunning ran out or the
--                   subscription lapsed)
--     overdue:      overdue and still unpaid at the end of the data
--     open:         not yet due and not fully paid (invoice payment only)
-- Overdue and write-off rules live in int_invoice_delinquency_periods.

with

invoices as (

    select * from {{ ref('stg_billing__invoices') }}

),

payments as (

    select * from {{ ref('stg_billing__payments') }}

),

delinquencies as (

    select * from {{ ref('int_invoice_delinquency_periods') }}

),

payment_totals as (

    select
        invoice_id,
        sum(
            iff(payment_status = 'succeeded', amount_cents, 0)
        ) as amount_paid_cents,
        count_if(payment_status = 'succeeded') as succeeded_payment_count,
        count_if(payment_method = 'card') as card_attempt_count,
        count_if(payment_status = 'failed') as failed_attempt_count,
        min(
            iff(payment_status = 'succeeded', attempted_at, null)
        ) as first_payment_at
    from payments
    group by invoice_id

),

-- Running total of money received per invoice, in the order it arrived.
received_running_total as (

    select
        invoice_id,
        attempted_at,
        sum(amount_cents) over (
            partition by invoice_id
            order by attempted_at, payment_id
        ) as cumulative_received_cents
    from payments
    where payment_status = 'succeeded'

),

fully_paid as (

    select
        invoices.invoice_id,
        min(received.attempted_at) as paid_at
    from invoices
    inner join received_running_total as received
        on invoices.invoice_id = received.invoice_id
    where received.cumulative_received_cents >= invoices.amount_due_cents
    group by invoices.invoice_id

),

combined as (

    select
        invoices.invoice_id,
        invoices.subscription_id,
        invoices.account_id,
        invoices.invoice_type,
        invoices.payment_method,
        case
            when
                fully_paid.paid_at is not null
                and delinquencies.invoice_id is null
                then 'paid_on_time'
            when fully_paid.paid_at is not null then 'paid_late'
            when delinquencies.end_reason = 'written_off' then 'written_off'
            when delinquencies.invoice_id is not null then 'overdue'
            else 'open'
        end as payment_outcome,
        invoices.amount_due_cents,
        coalesce(payment_totals.amount_paid_cents, 0) as amount_paid_cents,
        coalesce(
            payment_totals.succeeded_payment_count, 0
        ) as succeeded_payment_count,
        coalesce(payment_totals.card_attempt_count, 0) as card_attempt_count,
        coalesce(
            payment_totals.failed_attempt_count, 0
        ) as failed_attempt_count,
        invoices.issued_at,
        invoices.due_at,
        payment_totals.first_payment_at,
        fully_paid.paid_at,
        delinquencies.delinquent_from as overdue_from,
        delinquencies.written_off_at
    from invoices
    left join payment_totals
        on invoices.invoice_id = payment_totals.invoice_id
    left join fully_paid
        on invoices.invoice_id = fully_paid.invoice_id
    left join delinquencies
        on invoices.invoice_id = delinquencies.invoice_id

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
        iff(
            payment_outcome in ('overdue', 'open'),
            amount_due_cents - amount_paid_cents,
            0
        ) as outstanding_cents,
        iff(
            payment_outcome = 'written_off',
            amount_due_cents - amount_paid_cents,
            0
        ) as written_off_cents,
        succeeded_payment_count,
        card_attempt_count,
        failed_attempt_count,
        -- whole days from issue to full payment (0 = paid within 24 hours)
        floor(
            datediff('second', issued_at, paid_at) / 86400
        )::number(38, 0) as days_to_pay,
        succeeded_payment_count > 1 as has_partial_payments,
        issued_at,
        due_at,
        first_payment_at,
        paid_at,
        overdue_from,
        written_off_at
    from combined

)

select * from final
