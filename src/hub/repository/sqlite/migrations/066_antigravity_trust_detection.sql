-- Antigravity defaults to the affirmative project-trust choice. Confirm only
-- this exact chooser; authentication and unrelated consent remain interactive.
UPDATE provider_catalog
SET startup_detection = '{"enabled":true,"startup_probe_seconds":20,"capture_interval_ms":500,"blocked_patterns":[],"auto_enter_patterns":["Do you trust the contents of this project?"],"auto_enter_pre_keys":[""],"startup_unknown_is_blocked":false,"sanitized_reason_mapping":[]}'
WHERE provider = 'antigravity';

DELETE FROM provider_catalog_meta;
INSERT INTO provider_catalog_meta (catalog_etag)
VALUES ('sha256:d15a001f23a814137a0c48c6607a38b8bb94366429fc23d0865b265c722fa5f7');
