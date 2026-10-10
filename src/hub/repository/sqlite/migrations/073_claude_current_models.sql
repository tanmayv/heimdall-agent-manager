-- Claude Code --model values verified against official model-config docs.
-- Keep retired rows for historical references; new launches select current IDs.
-- Catalog ETags are SHA-256 of the canonical serialized catalog body at runtime.
UPDATE provider_models SET state = 'deprecated'
WHERE provider = 'claude'
  AND model_id IN ('claude-opus-5', 'claude-sonnet-4-8', 'claude-fable-5');

INSERT INTO provider_models (provider, model_id, label, state, rank) VALUES
  ('claude', 'claude-opus-5-5', 'Opus 5.5', 'active', 10),
  ('claude', 'claude-sonnet-5-5', 'Sonnet 5.5', 'active', 20),
  ('claude', 'claude-fable-5-1', 'Fable 5.1', 'active', 30)
ON CONFLICT(provider, model_id) DO UPDATE SET
  label = excluded.label, state = excluded.state, rank = excluded.rank;
