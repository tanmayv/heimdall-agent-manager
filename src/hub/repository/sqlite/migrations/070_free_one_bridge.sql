-- Change catalog defaults and existing snapshots while preserving explicit grants.
UPDATE billing_plans SET max_bridges = 1 WHERE plan_id = 'free';
UPDATE account_entitlements
SET max_bridges = COALESCE(override_max_bridges, 1)
WHERE user_id IN (
    SELECT user_id FROM account_billing
    WHERE plan_id = 'free' OR status IN ('free', 'paused', 'canceled')
       OR (status = 'past_due' AND grace_until <= strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
