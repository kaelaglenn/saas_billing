-- SCD Type 2 history of each subscription's effective state over
-- [valid_from, valid_to). Published from int_subscription_history.

select
    subscription_history_id,
    subscription_id,
    account_id,
    subscription_status,
    plan,
    billing_frequency,
    seats,
    mrr_cents,
    valid_from,
    valid_to,
    is_current
from {{ ref('int_subscription_history') }}
