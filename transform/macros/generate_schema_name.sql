{#
    Where each model is built.

    prod:      a folder's +schema is used as-is   -> ANALYTICS.STAGING, ANALYTICS.MARTS
    dev / ci:  everything goes in the target schema -> ANALYTICS_DEV.DBT_KAELA, ANALYTICS_DEV.DBT_PR_12

    Overrides dbt's default, which would prefix every custom schema with the target schema (DBT_KAELA_STAGING).
#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if target.name == 'prod' and custom_schema_name is not none -%}
        {{ custom_schema_name | trim }}
    {%- else -%}
        {{ target.schema }}
    {%- endif -%}
{%- endmacro %}
