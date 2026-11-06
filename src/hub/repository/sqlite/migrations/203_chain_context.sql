-- Curated input and actionable failure edge survive automatic projection/restart.
ALTER TABLE chain_summaries ADD COLUMN curated_body TEXT NOT NULL DEFAULT '';
ALTER TABLE chain_summaries ADD COLUMN failure_fingerprint TEXT NOT NULL DEFAULT '';
-- Existing mixed bodies are recovered by the old structural extractor once.
ALTER TABLE chain_summaries ADD COLUMN curated_initialized INTEGER NOT NULL DEFAULT 0;
