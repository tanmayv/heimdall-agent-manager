ALTER TABLE event_webhooks ADD COLUMN dedupe_header TEXT NOT NULL DEFAULT 'Idempotency-Key';
