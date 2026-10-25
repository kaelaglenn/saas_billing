-- One row per customer account, with company attributes and customer-level
-- facts rolled up from its subscriptions.
--   customer_status
--     customer:      has a live paid subscription (active or past_due)
--     trialing:      in a trial and has never paid
--     churned:       paid at some point, nothing live now
--     expired_trial: only ever had trials that expired

with

accounts as (

    select * from {{ ref('stg_billing__accounts') }}

),

subscriptions as (

    select * from {{ ref('dim_subscriptions') }}

),

per_account as (

    select
        account_id,
        count(*) as subscription_count,
        count_if(started_at is not null) as paid_subscription_count,
        count_if(is_reactivation) as reactivation_count,
        min(trial_started_at) as first_trial_started_at,
        min(started_at) as first_paid_at,
        sum(mrr_cents) as current_mrr_cents,
        count_if(
            subscription_status in ('active', 'past_due')
        ) > 0 as has_live_subscription,
        count_if(subscription_status = 'trialing') > 0 as is_trialing,
        max_by(
            subscription_id, coalesce(started_at, trial_started_at)
        ) as latest_subscription_id
    from subscriptions
    group by account_id

),

final as (

    select
        accounts.account_id,
        per_account.latest_subscription_id,
        accounts.company_name,
        accounts.industry,
        accounts.company_size_band,
        case
            when per_account.has_live_subscription then 'customer'
            when
                per_account.paid_subscription_count = 0
                and per_account.is_trialing
                then 'trialing'
            when per_account.paid_subscription_count > 0 then 'churned'
            else 'expired_trial'
        end as customer_status,
        per_account.subscription_count,
        per_account.paid_subscription_count,
        per_account.reactivation_count,
        per_account.current_mrr_cents,
        accounts.created_at,
        per_account.first_trial_started_at,
        per_account.first_paid_at
    from accounts
    inner join per_account
        on accounts.account_id = per_account.account_id

)

select * from final
