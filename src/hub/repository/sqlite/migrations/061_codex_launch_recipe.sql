-- Codex 0.151 accepts --ask-for-approval never; --approval-policy=never is
-- not a CLI option and made every provider validation process exit with code 2.
UPDATE provider_catalog
SET yolo_args = '["--ask-for-approval","never"]'
WHERE provider = 'codex';

DELETE FROM provider_catalog_meta;
INSERT INTO provider_catalog_meta (catalog_etag)
VALUES ('sha256:68e1170726b83202bce88d479d2417a7fefd84aa5e0d339446ba6f3bc080bccf');
