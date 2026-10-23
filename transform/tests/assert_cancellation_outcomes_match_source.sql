-- Cancellation outcomes derived from events should agree with the source
-- system's current-state table, in both directions:
--   applied            <-> cancelled, with ended_at equal to the
--                          cancellation's effective_at
--   pending            <-> live (active / past_due) with cancel_requested_at
--   never_took_effect  <-> lapsed with cancel_requested_at (lapsed first)
-- Returns disagreements; passes when empty.

with

cancellations as (

    select
        subscription_id,
        outcome,
        effective_at
    from {{ ref('int_subscription_change_requests') }}
    where request_type = 'cancellation'

),

-- the state each source subscription implies for its cancellation, if any
source_expectations as (

    select
        subscription_id,
        ended_at,
        case
            when subscription_status = 'cancelled' then 'applied'
            when
                subscription_status in ('active', 'past_due')
                and cancel_requested_at is not null
                then 'pending'
            when
                subscription_status = 'lapsed'
                and cancel_requested_at is not null
                then 'never_took_effect'
        end as expected_outcome
    from {{ ref('stg_billing__subscriptions') }}

),

compared as (

    select
        coalesce(
            cancellations.subscription_id, source_expectations.subscription_id
        ) as subscription_id,
        cancellations.outcome as derived_outcome,
        source_expectations.expected_outcome,
        cancellations.effective_at as derived_effective_at,
        source_expectations.ended_at as source_ended_at
    from cancellations
    full outer join source_expectations
        on cancellations.subscription_id = source_expectations.subscription_id
    where
        cancellations.subscription_id is not null
        or source_expectations.expected_outcome is not null

)

select * from compared
where
    derived_outcome is distinct from expected_outcome
    or (
        derived_outcome = 'applied'
        and derived_effective_at is distinct from source_ended_at
    )
