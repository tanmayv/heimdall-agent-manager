-- 003_device_tokens.sql
-- Token provenance for the device-authorization flow (ELDA-4).
-- Existing rows backfill to created_from='operator' and device_label=''.
ALTER TABLE user_api_tokens ADD COLUMN created_from TEXT NOT NULL DEFAULT 'operator';
ALTER TABLE user_api_tokens ADD COLUMN device_label TEXT NOT NULL DEFAULT '';
