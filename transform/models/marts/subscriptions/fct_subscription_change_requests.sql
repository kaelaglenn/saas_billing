-- Transaction fact: one row per customer-initiated change or cancellation,
-- with when it was requested, when it was due to take effect, and whether it
-- did. Published from int_subscription_change_requests, with reporting dates.

select
    change_request_id,
    subscription_id,
    account_id,
    request_type,
    from_plan,
    to_plan,
    from_billing_frequency,
    to_billing_frequency,
    cancel_reason,
    outcome,
    seat_delta,
    is_scheduled,
    requested_at,
    effective_at,
    ingested_at,
    {{ to_reporting_date('requested_at') }} as requested_date_et,
    {{ to_reporting_date('effective_at') }} as effective_date_et
from {{ ref('int_subscription_change_requests') }}
