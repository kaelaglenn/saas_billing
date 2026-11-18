-- One row per card invoice whose first charge failed: how dunning (the
-- weekly retries) turned out.
--   dunning_outcome
--     recovered_on_retry:          a scheduled retry succeeded (exactly 7 or
--                                  14 days after the first attempt)
--     recovered_after_card_update: an attempt off the retry schedule
--                                  succeeded. INFERRED: no field records a card
--                                  update, but in this data off-schedule
--                                  attempts only ever succeed, which is the
--                                  pattern of a card update triggering an
--                                  immediate charge (tested in
--                                  assert_card_failures_only_on_retry_schedule)
--     written_off:                 dunning ran out, or the subscription lapsed
--     in_dunning:                  still retrying at the end of the data

with

attempts as (

    select
        payments.*,
        datediff(
            'second',
            min(payments.attempted_at) over (
                partition by payments.invoice_id
            ),
            payments.attempted_at
        ) as seconds_after_first_attempt
    from {{ ref('stg_billing__payments') }} as payments
    where payments.payment_method = 'card'

),

delinquencies as (

    select * from {{ ref('int_invoice_delinquency_periods') }}

),

invoices as (

    select * from {{ ref('stg_billing__invoices') }}

),

failed_first as (

    select
        attempts.invoice_id,
        invoices.subscription_id,
        attempts.account_id,
        attempts.attempted_at as first_failed_at,
        attempts.failure_reason as first_failure_reason
    from attempts
    inner join invoices
        on attempts.invoice_id = invoices.invoice_id
    where attempts.attempt_number = 1 and attempts.payment_status = 'failed'

),

recoveries as (

    select
        invoice_id,
        attempted_at as recovered_at,
        attempt_number as recovery_attempt_number,
        -- scheduled retries happen at exact multiples of 7 days
        mod(seconds_after_first_attempt, 7 * 86400) = 0
            as is_on_retry_schedule
    from attempts
    where payment_status = 'succeeded'

),

attempt_counts as (

    select
        invoice_id,
        count(*) as attempt_count
    from attempts
    group by invoice_id

),

final as (

    select
        failed_first.invoice_id,
        failed_first.subscription_id,
        failed_first.account_id,
        case
            when recoveries.is_on_retry_schedule then 'recovered_on_retry'
            when recoveries.recovered_at is not null
                then 'recovered_after_card_update'
            when delinquencies.end_reason = 'written_off' then 'written_off'
            else 'in_dunning'
        end as dunning_outcome,
        failed_first.first_failure_reason,
        attempt_counts.attempt_count,
        recoveries.recovery_attempt_number,
        -- whole days from the first failure to recovery
        floor(
            datediff(
                'second', failed_first.first_failed_at, recoveries.recovered_at
            ) / 86400
        )::number(38, 0) as days_to_recover,
        failed_first.first_failed_at,
        recoveries.recovered_at,
        delinquencies.written_off_at
    from failed_first
    inner join attempt_counts
        on failed_first.invoice_id = attempt_counts.invoice_id
    left join recoveries
        on failed_first.invoice_id = recoveries.invoice_id
    left join delinquencies
        on failed_first.invoice_id = delinquencies.invoice_id

)

select * from final
