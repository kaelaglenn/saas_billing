-- Each invoice's derived payment_outcome should agree with the source
-- system's own invoice_status (as of the end of the data):
--   paid_on_time, paid_late -> paid
--   written_off             -> uncollectible
--   overdue                 -> past_due
--   open                    -> open (nothing paid) or partially_paid
-- Returns disagreements; passes when empty.

with

summary as (

    select * from {{ ref('int_invoice_payment_summary') }}

),

invoices as (

    select * from {{ ref('stg_billing__invoices') }}

)

select
    summary.invoice_id,
    summary.payment_outcome,
    summary.amount_paid_cents,
    invoices.invoice_status as source_status
from summary
inner join invoices
    on summary.invoice_id = invoices.invoice_id
where not (
    (
        summary.payment_outcome in ('paid_on_time', 'paid_late')
        and invoices.invoice_status = 'paid'
    )
    or (
        summary.payment_outcome = 'written_off'
        and invoices.invoice_status = 'uncollectible'
    )
    or (
        summary.payment_outcome = 'overdue'
        and invoices.invoice_status = 'past_due'
    )
    or (
        summary.payment_outcome = 'open'
        and invoices.invoice_status
        = iff(summary.amount_paid_cents > 0, 'partially_paid', 'open')
    )
)
