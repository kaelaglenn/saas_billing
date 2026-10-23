-- The latest month-end state should equal the source system's current-state
-- table. Assumes nothing happens between the data watermark and the latest
-- cutoff, which holds when the cutoff is the first one after the end of the
-- data; if this fails, check that assumption first. Compared in both
-- directions:
--   every latest-month row matches the source on status, plan, seats, and
--   frequency
--   every live or trialing source subscription has a latest-month row
-- Returns disagreements; passes when empty.

with

latest_month as (

    select max(month_start_date) as month_start_date
    from {{ ref('int_reporting_months') }}

),

latest_states as (

    select states.*
    from {{ ref('int_subscription_month_end_states') }} as states
    inner join latest_month
        on states.month_start_date = latest_month.month_start_date

),

source_current as (

    select * from {{ ref('stg_billing__subscriptions') }}

)

select
    coalesce(
        latest_states.subscription_id, source_current.subscription_id
    ) as subscription_id,
    latest_states.subscription_status as month_end_status,
    source_current.subscription_status as source_status,
    latest_states.plan as month_end_plan,
    source_current.plan as source_plan,
    latest_states.seats as month_end_seats,
    source_current.seats as source_seats
from latest_states
full outer join source_current
    on latest_states.subscription_id = source_current.subscription_id
where
    -- a latest-month row that disagrees with the source
    (
        latest_states.subscription_id is not null
        and (
            source_current.subscription_id is null
            or latest_states.subscription_status
            != source_current.subscription_status
            or latest_states.plan != source_current.plan
            or latest_states.seats != source_current.seats
            or latest_states.billing_frequency
            != source_current.billing_frequency
        )
    )
    -- a live or trialing source subscription with no latest-month row
    or (
        latest_states.subscription_id is null
        and source_current.subscription_status in (
            'trialing', 'active', 'past_due'
        )
    )
