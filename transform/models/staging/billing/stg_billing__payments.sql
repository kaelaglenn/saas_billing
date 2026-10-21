with

source as (

    select * from {{ source('billing', 'payments') }}

),

-- Some rows were loaded twice, identical in every column. distinct removes
-- exact copies only; if two rows ever share a payment_id but differ, both
-- survive and the unique test on payment_id fails.
deduplicated as (

    select distinct * from source

),

renamed as (

    select
        -- ids
        payment_id,
        invoice_id,
        account_id,

        -- strings
        method as payment_method,
        status as payment_status,
        failure_reason,

        -- numerics
        amount_cents,
        attempt_number,

        -- timestamps (UTC)
        attempted_at

    from deduplicated

)

select * from renamed
