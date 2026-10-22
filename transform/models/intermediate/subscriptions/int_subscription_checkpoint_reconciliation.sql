-- One row per renewal: the state the renewal recorded (actual) vs the state
-- expected from the previous checkpoint plus every change in between, both
-- immediate (effective after the previous checkpoint, up to this one) and
-- scheduled (effective at this renewal). A mismatch means events were missed
-- or double-counted, or the change logic is wrong. Built from events and
-- change requests directly, independent of int_subscription_history.

with

events as (

    select * from {{ ref('stg_billing__subscription_events') }}

),

change_requests as (

    select * from {{ ref('int_subscription_change_requests') }}

),

prices as (

    select * from {{ ref('plan_prices') }}

),

checkpoints as (

    select
        event_id,
        subscription_id,
        event_type,
        effective_at,
        plan,
        seats,
        billing_frequency,
        subscription_amount_cents,
        lag(effective_at) over (
            partition by subscription_id order by effective_at
        ) as previous_effective_at,
        lag(plan) over (
            partition by subscription_id order by effective_at
        ) as previous_plan,
        lag(seats) over (
            partition by subscription_id order by effective_at
        ) as previous_seats,
        lag(billing_frequency) over (
            partition by subscription_id order by effective_at
        ) as previous_billing_frequency
    from events
    where event_type in (
        'subscription_imported', 'subscription_started', 'renewed'
    )

),

renewals as (

    select * from checkpoints
    where event_type = 'renewed'

),

-- every non-cancellation change that should be included in each renewal
changes_in_window as (

    select
        renewals.event_id,
        change_requests.request_type,
        change_requests.seat_delta,
        change_requests.to_plan,
        change_requests.to_billing_frequency,
        change_requests.effective_at,
        change_requests.requested_at
    from renewals
    inner join change_requests
        on
            renewals.subscription_id = change_requests.subscription_id
            and change_requests.request_type != 'cancellation'
            and (
                (
                    not change_requests.is_scheduled
                    and renewals.previous_effective_at
                    < change_requests.effective_at
                    and renewals.effective_at >= change_requests.effective_at
                )
                or (
                    change_requests.is_scheduled
                    and renewals.effective_at = change_requests.effective_at
                )
            )

),

-- the latest change that actually set each attribute (a seat change or
-- frequency switch doesn't set the plan, and vice versa)
latest_plan_change as (

    select
        event_id,
        to_plan
    from changes_in_window
    where to_plan is not null
    qualify row_number() over (
        partition by event_id order by effective_at desc, requested_at desc
    ) = 1

),

latest_frequency_change as (

    select
        event_id,
        to_billing_frequency
    from changes_in_window
    where to_billing_frequency is not null
    qualify row_number() over (
        partition by event_id order by effective_at desc, requested_at desc
    ) = 1

),

expected_changes as (

    select
        changes_in_window.event_id,
        sum(coalesce(changes_in_window.seat_delta, 0)) as total_seat_delta,
        any_value(latest_plan_change.to_plan) as latest_to_plan,
        any_value(
            latest_frequency_change.to_billing_frequency
        ) as latest_to_frequency,
        count(*) as changes_applied
    from changes_in_window
    left join latest_plan_change
        on changes_in_window.event_id = latest_plan_change.event_id
    left join latest_frequency_change
        on changes_in_window.event_id = latest_frequency_change.event_id
    group by changes_in_window.event_id

),

final as (

    select
        renewals.event_id as renewal_event_id,
        renewals.subscription_id,
        renewals.effective_at as renewed_at,
        renewals.previous_effective_at as previous_checkpoint_at,
        coalesce(expected_changes.changes_applied, 0) as changes_applied,

        renewals.previous_seats
        + coalesce(expected_changes.total_seat_delta, 0) as expected_seats,
        renewals.seats as actual_seats,

        coalesce(
            expected_changes.latest_to_plan, renewals.previous_plan
        ) as expected_plan,
        renewals.plan as actual_plan,

        coalesce(
            expected_changes.latest_to_frequency,
            renewals.previous_billing_frequency
        ) as expected_billing_frequency,
        renewals.billing_frequency as actual_billing_frequency,

        renewals.seats * prices.unit_price_cents as expected_amount_cents,
        renewals.subscription_amount_cents as actual_amount_cents

    from renewals
    left join expected_changes
        on renewals.event_id = expected_changes.event_id
    left join prices
        on
            renewals.plan = prices.plan
            and renewals.billing_frequency = prices.billing_frequency

)

select
    *,
    expected_seats = actual_seats
    and expected_plan = actual_plan
    and expected_billing_frequency = actual_billing_frequency
    and expected_amount_cents = actual_amount_cents as is_reconciled
from final
