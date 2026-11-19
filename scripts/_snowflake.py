"""Read-only Snowflake connection for the scripts in this folder.

Uses the same environment variables as the dev dbt target (SNOWFLAKE_ACCOUNT, SNOWFLAKE_USER,
SNOWFLAKE_PRIVATE_KEY_PATH) and role DEVELOPER, which can read RAW and ANALYTICS but write only ANALYTICS_DEV.
"""

from __future__ import annotations

import os

import snowflake.connector


def connect(database: str = "ANALYTICS") -> snowflake.connector.SnowflakeConnection:
    return snowflake.connector.connect(
        account=os.environ["SNOWFLAKE_ACCOUNT"],
        user=os.environ["SNOWFLAKE_USER"],
        private_key_file=os.environ["SNOWFLAKE_PRIVATE_KEY_PATH"],
        role="DEVELOPER",
        warehouse="TRANSFORMING_WH",
        database=database,
    )
