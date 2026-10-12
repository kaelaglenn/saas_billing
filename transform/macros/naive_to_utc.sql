{#
    Convert a naive TIMESTAMP_NTZ recorded in local time to a UTC TIMESTAMP_TZ.

    Builds the value with its timezone attached instead of casting, because casting NTZ to TIMESTAMP_TZ uses the
    session's TIMEZONE parameter (Snowflake's default is America/Los_Angeles), so results would depend on who runs
    the query.

    Local times inside a repeated fall-back hour are ambiguous; Snowflake resolves them to the first occurrence
    (daylight time).
#}
{% macro naive_to_utc(column, source_timezone) -%}
    convert_timezone(
        'UTC',
        timestamp_tz_from_parts(
            year({{ column }}),
            month({{ column }}),
            day({{ column }}),
            hour({{ column }}),
            minute({{ column }}),
            second({{ column }}),
            date_part(nanosecond, {{ column }}),
            '{{ source_timezone }}'
        )
    )
{%- endmacro %}
