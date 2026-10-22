-- One row per continuous period during which a subscription had at least one
-- overdue invoice. Overlapping invoice delinquencies merge into one period
-- (gaps-and-islands). An invoice stops counting once it's paid or written
-- off; past_due_until is null while still overdue at the end of the data.

with

delinquencies as (

    select
        subscription_id,
        account_id,
        delinquent_from,
        -- still-overdue invoices stay open; a far-future end keeps them in
        -- the running max below
        coalesce(ended_at, '9999-12-31'::timestamp_tz) as delinquent_until
    from {{ ref('int_invoice_delinquency_periods') }}

),

-- latest end among earlier periods of the same subscription
with_running_end as (

    select
        subscription_id,
        account_id,
        delinquent_from,
        delinquent_until,
        max(delinquent_until) over (
            partition by subscription_id
            order by delinquent_from, delinquent_until
            rows between unbounded preceding and 1 preceding
        ) as previous_max_until
    from delinquencies

),

-- a period that starts after everything before it has ended starts an island
islands as (

    select
        subscription_id,
        account_id,
        delinquent_from,
        delinquent_until,
        sum(
            iff(
                previous_max_until is null
                or delinquent_from > previous_max_until,
                1,
                0
            )
        ) over (
            partition by subscription_id
            order by delinquent_from, delinquent_until
            rows between unbounded preceding and current row
        ) as island_number
    from with_running_end

),

final as (

    select
        subscription_id,
        account_id,
        island_number as past_due_period_number,
        min(delinquent_from) as past_due_from,
        nullif(
            max(delinquent_until), '9999-12-31'::timestamp_tz
        ) as past_due_until
    from islands
    group by subscription_id, account_id, island_number

)

select * from final
