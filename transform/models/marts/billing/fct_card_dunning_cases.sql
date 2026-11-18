-- Accumulating snapshot: one row per dunning case (a card invoice whose first
-- charge failed), with its milestones (first failure, then recovered or
-- written off) and outcome. Outcome rules, including the inferred
-- recovered_after_card_update, live in int_card_dunning_outcomes.

with

cases as (

    select * from {{ ref('int_card_dunning_outcomes') }}

),

final as (

    select
        invoice_id,
        subscription_id,
        account_id,
        dunning_outcome,
        first_failure_reason,
        attempt_count,
        recovery_attempt_number,
        days_to_recover,
        dunning_outcome like 'recovered%' as is_recovered,
        dunning_outcome != 'in_dunning' as is_resolved,
        first_failed_at,
        recovered_at,
        written_off_at,
        {{ to_reporting_date('first_failed_at') }} as first_failed_date_et,
        date_trunc(
            'month', {{ to_reporting_date('first_failed_at') }}
        ) as first_failed_month_et
    from cases

)

select * from final
