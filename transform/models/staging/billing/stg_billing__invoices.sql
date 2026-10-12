with

source as (

    select * from {{ source('billing', 'invoices') }}

),

renamed as (

    select
        -- ids
        invoice_id,
        account_id,
        subscription_id,

        -- strings
        invoice_type,
        status as invoice_status,
        payment_method,

        -- numerics
        amount_due_cents,

        -- timestamps (UTC)
        issued_at,
        due_at

    from source

)

select * from renamed
