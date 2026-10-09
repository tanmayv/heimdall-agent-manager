-- Codex approval policy and sandbox policy are independent. Heimdall agents
-- must be able to reach the local Bridge Unix socket, so the provider's yolo
-- recipe needs full sandbox access in addition to non-interactive approvals.
UPDATE provider_catalog
SET yolo_args = '["--ask-for-approval","never","--sandbox","danger-full-access"]'
WHERE provider = 'codex';

-- The original catalog shipped API model names that the ChatGPT-authenticated
-- Codex CLI does not expose. Replace the complete Codex model set with the
-- selectable model ids advertised by Codex 0.151.
DELETE FROM provider_models WHERE provider = 'codex';

INSERT INTO provider_models (provider, model_id, label, state, rank) VALUES
  ('codex', 'gpt-5.6-sol', 'GPT-5.6-Sol', 'active', 10),
  ('codex', 'gpt-5.6-terra', 'GPT-5.6-Terra', 'active', 20),
  ('codex', 'gpt-5.6-luna', 'GPT-5.6-Luna', 'active', 30);

DELETE FROM provider_catalog_meta;
INSERT INTO provider_catalog_meta (catalog_etag)
VALUES ('sha256:4c73446effbd9dee1bd7161b628da35d99b01308d0ba98f4f49689bd92c67c75');
