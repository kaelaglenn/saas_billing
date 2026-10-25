-- The latest month's ending MRR and paying-subscription count should equal
-- what the source system's current-state table implies: seats x list price
-- (annual / 12) for subscriptions currently active or past_due. That table is
-- maintained separately from the event log, so this checks the whole
-- event-sourcing pipeline end to end. Same assumption as
-- assert_latest_month_end_matches_source: nothing happens between the end of
-- the data and the latest cutoff. Passes when empty.

with

latest_bridge as (

    select
        ending_mrr_cents,
        ending_subscriptions
    from {{ ref('fct_mrr_bridge') }}
    qualify month_start_date_et = max(month_start_date_et) over ()

),

source_current as (

    select
        sum(
            subscriptions.seats * prices.unit_price_cents
            / iff(subscriptions.billing_frequency = 'annual', 12, 1)
        )::integer as mrr_cents,
        count(*) as paying_subscriptions
    from {{ ref('stg_billing__subscriptions') }} as subscriptions
    inner join {{ ref('plan_prices') }} as prices
        on
            subscriptions.plan = prices.plan
            and subscriptions.billing_frequency = prices.billing_frequency
    where subscriptions.subscription_status in ('active', 'past_due')

)

select
    latest_bridge.ending_mrr_cents,
    source_current.mrr_cents as source_mrr_cents,
    latest_bridge.ending_subscriptions,
    source_current.paying_subscriptions as source_paying_subscriptions
from latest_bridge
cross join source_current
where
    latest_bridge.ending_mrr_cents != source_current.mrr_cents
    or latest_bridge.ending_subscriptions
    != source_current.paying_subscriptions
