with

source as (

    select * from {{ source('billing', 'subscription_events') }}

),

-- Retried webhooks re-emit an event with a new event_id and identical
-- content. Keep the first-ingested copy, which carries the original event_id.
deduplicated as (

    select * from source
    qualify row_number() over (
        partition by
            subscription_id,
            event_type,
            requested_at,
            effective_at,
            attributes
        order by ingested_at, event_id
    ) = 1

),

parsed as (

    select
        *,
        parse_json(attributes) as attrs
    from deduplicated

),

-- Flatten attributes into typed columns; each is null for event types that
-- don't carry that key. Casting turns JSON null into SQL null.
renamed as (

    select
        -- ids
        event_id,
        subscription_id,
        account_id,
        attrs:previous_subscription_id::varchar as previous_subscription_id,
        attrs:invoice_id::varchar as lapse_invoice_id,

        -- strings
        event_type,
        attrs:change_type::varchar as change_type,
        attrs:direction::varchar as change_direction,
        attrs:plan::varchar as plan,
        attrs:billing_frequency::varchar as billing_frequency,
        attrs:payment_method::varchar as payment_method,
        attrs:from_plan::varchar as from_plan,
        attrs:to_plan::varchar as to_plan,
        attrs:from_billing_frequency::varchar as from_billing_frequency,
        attrs:to_billing_frequency::varchar as to_billing_frequency,
        -- "reason" means the customer's reason on cancelled events and the
        -- payment cause on lapsed events; imported subscriptions store a
        -- pending cancellation's reason under cancel_reason.
        case
            when event_type = 'cancelled' then attrs:reason::varchar
            when event_type = 'subscription_imported'
                then attrs:cancel_reason::varchar
        end as cancel_reason,
        iff(event_type = 'lapsed', attrs:reason::varchar, null) as lapse_reason,

        -- numerics
        subscription_amount_cents,
        attrs:seats::integer as seats,
        attrs:from_seats::integer as from_seats,
        attrs:to_seats::integer as to_seats,
        attrs:seat_delta::integer as seat_delta,

        -- booleans
        attrs:is_reactivation::boolean as is_reactivation,

        -- timestamps (UTC)
        requested_at,
        effective_at,
        ingested_at,
        attrs:current_period_start::timestamp_tz as current_period_start_at,
        attrs:current_period_end::timestamp_tz as current_period_end_at,
        attrs:trial_ends_at::timestamp_tz as trial_ends_at,
        attrs:started_at::timestamp_tz as subscription_started_at,
        attrs:cancel_requested_at::timestamp_tz as cancel_requested_at,

        -- semi-structured
        attrs as attributes_json

    from parsed

)

select * from renamed
