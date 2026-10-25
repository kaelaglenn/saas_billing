{#
    The calendar date of a UTC timestamp in the reporting timezone (var reporting_timezone).
    Converts the TIMESTAMP_TZ to the reporting timezone first, so the result doesn't depend on the session's
    TIMEZONE. Name the output with an _et suffix (e.g. trial_start_date_et): a DATE carries no timezone.
#}
{% macro to_reporting_date(column) -%}
    convert_timezone('{{ var("reporting_timezone") }}', {{ column }})::date
{%- endmacro %}
