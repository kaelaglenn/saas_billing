-- One row per invoice that went overdue: when it became overdue, and when and
-- how the overdue period ended.
--   became overdue
--     card:    at the first failed charge attempt
--     invoice: at due_at, if not fully paid by then (Net 30)
--   ended
--     paid:        a charge succeeded, or cumulative payments covered the
--                  amount due
--     written_off: dunning ran out (card: 3rd failed attempt; invoice: 60
--                  days past due), or the subscription lapsed over another
--                  invoice first
--   still overdue at the end of the data: ended_at is null

with

invoices as (

    select * from {{ ref('stg_billing__invoices') }}

),

payments as (

    select * from {{ ref('stg_billing__payments') }}

),

lapses as (

    select
        subscription_id,
        effective_at as lapsed_at
    from {{ ref('stg_billing__subscription_events') }}
    where event_type = 'lapsed'

),

-- Due dates and dunning deadlines after the watermark haven't happened yet.
watermark as (

    select data_as_of from {{ ref('int_data_watermark') }}

),

card_delinquency as (

    select
        invoices.invoice_id,
        min(
            iff(
                payments.payment_status = 'failed',
                payments.attempted_at,
                null
            )
        ) as delinquent_from,
        min(
            iff(
                payments.payment_status = 'succeeded',
                payments.attempted_at,
                null
            )
        ) as paid_at,
        -- the final retry failing exhausts dunning
        min(
            iff(
                payments.payment_status = 'failed'
                and payments.attempt_number = 3,
                payments.attempted_at,
                null
            )
        ) as dunning_exhausted_at
    from invoices
    inner join payments
        on invoices.invoice_id = payments.invoice_id
    where invoices.payment_method = 'card'
    group by invoices.invoice_id
    having count_if(payments.payment_status = 'failed') > 0

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

invoice_payment_delinquency as (

    select
        invoices.invoice_id,
        invoices.due_at as delinquent_from,
        min(
            iff(
                received.cumulative_received_cents
                >= invoices.amount_due_cents,
                received.attempted_at,
                null
            )
        ) as paid_at,
        -- 60 days past due exhausts dunning, once that moment is in the data
        iff(
            dateadd(day, 60, invoices.due_at) <= watermark.data_as_of,
            dateadd(day, 60, invoices.due_at),
            null
        ) as dunning_exhausted_at
    from invoices
    cross join watermark
    left join received_running_total as received
        on invoices.invoice_id = received.invoice_id
    where
        invoices.payment_method = 'invoice'
        and invoices.due_at <= watermark.data_as_of
    group by invoices.invoice_id, invoices.due_at, watermark.data_as_of
    -- overdue only if not fully paid by the due date
    having paid_at is null or paid_at > invoices.due_at

),

delinquencies as (

    select * from card_delinquency
    union all
    select * from invoice_payment_delinquency

),

with_write_off as (

    select
        delinquencies.invoice_id,
        invoices.subscription_id,
        invoices.account_id,
        invoices.payment_method,
        delinquencies.delinquent_from,
        delinquencies.paid_at,
        -- written off when dunning runs out, or earlier if the subscription
        -- lapsed (over this or another invoice) while this one was unpaid
        iff(
            delinquencies.paid_at is null,
            least_ignore_nulls(
                delinquencies.dunning_exhausted_at,
                iff(
                    lapses.lapsed_at >= delinquencies.delinquent_from,
                    lapses.lapsed_at,
                    null
                )
            ),
            null
        ) as written_off_at
    from delinquencies
    inner join invoices
        on delinquencies.invoice_id = invoices.invoice_id
    left join lapses
        on invoices.subscription_id = lapses.subscription_id

),

final as (

    select
        invoice_id,
        subscription_id,
        account_id,
        payment_method,
        delinquent_from,
        paid_at,
        written_off_at,
        coalesce(paid_at, written_off_at) as ended_at,
        case
            when paid_at is not null then 'paid'
            when written_off_at is not null then 'written_off'
        end as end_reason
    from with_write_off

)

select * from final
