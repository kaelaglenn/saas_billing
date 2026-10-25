{{ config(materialized='table') }}

-- Each subscription's effective state and MRR at each reporting month-end
-- (the state in effect at the month's cutoff instant). One row per month
-- the subscription is live or trialing at month-end, plus the first
-- month-end after it ends, so the month it churned or expired is visible.

with

months as (

    select * from {{ ref('int_reporting_months') }}

),

history as (

    select * from {{ ref('int_subscription_history') }}

),

-- the history row in effect at each cutoff; [valid_from, valid_to) is
-- half-open, so exactly one row matches per subscription and month
state_at_cutoff as (

    select
        history.subscription_id,
        history.account_id,
        history.subscription_history_id,
        history.subscription_status,
        history.plan,
        history.billing_frequency,
        history.seats,
        history.mrr_cents,
        history.valid_from,
        months.month_start_date_et,
        months.month_end_date_et,
        months.month_started_at,
        months.month_ended_at,
        months.is_month_closed,
        months.is_activity_complete
    from months
    inner join history
        on
            months.month_ended_at > history.valid_from
            and months.month_ended_at
            <= coalesce(history.valid_to, '9999-12-31'::timestamp_tz)

),

final as (

    select
        {{ dbt_utils.generate_surrogate_key(
            ['subscription_id', 'month_start_date_et']
        ) }} as subscription_month_id,
        subscription_id,
        account_id,
        subscription_history_id,
        month_start_date_et,
        month_end_date_et,
        subscription_status,
        plan,
        billing_frequency,
        seats,
        mrr_cents,
        is_month_closed,
        is_activity_complete,
        month_ended_at
    from state_at_cutoff
    where
        subscription_status in ('trialing', 'active', 'past_due')
        -- ended during this month: the first month-end after the ending
        or valid_from >= month_started_at

)

select * from final
