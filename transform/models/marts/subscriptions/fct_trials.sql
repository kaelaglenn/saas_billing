-- Accumulating snapshot: one row per trial, with its milestones (started,
-- then converted or expired) and outcome. A trial is matured once its trial
-- period plus var trial_maturity_buffer_days has passed as of the data
-- watermark; measure conversion rates on matured trials only.

with

subscriptions as (

    select * from {{ ref('dim_subscriptions') }}
    where trial_started_at is not null

),

trial_starts as (

    select
        subscription_id,
        plan,
        seats,
        billing_frequency,
        trial_ends_at
    from {{ ref('stg_billing__subscription_events') }}
    where event_type = 'trial_started'

),

watermark as (

    select data_as_of from {{ ref('int_data_watermark') }}

),

final as (

    select
        subscriptions.subscription_id,
        subscriptions.account_id,
        trial_starts.plan,
        trial_starts.billing_frequency,
        case
            when subscriptions.started_at is not null then 'converted'
            when subscriptions.subscription_status = 'trial_expired'
                then 'expired'
            else 'in_progress'
        end as trial_outcome,
        trial_starts.seats,
        -- whole days from trial start to conversion (day 0 = first 24 hours)
        floor(
            datediff(
                'second',
                subscriptions.trial_started_at,
                subscriptions.started_at
            ) / 86400
        )::number(38, 0) as days_to_convert,
        dateadd(
            day,
            {{ var('trial_maturity_buffer_days') }},
            trial_starts.trial_ends_at
        ) <= watermark.data_as_of as is_matured,
        subscriptions.trial_started_at,
        trial_starts.trial_ends_at,
        subscriptions.started_at as converted_at,
        iff(
            subscriptions.subscription_status = 'trial_expired',
            subscriptions.ended_at,
            null
        ) as expired_at,
        {{ to_reporting_date('subscriptions.trial_started_at') }}
            as trial_start_date_et,
        date_trunc(
            'month', {{ to_reporting_date('subscriptions.trial_started_at') }}
        ) as trial_start_month_et
    from subscriptions
    inner join trial_starts
        on subscriptions.subscription_id = trial_starts.subscription_id
    cross join watermark

)

select * from final
