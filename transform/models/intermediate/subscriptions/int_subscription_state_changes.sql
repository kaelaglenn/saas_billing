-- One row per moment something about a subscription's effective state
-- changes, carrying only what changed. int_subscription_history replays these
-- in order to rebuild the full state (event sourcing).
--   checkpoint: trial start and snapshot events record the full state
--   immediate:  seat increases and plan upgrades between checkpoints
--   past_due:   +1 when a past-due period starts, -1 when it ends
--   ending:     applied cancellation, lapse, or expired trial
-- Scheduled changes (decreases, downgrades, frequency switches) aren't rows:
-- they take effect at a renewal, whose checkpoint already includes them.

with

events as (

    select * from {{ ref('stg_billing__subscription_events') }}

),

change_requests as (

    select * from {{ ref('int_subscription_change_requests') }}

),

past_due_periods as (

    select * from {{ ref('int_subscription_past_due_periods') }}

),

checkpoints as (

    select
        subscription_id,
        account_id,
        effective_at as changed_at,
        1 as sort_order,
        'checkpoint' as change_kind,
        event_type as change_detail,
        iff(
            event_type = 'trial_started', 'trialing', 'active'
        ) as lifecycle_status,
        plan,
        seats,
        billing_frequency,
        null::integer as seat_delta,
        null::integer as past_due_change,
        event_id as source_id
    from events
    where event_type in (
        'trial_started',
        'subscription_imported',
        'subscription_started',
        'renewed'
    )

),

immediate_changes as (

    select
        subscription_id,
        account_id,
        effective_at as changed_at,
        2 as sort_order,
        'immediate' as change_kind,
        request_type as change_detail,
        null::varchar as lifecycle_status,
        to_plan as plan,
        null::integer as seats,
        null::varchar as billing_frequency,
        seat_delta,
        null::integer as past_due_change,
        change_request_id as source_id
    from change_requests
    where outcome = 'applied' and not is_scheduled

),

past_due_starts as (

    select
        subscription_id,
        account_id,
        past_due_from as changed_at,
        3 as sort_order,
        'past_due' as change_kind,
        'past_due_started' as change_detail,
        null::varchar as lifecycle_status,
        null::varchar as plan,
        null::integer as seats,
        null::varchar as billing_frequency,
        null::integer as seat_delta,
        1 as past_due_change,
        subscription_id || '-' || past_due_period_number as source_id
    from past_due_periods

),

past_due_ends as (

    select
        subscription_id,
        account_id,
        past_due_until as changed_at,
        3 as sort_order,
        'past_due' as change_kind,
        'past_due_ended' as change_detail,
        null::varchar as lifecycle_status,
        null::varchar as plan,
        null::integer as seats,
        null::varchar as billing_frequency,
        null::integer as seat_delta,
        -1 as past_due_change,
        subscription_id || '-' || past_due_period_number as source_id
    from past_due_periods
    where past_due_until is not null

),

applied_cancellations as (

    select
        subscription_id,
        account_id,
        effective_at as changed_at,
        4 as sort_order,
        'ending' as change_kind,
        'cancellation' as change_detail,
        'cancelled' as lifecycle_status,
        null::varchar as plan,
        null::integer as seats,
        null::varchar as billing_frequency,
        null::integer as seat_delta,
        null::integer as past_due_change,
        change_request_id as source_id
    from change_requests
    where request_type = 'cancellation' and outcome = 'applied'

),

lapses_and_expirations as (

    select
        subscription_id,
        account_id,
        effective_at as changed_at,
        4 as sort_order,
        'ending' as change_kind,
        event_type as change_detail,
        event_type as lifecycle_status,
        null::varchar as plan,
        null::integer as seats,
        null::varchar as billing_frequency,
        null::integer as seat_delta,
        null::integer as past_due_change,
        event_id as source_id
    from events
    where event_type in ('lapsed', 'trial_expired')

),

unioned as (

    select * from checkpoints
    union all
    select * from immediate_changes
    union all
    select * from past_due_starts
    union all
    select * from past_due_ends
    union all
    select * from applied_cancellations
    union all
    select * from lapses_and_expirations

)

select * from unioned
