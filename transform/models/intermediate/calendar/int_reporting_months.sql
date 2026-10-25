-- One row per reporting month, in the reporting timezone, with the UTC
-- instants the month starts and ends (the month-end cutoff, exclusive).
-- Covers the month of the first data through the month of the watermark.
--   is_month_closed:       the cutoff is at or before the watermark, so the
--                          month-end state is fully known
--   is_activity_complete:  the whole month is in the data, so activity
--                          during it (new, churn, ...) is complete

{% set reporting_tz = var('reporting_timezone') %}

with

data_bounds as (

    select
        data_starts_at,
        data_as_of
    from {{ ref('int_data_watermark') }}

),

month_bounds as (

    select
        data_starts_at,
        data_as_of,
        date_trunc(
            'month',
            convert_timezone('{{ reporting_tz }}', data_starts_at)::date
        ) as first_month_start_date,
        date_trunc(
            'month',
            convert_timezone('{{ reporting_tz }}', data_as_of)::date
        ) as last_month_start_date
    from data_bounds

),

spine as (

    {{ dbt_utils.date_spine(
        datepart="month",
        start_date="'2019-01-01'::date",
        end_date="'2031-01-01'::date"
    ) }}

),

months as (

    select
        spine.date_month::date as month_start_date_et,
        month_bounds.data_starts_at,
        month_bounds.data_as_of
    from spine
    cross join month_bounds
    where
        spine.date_month between month_bounds.first_month_start_date
        and month_bounds.last_month_start_date

),

final as (

    select
        month_start_date_et,
        last_day(month_start_date_et) as month_end_date_et,
        {{ naive_to_utc(
            'month_start_date_et::timestamp_ntz', reporting_tz
        ) }} as month_started_at,
        {{ naive_to_utc(
            'dateadd(month, 1, month_start_date_et)::timestamp_ntz', reporting_tz
        ) }} as month_ended_at,
        month_ended_at <= data_as_of as is_month_closed,
        month_started_at >= data_starts_at
        and is_month_closed as is_activity_complete
    from months

)

select * from final
