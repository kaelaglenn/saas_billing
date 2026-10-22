-- Each subscription's current history row should match the source system's
-- own current-state table, which it maintains separately from the event log.
-- Returns mismatches (and subscriptions missing from either side); passes
-- when empty.

with

current_history as (

    select * from {{ ref('int_subscription_history') }}
    where is_current

),

source_current as (

    select * from {{ ref('stg_billing__subscriptions') }}

)

select
    coalesce(
        current_history.subscription_id, source_current.subscription_id
    ) as subscription_id,
    current_history.subscription_status as history_status,
    source_current.subscription_status as source_status,
    current_history.plan as history_plan,
    source_current.plan as source_plan,
    current_history.seats as history_seats,
    source_current.seats as source_seats,
    current_history.billing_frequency as history_billing_frequency,
    source_current.billing_frequency as source_billing_frequency
from current_history
full outer join source_current
    on current_history.subscription_id = source_current.subscription_id
where
    current_history.subscription_id is null
    or source_current.subscription_id is null
    or current_history.subscription_status
    != source_current.subscription_status
    or current_history.plan != source_current.plan
    or current_history.seats != source_current.seats
    or current_history.billing_frequency != source_current.billing_frequency
