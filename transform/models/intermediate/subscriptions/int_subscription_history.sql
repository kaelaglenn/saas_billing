{{ config(materialized='table') }}

-- SCD Type 2 history of each subscription's effective state: one row per
-- period with constant status, plan, seats, and billing frequency, over
-- [valid_from, valid_to). Rebuilt by replaying int_subscription_state_changes
-- in order (event sourcing).

with

state_changes as (

    select * from {{ ref('int_subscription_state_changes') }}

),

prices as (

    select * from {{ ref('plan_prices') }}

),

-- Replay in order. A new checkpoint resets seats; seat deltas accumulate
-- until the next one.
ordered as (

    select
        *,
        count_if(change_kind = 'checkpoint') over (
            partition by subscription_id
            order by changed_at, sort_order, source_id
            rows between unbounded preceding and current row
        ) as checkpoint_number,
        row_number() over (
            partition by subscription_id
            order by changed_at, sort_order, source_id
        ) as replay_order
    from state_changes

),

resolved as (

    select
        subscription_id,
        account_id,
        changed_at,
        replay_order,
        last_value(lifecycle_status ignore nulls) over (
            partition by subscription_id
            order by replay_order
            rows between unbounded preceding and current row
        ) as lifecycle_status,
        last_value(plan ignore nulls) over (
            partition by subscription_id
            order by replay_order
            rows between unbounded preceding and current row
        ) as plan,
        last_value(billing_frequency ignore nulls) over (
            partition by subscription_id
            order by replay_order
            rows between unbounded preceding and current row
        ) as billing_frequency,
        first_value(seats)
            over (
                partition by subscription_id, checkpoint_number
                order by replay_order
            )
        + coalesce(
            sum(seat_delta) over (
                partition by subscription_id, checkpoint_number
                order by replay_order
                rows between unbounded preceding and current row
            ),
            0
        ) as seats,
        coalesce(
            sum(past_due_change) over (
                partition by subscription_id
                order by replay_order
                rows between unbounded preceding and current row
            ),
            0
        ) as open_past_due_periods
    from ordered

),

with_status as (

    select
        subscription_id,
        account_id,
        changed_at,
        replay_order,
        -- an ended subscription is cancelled / lapsed, never past_due
        iff(
            lifecycle_status = 'active' and open_past_due_periods > 0,
            'past_due',
            lifecycle_status
        ) as subscription_status,
        plan,
        seats,
        billing_frequency
    from resolved

),

-- When several changes happen at the same instant, keep the state after the
-- last one.
end_of_instant as (

    select * from with_status
    qualify row_number() over (
        partition by subscription_id, changed_at
        order by replay_order desc
    ) = 1

),

-- Drop rows where nothing actually changed.
state_transitions as (

    select * from end_of_instant
    qualify
        lag(subscription_status) over (
            partition by subscription_id order by changed_at
        ) is distinct from subscription_status
        or lag(plan) over (
            partition by subscription_id order by changed_at
        ) is distinct from plan
        or lag(seats) over (
            partition by subscription_id order by changed_at
        ) is distinct from seats
        or lag(billing_frequency) over (
            partition by subscription_id order by changed_at
        ) is distinct from billing_frequency

),

final as (

    select
        {{ dbt_utils.generate_surrogate_key(
            ['state_transitions.subscription_id', 'state_transitions.changed_at']
        ) }} as subscription_history_id,
        state_transitions.subscription_id,
        state_transitions.account_id,
        state_transitions.subscription_status,
        state_transitions.plan,
        state_transitions.billing_frequency,
        state_transitions.seats,
        -- MRR: monthly price as-is, annual price spread over 12 months
        iff(
            state_transitions.subscription_status in ('active', 'past_due'),
            (
                state_transitions.seats * prices.unit_price_cents
                / iff(state_transitions.billing_frequency = 'annual', 12, 1)
            )::integer,
            0
        ) as mrr_cents,
        state_transitions.changed_at as valid_from,
        lead(state_transitions.changed_at) over (
            partition by state_transitions.subscription_id
            order by state_transitions.changed_at
        ) as valid_to,
        valid_to is null as is_current
    from state_transitions
    left join prices
        on
            state_transitions.plan = prices.plan
            and state_transitions.billing_frequency = prices.billing_frequency

)

select * from final
