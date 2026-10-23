-- Periodic snapshot: one row per subscription per reporting month-end, with
-- MRR at the month-end, the change from the previous month-end, and the
-- movement that change represents. Signed: contraction and churn are negative.

with

states as (

    select * from {{ ref('int_subscription_month_end_states') }}

),

months as (

    select * from {{ ref('dim_reporting_months') }}

),

reactivations as (

    select distinct subscription_id
    from {{ ref('stg_billing__subscription_events') }}
    where event_type = 'subscription_started' and is_reactivation

),

with_previous as (

    select
        states.*,
        -- the previous row only counts if it's the immediately preceding month
        lag(states.month_start_date) over (
            partition by states.subscription_id
            order by states.month_start_date
        ) = dateadd(month, -1, states.month_start_date) as has_previous_month,
        lag(states.mrr_cents) over (
            partition by states.subscription_id
            order by states.month_start_date
        ) as lagged_mrr_cents,
        lag(states.plan) over (
            partition by states.subscription_id
            order by states.month_start_date
        ) as previous_plan,
        lag(states.seats) over (
            partition by states.subscription_id
            order by states.month_start_date
        ) as previous_seats,
        lag(states.billing_frequency) over (
            partition by states.subscription_id
            order by states.month_start_date
        ) as previous_billing_frequency
    from states

),

classified as (

    select
        with_previous.*,
        months.is_opening_balance,
        reactivations.subscription_id is not null as is_reactivation,
        iff(
            coalesce(with_previous.has_previous_month, false),
            with_previous.lagged_mrr_cents,
            0
        ) as previous_mrr_cents
    from with_previous
    inner join months
        on with_previous.month_start_date = months.month_start_date
    left join reactivations
        on with_previous.subscription_id = reactivations.subscription_id

),

final as (

    select
        subscription_month_id,
        subscription_id,
        account_id,
        month_start_date,
        month_end_date,
        subscription_status,
        plan,
        billing_frequency,
        seats,
        mrr_cents,
        previous_mrr_cents,
        mrr_cents - previous_mrr_cents as mrr_change_cents,
        case
            when is_opening_balance then 'opening'
            when previous_mrr_cents = 0 and mrr_cents > 0 and is_reactivation
                then 'reactivation'
            when previous_mrr_cents = 0 and mrr_cents > 0 then 'new'
            when previous_mrr_cents > 0 and mrr_cents = 0 then 'churn'
            when mrr_cents > previous_mrr_cents then 'expansion'
            when mrr_cents < previous_mrr_cents then 'contraction'
            when mrr_cents > 0 then 'unchanged'
            -- no MRR on either side (trial months, expired trials)
            else 'none'
        end as movement_type,
        case
            when
                not is_opening_balance
                and previous_mrr_cents > 0
                and mrr_cents = 0
                then
                    iff(
                        subscription_status = 'lapsed',
                        'involuntary',
                        'voluntary'
                    )
        end as churn_type,
        coalesce(
            has_previous_month and seats != previous_seats, false
        ) as has_seat_change,
        coalesce(
            has_previous_month and plan != previous_plan, false
        ) as has_plan_change,
        coalesce(
            has_previous_month
            and billing_frequency != previous_billing_frequency,
            false
        ) as has_frequency_change,
        is_reactivation,
        is_month_closed,
        is_activity_complete
    from classified

)

select * from final
