BEGIN;
-- The older expiry index excludes delivered prompts awaiting a read receipt.
CREATE INDEX pipeline_deliveries_action_prompt_expiry
ON pipeline_deliveries(expires_at,delivery_id)
WHERE kind='prompt' AND state IN ('routed','forwarded','delivered');
COMMIT;
