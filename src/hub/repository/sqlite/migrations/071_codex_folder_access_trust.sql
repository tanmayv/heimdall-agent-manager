-- Codex now labels its folder-trust choice "1. Trust and continue". The first
-- option is selected by default, so Enter accepts it without changing selection.
-- Keep earlier directory-trust and session-approval screens supported.
UPDATE provider_catalog
SET startup_detection = '{"enabled":true,"startup_probe_seconds":20,"capture_interval_ms":500,"blocked_patterns":[],"auto_enter_patterns":["Do you trust the contents of this directory?","Allow for this session","1. Trust and continue"],"auto_enter_pre_keys":["","",""],"startup_unknown_is_blocked":false,"sanitized_reason_mapping":[]}'
WHERE provider = 'codex';

DELETE FROM provider_catalog_meta;
INSERT INTO provider_catalog_meta (catalog_etag)
VALUES ('sha256:9a33321525edf2d51446ef87b493dd0f7792055f28ad82d973f13b1f6f2a569d');
