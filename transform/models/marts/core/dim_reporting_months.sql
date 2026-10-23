-- One row per reporting month (reporting timezone), with the UTC instants it
-- starts and ends and how complete the data is for it.

with

months as (

    select * from {{ ref('int_reporting_months') }}

),

final as (

    select
        month_start_date,
        month_end_date,
        to_char(month_start_date, 'YYYY-MM') as month_label,
        year(month_start_date) as year,
        month_started_at,
        month_ended_at,
        month_start_date = min(month_start_date) over () as is_opening_balance,
        is_month_closed,
        is_activity_complete
    from months

)

select * from final
