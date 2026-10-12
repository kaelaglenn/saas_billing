with

source as (

    select * from {{ source('billing', 'accounts') }}

),

renamed as (

    select
        -- ids
        account_id,

        -- strings
        company_name,
        industry,
        company_size_band,

        -- timestamps: source stores naive America/New_York time
        {{ naive_to_utc('created_at', 'America/New_York') }} as created_at,
        {{ naive_to_utc('updated_at', 'America/New_York') }} as updated_at

    from source

)

select * from renamed
