with

source as (

    select * from {{ source('billing', 'invoice_line_items') }}

),

renamed as (

    select
        -- ids
        line_item_id,
        invoice_id,

        -- strings
        line_type,
        plan,
        billing_frequency,

        -- numerics
        quantity,
        unit_price_cents,
        amount_cents,

        -- timestamps (UTC)
        service_period_start as service_period_start_at,
        service_period_end as service_period_end_at

    from source

)

select * from renamed
