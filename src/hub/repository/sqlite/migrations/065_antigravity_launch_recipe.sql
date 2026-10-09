-- Antigravity rejects a bare prompt argument. Provider tests need an initial
-- interactive prompt so the agent can call start-success and remain available
-- for user validation.
UPDATE provider_catalog
SET yolo_args = '["--dangerously-skip-permissions"]',
    prompt_args = '["--prompt-interactive"]'
WHERE provider = 'antigravity';

DELETE FROM provider_catalog_meta;
INSERT INTO provider_catalog_meta (catalog_etag)
VALUES ('sha256:95be6a0c9149771f01b489c9f89fcb66c726f6f772ee2bc454261eedb7b4b714');
