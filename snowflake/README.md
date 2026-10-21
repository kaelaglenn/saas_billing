# Snowflake setup

One-time setup of warehouses, databases, roles, and service users. Everything is in
[bootstrap.sql](bootstrap.sql) so the account can be rebuilt from scratch, for example on a fresh trial.

## Layout

| Database | Written by | Read by | Contents |
|---|---|---|---|
| `RAW` | `LOADER` (dlt) | `TRANSFORMER`, `DEVELOPER` | Source tables exactly as landed |
| `ANALYTICS` | `TRANSFORMER` (prod dbt) | `REPORTER`, `DEVELOPER` | Production models |
| `ANALYTICS_DEV` | `DEVELOPER` (you, CI) | `DEVELOPER` | `dbt_<name>` dev schemas, `dbt_pr_<number>` CI schemas |

| User | Role | Used by |
|---|---|---|
| `DLT_SVC` | `LOADER` | dlt pipeline |
| `DBT_PROD_SVC` | `TRANSFORMER` | GitHub Actions on merge to `main` |
| `DBT_CI_SVC` | `DEVELOPER` | GitHub Actions on pull requests |
| you | `DEVELOPER`, `LOADER` | local development |

Production is only ever built by CI. Your own user can't write to `ANALYTICS`, which is the point.

Each workload has its own X-Small warehouse that suspends after 60 seconds idle, and all three share a
resource monitor capped at 20 credits a month.

## Setup

1. **Create a trial account** at [signup.snowflake.com](https://signup.snowflake.com): Enterprise edition, any
   cloud and region. Save the account identifier (`<org>-<account>`, under **Admin → Accounts**); dlt and dbt
   use it to connect, so you'll need it when setting those up.
2. **Run the bootstrap.** Open a Snowsight worksheet, paste [bootstrap.sql](bootstrap.sql), and choose
   **Run All**. It switches roles as it goes, so you need ACCOUNTADMIN (trial accounts start with it).
3. **Create key pairs for the service users.** From the repo root, run the script once per user, then paste
   the `ALTER USER` statement each run prints into a Snowsight worksheet and run it:

   ```bash
   cd ~/Projects/saas_billing
   ```

   ```bash
   snowflake/generate_keypair.sh DLT_SVC
   ```

   ```bash
   snowflake/generate_keypair.sh DBT_PROD_SVC
   ```

   ```bash
   snowflake/generate_keypair.sh DBT_CI_SVC
   ```

   Private keys go to `~/.snowflake/keys/`, outside the repo. They'll become GitHub Actions secrets when we
   set up CI.
4. **Check it worked:**

   ```sql
   USE ROLE SECURITYADMIN;
   SHOW GRANTS TO ROLE DEVELOPER;
   DESC USER DLT_SVC;  -- RSA_PUBLIC_KEY_FP should be set
   ```

To start over, [teardown.sql](teardown.sql) drops everything bootstrap.sql created.

## GitHub Actions settings

The [dbt CI workflow](../.github/workflows/dbt_ci.yml) connects as `DBT_CI_SVC` using two repository settings
(GitHub → Settings → Secrets and variables → Actions):

| Name | Kind | Value |
|---|---|---|
| `SNOWFLAKE_ACCOUNT` | variable | the account identifier |
| `SNOWFLAKE_CI_PRIVATE_KEY` | secret | contents of `~/.snowflake/keys/DBT_CI_SVC.p8` |

```bash
gh variable set SNOWFLAKE_ACCOUNT --body "<ORG>-<ACCOUNT>"
```

```bash
gh secret set SNOWFLAKE_CI_PRIVATE_KEY < ~/.snowflake/keys/DBT_CI_SVC.p8
```

**Moving to a new account** (e.g. a new trial): run the bootstrap, register keys, then update both settings
with the commands above.
