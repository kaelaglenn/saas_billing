-- Evidence behind int_card_dunning_outcomes' inferred card updates: failed card
-- attempts only ever happen at issue or exactly on the weekly retry schedule
-- (+7, +14 days). Off-schedule attempts are therefore customer-triggered (a
-- card update), and they only ever succeed. If this fails, the source has
-- started failing off-schedule attempts and the recovered_after_card_update
-- rule needs revisiting. Returns failed attempts off the schedule.

with

card_attempts as (

    select
        payments.payment_id,
        payments.invoice_id,
        payments.attempt_number,
        payments.payment_status,
        datediff(
            'second',
            min(payments.attempted_at) over (
                partition by payments.invoice_id
            ),
            payments.attempted_at
        ) as seconds_after_first_attempt
    from {{ ref('stg_billing__payments') }} as payments
    where payments.payment_method = 'card'

)

select *
from card_attempts
where
    payment_status = 'failed'
    and mod(seconds_after_first_attempt, 7 * 86400) != 0
