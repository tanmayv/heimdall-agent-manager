-- When the Hub received (upserted) each bridge ACP report, on the Hub's own
-- clock. Staleness is judged by this, never by the bridge-reported checked_at,
-- which suffers from clock skew. '' = received before this column existed
-- (treated as stale, so the next status read re-detects once).
-- One atomic statement; run_migrations treats the column as completion.
ALTER TABLE bridge_provider_status ADD COLUMN acp_adapter_received_at TEXT NOT NULL DEFAULT '';
