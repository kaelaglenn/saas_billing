-- MRR bridge (roll-forward): one row per reporting month explaining how MRR
-- got from the previous month-end to this one.
--   ending = starting + new + expansion + reactivation + contraction + churned
-- Movements are signed (contraction and churned are negative), so they sum
-- to net_new_mrr_cents. The opening month has an ending balance only: its
-- starting balance and movements are unknown (null), not zero.

with

months as (

    select * from {{ ref('dim_reporting_months') }}

),

subscription_months as (

    select * from {{ ref('fct_subscription_months') }}

),

monthly as (

    select
        month_start_date_et,
        sum(mrr_cents) as ending_mrr_cents,
        sum(iff(movement_type = 'new', mrr_change_cents, 0)) as new_mrr_cents,
        sum(
            iff(movement_type = 'expansion', mrr_change_cents, 0)
        ) as expansion_mrr_cents,
        sum(
            iff(movement_type = 'reactivation', mrr_change_cents, 0)
        ) as reactivation_mrr_cents,
        sum(
            iff(movement_type = 'contraction', mrr_change_cents, 0)
        ) as contraction_mrr_cents,
        sum(
            iff(movement_type = 'churn', mrr_change_cents, 0)
        ) as churned_mrr_cents,
        count_if(mrr_cents > 0) as ending_subscriptions,
        count_if(movement_type = 'new') as new_subscriptions,
        count_if(movement_type = 'reactivation') as reactivated_subscriptions,
        count_if(movement_type = 'churn') as churned_subscriptions,
        count_if(
            churn_type = 'voluntary'
        ) as voluntarily_churned_subscriptions,
        count_if(
            churn_type = 'involuntary'
        ) as involuntarily_churned_subscriptions
    from subscription_months
    group by month_start_date_et

),

final as (

    select
        months.month_start_date_et,
        months.month_end_date_et,
        months.month_label,

        -- MRR (cents)
        iff(
            months.is_opening_balance,
            null,
            lag(monthly.ending_mrr_cents) over (
                order by months.month_start_date_et
            )
        ) as starting_mrr_cents,
        iff(
            months.is_opening_balance, null, monthly.new_mrr_cents
        ) as new_mrr_cents,
        iff(
            months.is_opening_balance, null, monthly.expansion_mrr_cents
        ) as expansion_mrr_cents,
        iff(
            months.is_opening_balance, null, monthly.reactivation_mrr_cents
        ) as reactivation_mrr_cents,
        iff(
            months.is_opening_balance, null, monthly.contraction_mrr_cents
        ) as contraction_mrr_cents,
        iff(
            months.is_opening_balance, null, monthly.churned_mrr_cents
        ) as churned_mrr_cents,
        iff(
            months.is_opening_balance,
            null,
            monthly.new_mrr_cents
            + monthly.expansion_mrr_cents
            + monthly.reactivation_mrr_cents
            + monthly.contraction_mrr_cents
            + monthly.churned_mrr_cents
        ) as net_new_mrr_cents,
        monthly.ending_mrr_cents,

        -- subscriptions (counts of paying subscriptions)
        iff(
            months.is_opening_balance,
            null,
            lag(monthly.ending_subscriptions) over (
                order by months.month_start_date_et
            )
        ) as starting_subscriptions,
        iff(
            months.is_opening_balance, null, monthly.new_subscriptions
        ) as new_subscriptions,
        iff(
            months.is_opening_balance, null, monthly.reactivated_subscriptions
        ) as reactivated_subscriptions,
        iff(
            months.is_opening_balance, null, monthly.churned_subscriptions
        ) as churned_subscriptions,
        iff(
            months.is_opening_balance,
            null,
            monthly.voluntarily_churned_subscriptions
        ) as voluntarily_churned_subscriptions,
        iff(
            months.is_opening_balance,
            null,
            monthly.involuntarily_churned_subscriptions
        ) as involuntarily_churned_subscriptions,
        monthly.ending_subscriptions,

        months.is_opening_balance,
        months.is_month_closed,
        months.is_activity_complete
    from months
    inner join monthly
        on months.month_start_date_et = monthly.month_start_date_et

)

select * from final
