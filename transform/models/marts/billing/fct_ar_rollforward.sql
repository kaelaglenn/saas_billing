-- AR roll-forward: one row per reporting month explaining how accounts
-- receivable got from the previous month-end to this one.
--   ending = starting + invoiced - collected - written_off
-- Amounts are positive; the formula carries the signs. Ending AR and its aging
-- come from the month-end snapshot; the flows come from invoices and
-- payments, so the identity is a real check. The opening month has an ending
-- balance only: its starting balance and flows are unknown (null), not zero.

with

months as (

    select * from {{ ref('dim_reporting_months') }}

),

balances as (

    select
        month_start_date_et,
        sum(balance_cents) as ending_ar_cents,
        sum(
            iff(aging_bucket = 'current', balance_cents, 0)
        ) as current_ar_cents,
        sum(
            iff(aging_bucket = '1-30', balance_cents, 0)
        ) as past_due_1_30_ar_cents,
        sum(
            iff(aging_bucket = '31-60', balance_cents, 0)
        ) as past_due_31_60_ar_cents,
        sum(
            iff(aging_bucket = '61-90', balance_cents, 0)
        ) as past_due_61_90_ar_cents,
        sum(
            iff(aging_bucket = '90+', balance_cents, 0)
        ) as past_due_90_plus_ar_cents,
        count(*) as ending_invoices_owed
    from {{ ref('fct_ar_month_end_balances') }}
    group by month_start_date_et

),

invoiced as (

    select
        issued_month_et as month_start_date_et,
        sum(amount_due_cents) as invoiced_cents,
        count(*) as invoices_issued
    from {{ ref('fct_invoices') }}
    group by issued_month_et

),

collected as (

    select
        attempted_month_et as month_start_date_et,
        sum(received_amount_cents) as collected_cents
    from {{ ref('fct_payments') }}
    where is_succeeded
    group by attempted_month_et

),

written_off as (

    select
        date_trunc('month', written_off_date_et) as month_start_date_et,
        sum(written_off_cents) as written_off_cents,
        count(*) as invoices_written_off
    from {{ ref('fct_invoices') }}
    where payment_outcome = 'written_off'
    group by date_trunc('month', written_off_date_et)

),

monthly as (

    select
        months.month_start_date_et,
        months.month_end_date_et,
        months.month_label,
        months.is_opening_balance,
        months.is_month_closed,
        months.is_activity_complete,
        coalesce(balances.ending_ar_cents, 0) as ending_ar_cents,
        coalesce(balances.current_ar_cents, 0) as current_ar_cents,
        coalesce(
            balances.past_due_1_30_ar_cents, 0
        ) as past_due_1_30_ar_cents,
        coalesce(
            balances.past_due_31_60_ar_cents, 0
        ) as past_due_31_60_ar_cents,
        coalesce(
            balances.past_due_61_90_ar_cents, 0
        ) as past_due_61_90_ar_cents,
        coalesce(
            balances.past_due_90_plus_ar_cents, 0
        ) as past_due_90_plus_ar_cents,
        coalesce(balances.ending_invoices_owed, 0) as ending_invoices_owed,
        coalesce(invoiced.invoiced_cents, 0) as invoiced_cents,
        coalesce(invoiced.invoices_issued, 0) as invoices_issued,
        coalesce(collected.collected_cents, 0) as collected_cents,
        coalesce(written_off.written_off_cents, 0) as written_off_cents,
        coalesce(
            written_off.invoices_written_off, 0
        ) as invoices_written_off
    from months
    left join balances
        on months.month_start_date_et = balances.month_start_date_et
    left join invoiced
        on months.month_start_date_et = invoiced.month_start_date_et
    left join collected
        on months.month_start_date_et = collected.month_start_date_et
    left join written_off
        on months.month_start_date_et = written_off.month_start_date_et

),

final as (

    select
        month_start_date_et,
        month_end_date_et,
        month_label,

        -- AR (cents)
        iff(
            is_opening_balance,
            null,
            lag(ending_ar_cents) over (order by month_start_date_et)
        ) as starting_ar_cents,
        iff(is_opening_balance, null, invoiced_cents) as invoiced_cents,
        iff(is_opening_balance, null, collected_cents) as collected_cents,
        iff(is_opening_balance, null, written_off_cents) as written_off_cents,
        ending_ar_cents,

        -- ending AR by aging bucket (cents); sums to ending_ar_cents
        current_ar_cents,
        past_due_1_30_ar_cents,
        past_due_31_60_ar_cents,
        past_due_61_90_ar_cents,
        past_due_90_plus_ar_cents,

        -- invoice counts
        iff(is_opening_balance, null, invoices_issued) as invoices_issued,
        iff(
            is_opening_balance, null, invoices_written_off
        ) as invoices_written_off,
        ending_invoices_owed,

        is_opening_balance,
        is_month_closed,
        is_activity_complete
    from monthly

)

select * from final
