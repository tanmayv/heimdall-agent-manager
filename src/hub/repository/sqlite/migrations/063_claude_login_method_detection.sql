-- The first-run flow reaches this chooser after the theme preference. Login is
-- deliberately not automated: surface a sanitized blocked state so the user can
-- authenticate in their own environment without Heimdall choosing credentials.
UPDATE provider_catalog
SET startup_detection = '{"enabled":true,"startup_probe_seconds":20,"capture_interval_ms":500,"blocked_patterns":["Select login method:","Not logged in. Run claude auth login to authenticate.","Please run /login"],"auto_enter_patterns":["Choose the text style that looks best with your terminal","Yes, I trust this folder"],"auto_enter_pre_keys":["Up","Up"],"startup_unknown_is_blocked":false,"sanitized_reason_mapping":["login=Claude Code authentication is required","login=Claude Code authentication is required","login=Claude Code authentication is required"]}'
WHERE provider = 'claude';

DELETE FROM provider_catalog_meta;
INSERT INTO provider_catalog_meta (catalog_etag)
VALUES ('sha256:68e1170726b83202bce88d479d2417a7fefd84aa5e0d339446ba6f3bc080bccf');
