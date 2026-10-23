-- Each invoice's derived delinquency outcome should agree with the source
-- system's own invoice_status (as of the end of the data):
--   overdue, then paid         -> paid
--   overdue, then written off  -> uncollectible
--   overdue, still overdue     -> past_due
--   never overdue              -> anything but past_due or uncollectible
-- Returns disagreements; passes when empty.

with

invoices as (

    select * from {{ ref('stg_billing__invoices') }}

),

delinquencies as (

    select * from {{ ref('int_invoice_delinquency_periods') }}

),

compared as (

    select
        invoices.invoice_id,
        invoices.invoice_status as source_status,
        case
            when delinquencies.invoice_id is null then 'never_overdue'
            when delinquencies.end_reason = 'paid' then 'paid'
            when delinquencies.end_reason = 'written_off' then 'written_off'
            else 'still_overdue'
        end as derived_outcome
    from invoices
    left join delinquencies
        on invoices.invoice_id = delinquencies.invoice_id

)

select * from compared
where not (
    (derived_outcome = 'paid' and source_status = 'paid')
    or (derived_outcome = 'written_off' and source_status = 'uncollectible')
    or (derived_outcome = 'still_overdue' and source_status = 'past_due')
    or (
        derived_outcome = 'never_overdue'
        and source_status not in ('past_due', 'uncollectible')
    )
)
