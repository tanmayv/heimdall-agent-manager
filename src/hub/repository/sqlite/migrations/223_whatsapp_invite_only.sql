-- WhatsApp is invite-only: no plan includes it; an operator grants it per
-- account with override_whatsapp_enabled (NULL = plan value, 0/1 = explicit).
-- Atomic before its ledger row; the last column proves completion on restart.
BEGIN IMMEDIATE;
ALTER TABLE billing_plans ADD COLUMN whatsapp_enabled INTEGER NOT NULL DEFAULT 0 CHECK (whatsapp_enabled IN (0, 1));
ALTER TABLE account_entitlements ADD COLUMN whatsapp_enabled INTEGER NOT NULL DEFAULT 0 CHECK (whatsapp_enabled IN (0, 1));
DROP TRIGGER users_billing_defaults;
CREATE TRIGGER users_billing_defaults AFTER INSERT ON users BEGIN
    INSERT INTO account_billing (user_id, created_at, updated_at)
        VALUES (NEW.user_id, NEW.created_at, NEW.updated_at);
    INSERT INTO account_entitlements (user_id, max_bridges, terminal_streaming_enabled, terminal_input_enabled, max_concurrent_streams, shells_enabled, whatsapp_enabled, updated_at)
        SELECT NEW.user_id, max_bridges, terminal_streaming_enabled, terminal_input_enabled, max_concurrent_streams, shells_enabled, whatsapp_enabled, NEW.updated_at
        FROM billing_plans WHERE plan_id = 'free';
END;
ALTER TABLE account_entitlements ADD COLUMN override_whatsapp_enabled INTEGER CHECK (override_whatsapp_enabled IN (0, 1));
COMMIT;
