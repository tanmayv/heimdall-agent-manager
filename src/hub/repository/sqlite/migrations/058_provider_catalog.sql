-- REQ-PROVIDER-CATALOG-1: the Hub is the sole owner of provider launch recipes
-- and model identifiers. Bridges measure only local availability and never author
-- executable arguments.
CREATE TABLE IF NOT EXISTS provider_catalog (
  provider           TEXT PRIMARY KEY,
  display_name       TEXT NOT NULL,
  icon_url           TEXT NOT NULL,
  binary             TEXT NOT NULL,
  base_args          TEXT NOT NULL,
  yolo_args          TEXT NOT NULL,
  model_flag         TEXT NOT NULL,
  prompt_args        TEXT NOT NULL,
  prompt_delivery    TEXT NOT NULL,
  starter_prompt     TEXT NOT NULL,
  bootstrap_file     TEXT NOT NULL,
  skill_dir          TEXT NOT NULL,
  startup_detection  TEXT NOT NULL,
  activity_detection TEXT NOT NULL,
  state              TEXT NOT NULL CHECK (state IN ('active', 'deprecated')),
  rank               INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS provider_models (
  provider TEXT NOT NULL REFERENCES provider_catalog(provider) ON DELETE CASCADE,
  model_id TEXT NOT NULL,
  label    TEXT NOT NULL,
  state    TEXT NOT NULL CHECK (state IN ('active', 'deprecated')),
  rank     INTEGER NOT NULL,
  PRIMARY KEY (provider, model_id)
);

CREATE TABLE IF NOT EXISTS provider_catalog_meta (
  catalog_etag TEXT NOT NULL
);

-- icon_url remains a stable Hub-relative public contract. The bytes live here,
-- rather than in UI assets or remote URLs, so self-hosted and offline Hubs serve
-- the exact catalog revision shipped by this migration.
CREATE TABLE IF NOT EXISTS provider_icons (
  provider     TEXT PRIMARY KEY REFERENCES provider_catalog(provider) ON DELETE CASCADE,
  content_type TEXT NOT NULL,
  content      TEXT NOT NULL
);

INSERT OR REPLACE INTO provider_catalog (
  provider, display_name, icon_url, binary, base_args, yolo_args, model_flag,
  prompt_args, prompt_delivery, starter_prompt, bootstrap_file, skill_dir,
  startup_detection, activity_detection, state, rank
) VALUES
  ('claude', 'Claude Code', '/api/v1/providers/claude/icon', 'claude', '[]', '["--dangerously-skip-permissions"]', '--model', '[]', 'flag-injection',
   'First, run: {ctl_bin} agent start-success. Then read your bootstrap file (CLAUDE.md) for context, identity, and what you can do.',
   'CLAUDE.md', '.claude/skills',
   '{"enabled":true,"startup_probe_seconds":20,"capture_interval_ms":500,"blocked_patterns":["Select login method:","Not logged in. Run claude auth login to authenticate.","Please run /login"],"auto_enter_patterns":["Choose the text style that looks best with your terminal","Yes, I trust this folder"],"auto_enter_pre_keys":["Up","Up"],"startup_unknown_is_blocked":false,"sanitized_reason_mapping":["login=Claude Code authentication is required","login=Claude Code authentication is required","login=Claude Code authentication is required"]}',
   '{"enabled":true,"sample_line_count":20,"ignore_bottom_lines":0,"check_interval_seconds":15,"min_gap_ms":100,"max_gap_ms":500}', 'active', 10),
  ('codex', 'Codex', '/api/v1/providers/codex/icon', 'codex', '[]', '["--ask-for-approval","never"]', '-m', '[]', 'flag-injection',
   'First, run: {ctl_bin} agent start-success. Then read AGENTS.md for context.',
   'AGENTS.md', '.codex/skills',
   '{"enabled":true,"startup_probe_seconds":20,"capture_interval_ms":500,"blocked_patterns":[],"auto_enter_patterns":["Do you trust the contents of this directory?","Allow for this session"],"auto_enter_pre_keys":["",""],"startup_unknown_is_blocked":false,"sanitized_reason_mapping":[]}',
   '{"enabled":true,"sample_line_count":20,"ignore_bottom_lines":0,"check_interval_seconds":15,"min_gap_ms":100,"max_gap_ms":500}', 'active', 20),
  ('copilot', 'GitHub Copilot', '/api/v1/providers/copilot/icon', 'copilot', '[]', '[]', '--model', '[]', 'flag-injection',
   'First, run: {ctl_bin} agent start-success. Then read AGENTS.md for context.',
   'AGENTS.md', '.copilot/skills',
   '{"enabled":true,"startup_probe_seconds":15,"capture_interval_ms":500,"blocked_patterns":[],"auto_enter_patterns":[],"auto_enter_pre_keys":[],"startup_unknown_is_blocked":false,"sanitized_reason_mapping":[]}',
   '{"enabled":true,"sample_line_count":20,"ignore_bottom_lines":0,"check_interval_seconds":15,"min_gap_ms":100,"max_gap_ms":500}', 'active', 30),
  ('antigravity', 'Antigravity', '/api/v1/providers/antigravity/icon', 'agy', '[]', '["--dangerously-skip-permissions"]', '--model', '["--prompt-interactive"]', 'flag-injection',
   'First, run: {ctl_bin} agent start-success. Then read AGENTS.md for context.',
   'AGENTS.md', '.agents/skills',
   '{"enabled":true,"startup_probe_seconds":20,"capture_interval_ms":500,"blocked_patterns":[],"auto_enter_patterns":["Do you trust the contents of this project?"],"auto_enter_pre_keys":[""],"startup_unknown_is_blocked":false,"sanitized_reason_mapping":[]}',
   '{"enabled":true,"sample_line_count":20,"ignore_bottom_lines":0,"check_interval_seconds":15,"min_gap_ms":100,"max_gap_ms":500}', 'active', 40);

INSERT OR REPLACE INTO provider_models (provider, model_id, label, state, rank) VALUES
  ('claude', 'claude-opus-5', 'Opus 5', 'active', 10),
  ('claude', 'claude-sonnet-4-8', 'Sonnet 4.8', 'active', 20),
  ('claude', 'claude-fable-5', 'Fable 5', 'active', 30),
  ('codex', 'gpt-5', 'GPT-5', 'active', 10),
  ('codex', 'gpt-5-pro', 'GPT-5 Pro', 'active', 20),
  ('codex', 'gpt-4o', 'GPT-4o', 'active', 30),
  ('codex', 'gpt-4o-mini', 'GPT-4o mini', 'active', 40),
  ('copilot', 'claude-sonnet-4.6', 'Claude Sonnet 4.6', 'active', 10),
  ('copilot', 'claude-opus-4.6', 'Claude Opus 4.6', 'active', 20),
  ('copilot', 'gpt-4o', 'GPT-4o', 'active', 30),
  ('antigravity', 'Gemini 3.5 Flash (Medium)', 'Gemini 3.5 Flash (Medium)', 'active', 10),
  ('antigravity', 'Gemini 3.1 Pro (High)', 'Gemini 3.1 Pro (High)', 'active', 20);

DELETE FROM provider_catalog_meta;
INSERT INTO provider_catalog_meta (catalog_etag) VALUES ('sha256:d15a001f23a814137a0c48c6607a38b8bb94366429fc23d0865b265c722fa5f7');

INSERT OR REPLACE INTO provider_icons (provider, content_type, content) VALUES
  ('claude', 'image/svg+xml', '<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64"><rect width="64" height="64" rx="15" fill="#d97757"/><text x="32" y="40" text-anchor="middle" font-family="sans-serif" font-size="27" font-weight="700" fill="#fff">C</text></svg>'),
  ('codex', 'image/svg+xml', '<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64"><rect width="64" height="64" rx="15" fill="#111827"/><circle cx="32" cy="32" r="15" fill="none" stroke="#fff" stroke-width="5"/><circle cx="32" cy="32" r="4" fill="#fff"/></svg>'),
  ('copilot', 'image/svg+xml', '<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64"><rect width="64" height="64" rx="15" fill="#6e40c9"/><text x="32" y="39" text-anchor="middle" font-family="sans-serif" font-size="20" font-weight="700" fill="#fff">GH</text></svg>'),
  ('antigravity', 'image/svg+xml', '<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64"><rect width="64" height="64" rx="15" fill="#2563eb"/><path d="M17 44 32 16l15 28h-8l-7-14-7 14z" fill="#fff"/></svg>');
