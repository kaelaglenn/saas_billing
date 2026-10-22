/*
  Snowflake bootstrap for saas_billing. Run once, top to bottom, in a Snowsight worksheet as a user
  with ACCOUNTADMIN. Safe to re-run: every statement is idempotent.

  Layout
    RAW              source data landed by dlt (LOADER writes, dbt roles read)
    ANALYTICS        production dbt models (TRANSFORMER writes, everyone else reads)
    ANALYTICS_DEV    developer schemas (dbt_<name>) and CI schemas (dbt_pr_<number>)

  Functional roles
    LOADER       dlt: creates schemas and tables in RAW
    TRANSFORMER  production dbt runs from GitHub Actions: reads RAW, builds ANALYTICS
    DEVELOPER    humans and CI: reads RAW and ANALYTICS (for --defer), builds only in ANALYTICS_DEV
    REPORTER     BI and ad hoc queries: reads ANALYTICS

  Service users authenticate with key pairs only (TYPE = SERVICE cannot use passwords).
  Set their public keys afterwards with snowflake/generate_keypair.sh.
*/

-- ---------------------------------------------------------------- warehouses (SYSADMIN)
USE ROLE SYSADMIN;

CREATE WAREHOUSE IF NOT EXISTS LOADING_WH
  WAREHOUSE_SIZE = 'XSMALL' AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE
  STATEMENT_TIMEOUT_IN_SECONDS = 900
  COMMENT = 'dlt loads into RAW';

CREATE WAREHOUSE IF NOT EXISTS TRANSFORMING_WH
  WAREHOUSE_SIZE = 'XSMALL' AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE
  STATEMENT_TIMEOUT_IN_SECONDS = 900
  COMMENT = 'dbt runs: production, CI, and development';

CREATE WAREHOUSE IF NOT EXISTS REPORTING_WH
  WAREHOUSE_SIZE = 'XSMALL' AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE
  STATEMENT_TIMEOUT_IN_SECONDS = 300
  COMMENT = 'BI tools and ad hoc queries';

-- ----------------------------------------------------------------- databases (SYSADMIN)
CREATE DATABASE IF NOT EXISTS RAW COMMENT = 'Source data landed by dlt. Never modified by dbt.';
CREATE DATABASE IF NOT EXISTS ANALYTICS COMMENT = 'Production dbt models.';
CREATE DATABASE IF NOT EXISTS ANALYTICS_DEV COMMENT = 'Developer and CI dbt schemas. Disposable.';

-- ------------------------------------------------------------ cost guardrail (ACCOUNTADMIN)
-- Trial accounts include about $400 of credit. This caps spend well below that each month.
USE ROLE ACCOUNTADMIN;

CREATE RESOURCE MONITOR IF NOT EXISTS SAAS_BILLING_MONITOR
  WITH CREDIT_QUOTA = 20 FREQUENCY = MONTHLY START_TIMESTAMP = IMMEDIATELY
  TRIGGERS
    ON 75 PERCENT DO NOTIFY
    ON 100 PERCENT DO SUSPEND
    ON 110 PERCENT DO SUSPEND_IMMEDIATE;

ALTER WAREHOUSE LOADING_WH SET RESOURCE_MONITOR = SAAS_BILLING_MONITOR;
ALTER WAREHOUSE TRANSFORMING_WH SET RESOURCE_MONITOR = SAAS_BILLING_MONITOR;
ALTER WAREHOUSE REPORTING_WH SET RESOURCE_MONITOR = SAAS_BILLING_MONITOR;

-- ------------------------------------------------------------ account defaults (ACCOUNTADMIN)
-- Every session defaults to UTC instead of Snowflake's America/Los_Angeles, so plain date strings, NTZ -> TZ
-- casts, and current_timestamp() mean UTC in every tool. Stored TIMESTAMP_TZ values are unaffected. Users or
-- sessions can still override this, so models shouldn't depend on it (see the naive_to_utc macro).
ALTER ACCOUNT SET TIMEZONE = 'UTC';

-- --------------------------------------------------------------------- roles (USERADMIN)
USE ROLE USERADMIN;

CREATE ROLE IF NOT EXISTS LOADER COMMENT = 'dlt: writes RAW';
CREATE ROLE IF NOT EXISTS TRANSFORMER COMMENT = 'Production dbt: reads RAW, writes ANALYTICS';
CREATE ROLE IF NOT EXISTS DEVELOPER COMMENT = 'Humans and CI: reads RAW and ANALYTICS, writes ANALYTICS_DEV';
CREATE ROLE IF NOT EXISTS REPORTER COMMENT = 'Reads ANALYTICS';

-- SYSADMIN inherits every functional role so admins can see and manage all objects.
GRANT ROLE LOADER TO ROLE SYSADMIN;
GRANT ROLE TRANSFORMER TO ROLE SYSADMIN;
GRANT ROLE DEVELOPER TO ROLE SYSADMIN;
GRANT ROLE REPORTER TO ROLE SYSADMIN;

-- Developers read production models (needed for dbt --defer in CI) by inheriting REPORTER.
GRANT ROLE REPORTER TO ROLE DEVELOPER;

-- -------------------------------------------------------------------- grants (SECURITYADMIN)
USE ROLE SECURITYADMIN;

-- Warehouses
GRANT USAGE ON WAREHOUSE LOADING_WH TO ROLE LOADER;
GRANT USAGE ON WAREHOUSE TRANSFORMING_WH TO ROLE TRANSFORMER;
GRANT USAGE ON WAREHOUSE TRANSFORMING_WH TO ROLE DEVELOPER;
GRANT USAGE ON WAREHOUSE REPORTING_WH TO ROLE REPORTER;

-- RAW: LOADER creates (and so owns) the schemas and tables dlt lands.
GRANT USAGE, CREATE SCHEMA ON DATABASE RAW TO ROLE LOADER;

-- RAW: both dbt roles read everything, including schemas and tables dlt creates later.
GRANT USAGE ON DATABASE RAW TO ROLE TRANSFORMER;
GRANT USAGE ON ALL SCHEMAS IN DATABASE RAW TO ROLE TRANSFORMER;
GRANT USAGE ON FUTURE SCHEMAS IN DATABASE RAW TO ROLE TRANSFORMER;
GRANT SELECT ON ALL TABLES IN DATABASE RAW TO ROLE TRANSFORMER;
GRANT SELECT ON FUTURE TABLES IN DATABASE RAW TO ROLE TRANSFORMER;

GRANT USAGE ON DATABASE RAW TO ROLE DEVELOPER;
GRANT USAGE ON ALL SCHEMAS IN DATABASE RAW TO ROLE DEVELOPER;
GRANT USAGE ON FUTURE SCHEMAS IN DATABASE RAW TO ROLE DEVELOPER;
GRANT SELECT ON ALL TABLES IN DATABASE RAW TO ROLE DEVELOPER;
GRANT SELECT ON FUTURE TABLES IN DATABASE RAW TO ROLE DEVELOPER;

-- ANALYTICS: only production dbt builds here.
GRANT USAGE, CREATE SCHEMA ON DATABASE ANALYTICS TO ROLE TRANSFORMER;

-- ANALYTICS: REPORTER (and so DEVELOPER) reads every model production dbt creates.
GRANT USAGE ON DATABASE ANALYTICS TO ROLE REPORTER;
GRANT USAGE ON ALL SCHEMAS IN DATABASE ANALYTICS TO ROLE REPORTER;
GRANT USAGE ON FUTURE SCHEMAS IN DATABASE ANALYTICS TO ROLE REPORTER;
GRANT SELECT ON ALL TABLES IN DATABASE ANALYTICS TO ROLE REPORTER;
GRANT SELECT ON FUTURE TABLES IN DATABASE ANALYTICS TO ROLE REPORTER;
GRANT SELECT ON ALL VIEWS IN DATABASE ANALYTICS TO ROLE REPORTER;
GRANT SELECT ON FUTURE VIEWS IN DATABASE ANALYTICS TO ROLE REPORTER;

-- ANALYTICS_DEV: developers and CI create (and so own, and can drop) their own schemas.
GRANT USAGE, CREATE SCHEMA ON DATABASE ANALYTICS_DEV TO ROLE DEVELOPER;

-- --------------------------------------------------------------------- users (USERADMIN)
USE ROLE USERADMIN;

CREATE USER IF NOT EXISTS DLT_SVC
  TYPE = SERVICE DEFAULT_ROLE = LOADER DEFAULT_WAREHOUSE = LOADING_WH
  COMMENT = 'dlt pipeline (local runs and GitHub Actions)';

CREATE USER IF NOT EXISTS DBT_PROD_SVC
  TYPE = SERVICE DEFAULT_ROLE = TRANSFORMER DEFAULT_WAREHOUSE = TRANSFORMING_WH
  COMMENT = 'Production dbt runs from GitHub Actions on merge to main';

CREATE USER IF NOT EXISTS DBT_CI_SVC
  TYPE = SERVICE DEFAULT_ROLE = DEVELOPER DEFAULT_WAREHOUSE = TRANSFORMING_WH
  COMMENT = 'dbt CI runs from GitHub Actions on pull requests';

USE ROLE SECURITYADMIN;

GRANT ROLE LOADER TO USER DLT_SVC;
GRANT ROLE TRANSFORMER TO USER DBT_PROD_SVC;
GRANT ROLE DEVELOPER TO USER DBT_CI_SVC;

-- You, the human: develop in ANALYTICS_DEV and run dlt locally. Production changes go through CI.
SET my_user = CURRENT_USER();
GRANT ROLE DEVELOPER TO USER IDENTIFIER($my_user);
GRANT ROLE LOADER TO USER IDENTIFIER($my_user);
