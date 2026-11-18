-- Total receivables at the latest month-end should equal what the source
-- system's invoice_status implies: amount due minus payments received for
-- every invoice the source marks open, partially_paid, or past_due. Assumes
-- nothing happens between the end of the data and the latest cutoff (as in
-- assert_latest_month_end_matches_source). Compares the balance and the
-- invoice count. Passes when empty.

with

balances as (

    select * from {{ ref('int_invoice_month_end_balances') }}

),

latest_month as (

    select max(month_start_date_et) as month_start_date_et
    from balances

),

latest_ar as (

    select
        sum(balances.balance_cents) as balance_cents,
        count(*) as invoices_owed
    from balances
    inner join latest_month
        on balances.month_start_date_et = latest_month.month_start_date_et

),

received as (

    select
        invoice_id,
        sum(amount_cents) as received_cents
    from {{ ref('stg_billing__payments') }}
    where payment_status = 'succeeded'
    group by invoice_id

),

source_ar as (

    select
        sum(
            invoices.amount_due_cents - coalesce(received.received_cents, 0)
        ) as balance_cents,
        count(*) as invoices_owed
    from {{ ref('stg_billing__invoices') }} as invoices
    left join received
        on invoices.invoice_id = received.invoice_id
    where invoices.invoice_status in ('open', 'partially_paid', 'past_due')

)

select
    latest_ar.balance_cents,
    source_ar.balance_cents as source_balance_cents,
    latest_ar.invoices_owed,
    source_ar.invoices_owed as source_invoices_owed
from latest_ar
cross join source_ar
where
    latest_ar.balance_cents is distinct from source_ar.balance_cents
    or latest_ar.invoices_owed is distinct from source_ar.invoices_owed
