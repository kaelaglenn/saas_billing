-- One row per calendar date in the reporting timezone, from the first day of
-- the opening month to the last month-end. The Semantic Layer's time spine:
-- MetricFlow joins metric_time to it. Dates come from the reporting calendar,
-- so the spine always covers the data.

with

calendar_bounds as (

    select
        min(month_start_date_et) as first_date_et,
        max(month_end_date_et) as last_date_et
    from {{ ref('int_reporting_months') }}

),

-- Snowflake's generator needs a constant row count: 2,000 days (about 5.5
-- years) is well past the data, and the relationships tests in YAML fail if
-- the calendar ever outgrows it.
day_offsets as (

    select row_number() over (order by seq4()) - 1 as day_offset
    from table(generator(rowcount => 2000))

),

final as (

    select
        dateadd(
            day, day_offsets.day_offset, calendar_bounds.first_date_et
        ) as date_day
    from day_offsets
    cross join calendar_bounds
    where
        dateadd(day, day_offsets.day_offset, calendar_bounds.first_date_et)
        <= calendar_bounds.last_date_et

)

select * from final
