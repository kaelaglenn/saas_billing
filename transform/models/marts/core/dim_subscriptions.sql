-- One row per subscription (Type 1: current state), with its lifecycle:
-- trial, paid start, cancellation request, and how it ended.

with

current_state as (

    select * from {{ ref('int_subscription_history') }}
    where is_current

),

subscriptions as (

    select * from {{ ref('stg_billing__subscriptions') }}

),

starts as (

    select
        subscription_id,
        is_reactivation,
        previous_subscription_id
    from {{ ref('stg_billing__subscription_events') }}
    where event_type = 'subscription_started'

),

imports as (

    select distinct subscription_id
    from {{ ref('stg_billing__subscription_events') }}
    where event_type = 'subscription_imported'

),

latest_cancellation as (

    select
        subscription_id,
        cancel_reason,
        requested_at,
        outcome
    from {{ ref('int_subscription_change_requests') }}
    where request_type = 'cancellation'
    qualify row_number() over (
        partition by subscription_id order by requested_at desc
    ) = 1

),

final as (

    select
        current_state.subscription_id,
        current_state.account_id,
        starts.previous_subscription_id,
        current_state.subscription_status,
        current_state.plan,
        current_state.billing_frequency,
        current_state.seats,
        current_state.mrr_cents,
        iff(
            current_state.subscription_status in (
                'cancelled', 'lapsed', 'trial_expired'
            ),
            current_state.subscription_status,
            null
        ) as end_reason,
        latest_cancellation.cancel_reason,
        coalesce(starts.is_reactivation, false) as is_reactivation,
        imports.subscription_id is not null as is_imported,
        coalesce(
            latest_cancellation.outcome = 'pending', false
        ) as has_pending_cancellation,
        subscriptions.trial_started_at,
        subscriptions.started_at,
        latest_cancellation.requested_at as cancel_requested_at,
        iff(
            end_reason is not null, current_state.valid_from, null
        ) as ended_at
    from current_state
    inner join subscriptions
        on current_state.subscription_id = subscriptions.subscription_id
    left join starts
        on current_state.subscription_id = starts.subscription_id
    left join imports
        on current_state.subscription_id = imports.subscription_id
    left join latest_cancellation
        on current_state.subscription_id = latest_cancellation.subscription_id

)

select * from final
