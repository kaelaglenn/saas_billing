-- One row per customer-initiated change: plan and seat changes, billing
-- frequency switches, and cancellations, with when each was requested, when
-- it was due to take effect, and whether it did.
--   outcome
--     applied:           took effect (immediately, or at the renewal it was
--                        scheduled for)
--     pending:           scheduled after the end of the data
--     never_took_effect: the subscription lapsed or was cancelled first

with

events as (

    select * from {{ ref('stg_billing__subscription_events') }}

),

watermark as (

    select data_as_of from {{ ref('int_data_watermark') }}

),

plan_changes as (

    select
        event_id as change_request_id,
        subscription_id,
        account_id,
        case
            when change_type = 'seats' and change_direction = 'increase'
                then 'seat_increase'
            when change_type = 'seats' then 'seat_decrease'
            when change_direction = 'upgrade' then 'plan_upgrade'
            when change_direction = 'downgrade' then 'plan_downgrade'
            else 'frequency_switch'
        end as request_type,
        from_plan,
        to_plan,
        from_billing_frequency,
        to_billing_frequency,
        seat_delta,
        null::varchar as cancel_reason,
        requested_at,
        effective_at,
        ingested_at,
        event_type as source_event_type
    from events
    where event_type = 'plan_updated'

),

cancellations as (

    select
        event_id as change_request_id,
        subscription_id,
        account_id,
        'cancellation' as request_type,
        null::varchar as from_plan,
        null::varchar as to_plan,
        null::varchar as from_billing_frequency,
        null::varchar as to_billing_frequency,
        null::integer as seat_delta,
        cancel_reason,
        requested_at,
        effective_at,
        ingested_at,
        event_type as source_event_type
    from events
    where event_type = 'cancelled'

),

-- Cancellations requested before the Jan 1, 2024 cutover are recorded only on
-- the subscription_imported event, effective at that period's end.
cutover_cancellations as (

    select
        event_id as change_request_id,
        subscription_id,
        account_id,
        'cancellation' as request_type,
        null::varchar as from_plan,
        null::varchar as to_plan,
        null::varchar as from_billing_frequency,
        null::varchar as to_billing_frequency,
        null::integer as seat_delta,
        cancel_reason,
        cancel_requested_at as requested_at,
        current_period_end_at as effective_at,
        ingested_at,
        event_type as source_event_type
    from events
    where
        event_type = 'subscription_imported'
        and cancel_requested_at is not null

),

requests as (

    select * from plan_changes
    union all
    select * from cancellations
    union all
    select * from cutover_cancellations

),

renewals as (

    select
        subscription_id,
        effective_at as renewed_at
    from events
    where event_type = 'renewed'

),

lapses as (

    select
        subscription_id,
        effective_at as lapsed_at
    from events
    where event_type = 'lapsed'

),

-- A cancellation ends the subscription once its date has passed, unless the
-- subscription lapsed before then.
cancellation_endings as (

    select
        requests.subscription_id,
        requests.effective_at as ended_at
    from requests
    cross join watermark
    left join lapses
        on
            requests.subscription_id = lapses.subscription_id
            and requests.effective_at > lapses.lapsed_at
    where
        requests.request_type = 'cancellation'
        and requests.effective_at <= watermark.data_as_of
        and lapses.subscription_id is null

),

subscription_endings as (

    select
        subscription_id,
        min(ended_at) as ended_at
    from (
        select
            subscription_id,
            lapsed_at as ended_at
        from lapses
        union all
        select
            subscription_id,
            ended_at
        from cancellation_endings
    ) as endings
    group by subscription_id

),

final as (

    select
        requests.change_request_id,
        requests.subscription_id,
        requests.account_id,
        requests.request_type,
        requests.from_plan,
        requests.to_plan,
        requests.from_billing_frequency,
        requests.to_billing_frequency,
        requests.seat_delta,
        requests.cancel_reason,
        requests.effective_at > requests.requested_at as is_scheduled,
        case
            -- increases and upgrades take effect when requested
            when requests.effective_at = requests.requested_at
                then 'applied'
            when requests.request_type = 'cancellation'
                then
                    case
                        when
                            subscription_endings.ended_at
                            < requests.effective_at
                            then 'never_took_effect'
                        when requests.effective_at > watermark.data_as_of
                            then 'pending'
                        else 'applied'
                    end
            -- scheduled plan changes take effect at a renewal
            when renewals.renewed_at is not null then 'applied'
            when subscription_endings.ended_at <= requests.effective_at
                then 'never_took_effect'
            when requests.effective_at > watermark.data_as_of
                then 'pending'
            -- should never happen; tested
            else 'unexplained'
        end as outcome,
        requests.requested_at,
        requests.effective_at,
        requests.ingested_at,
        requests.source_event_type
    from requests
    cross join watermark
    left join renewals
        on
            requests.subscription_id = renewals.subscription_id
            and requests.effective_at = renewals.renewed_at
    left join subscription_endings
        on requests.subscription_id = subscription_endings.subscription_id

)

select * from final
