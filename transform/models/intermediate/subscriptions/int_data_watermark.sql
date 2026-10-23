-- The time range the data covers: the earliest and latest recorded business
-- activity (invoice issued, payment attempted, or customer/system action).
-- Anything scheduled after data_as_of hasn't happened yet. ingested_at is
-- deliberately excluded: late-arriving rows land after the moment they
-- describe.

with

activity_bounds as (

    select
        min(issued_at) as first_activity_at,
        max(issued_at) as last_activity_at
    from {{ ref('stg_billing__invoices') }}

    union all

    select
        min(attempted_at) as first_activity_at,
        max(attempted_at) as last_activity_at
    from {{ ref('stg_billing__payments') }}

    union all

    select
        min(requested_at) as first_activity_at,
        max(requested_at) as last_activity_at
    from {{ ref('stg_billing__subscription_events') }}

)

select
    min(first_activity_at) as data_starts_at,
    max(last_activity_at) as data_as_of
from activity_bounds
