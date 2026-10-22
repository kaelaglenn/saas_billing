-- The latest moment the data covers: the last recorded business activity
-- (invoice issued, payment attempted, or customer/system action). Anything
-- scheduled after it hasn't happened yet. ingested_at is deliberately
-- excluded: late-arriving rows land after the moment they describe.

with

last_activity as (

    select max(issued_at) as last_activity_at
    from {{ ref('stg_billing__invoices') }}

    union all

    select max(attempted_at) as last_activity_at
    from {{ ref('stg_billing__payments') }}

    union all

    select max(requested_at) as last_activity_at
    from {{ ref('stg_billing__subscription_events') }}

)

select max(last_activity_at) as data_as_of
from last_activity
