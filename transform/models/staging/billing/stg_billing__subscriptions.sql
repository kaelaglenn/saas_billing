with

source as (

    select * from {{ source('billing', 'subscriptions') }}

),

renamed as (

    select
        -- ids
        subscription_id,
        account_id,

        -- strings
        status as subscription_status,
        plan,
        billing_frequency,
        payment_method,

        -- numerics
        seats,
        subscription_amount_cents,

        -- timestamps (UTC)
        trial_started_at,
        started_at,
        current_period_start as current_period_start_at,
        current_period_end as current_period_end_at,
        cancel_requested_at,
        ended_at,
        updated_at

    from source

)

select * from renamed
