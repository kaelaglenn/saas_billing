{#
    Drop a pull request's CI schema:  dbt run-operation drop_pr_schema --args '{schema_name: DBT_PR_12}' --target ci

    Used by CI to start each run from an empty schema and to clean up when a PR closes. Refuses anything that
    isn't a DBT_PR_* schema in ANALYTICS_DEV, so it can't drop a developer schema or touch production.
#}
{% macro drop_pr_schema(schema_name) %}
    {% if not modules.re.match('^DBT_PR_[0-9]+$', schema_name | upper) %}
        {{ exceptions.raise_compiler_error(
            "drop_pr_schema only drops DBT_PR_<number> schemas, got '" ~ schema_name ~ "'"
        ) }}
    {% endif %}
    {% if target.database | upper != 'ANALYTICS_DEV' %}
        {{ exceptions.raise_compiler_error(
            "drop_pr_schema only runs against ANALYTICS_DEV, target database is '" ~ target.database ~ "'"
        ) }}
    {% endif %}

    {% set relation = target.database ~ '.' ~ schema_name | upper %}
    {% do run_query('drop schema if exists ' ~ relation ~ ' cascade') %}
    {% do log('Dropped schema ' ~ relation ~ ' (if it existed)', info=true) %}
{% endmacro %}
