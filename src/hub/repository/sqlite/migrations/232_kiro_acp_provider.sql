-- Kiro CLI (AWS) as an ACP-only, detect-only provider. Verified against
-- kiro-cli 3.5.0 (`kiro-cli acp`, protocolVersion 1). The Bridge never installs
-- it: the user installs kiro-cli on the bridge host (on NixOS, the musl build)
-- and the Bridge detects `binary`, checks `kiro-cli --version` >= 3.5.0 and
-- probes initialize. The PTY columns are inert; transports omits pty, so Kiro
-- is never offered or launched as a PTY provider.
-- Only the agent-default model is listed: Kiro's model ids are visible only to
-- a signed-in session and are not verified yet, and an unlisted id would fail
-- the launch with acp_model_unavailable. 'default' sends no set_config_option.
-- Requires a Bridge with the Kiro ACP descriptor: older Bridges reject a catalog
-- with an unknown ACP row and keep their cached copy until they update.
BEGIN IMMEDIATE;
INSERT INTO provider_catalog (
  provider, display_name, icon_url, binary, base_args, yolo_args, model_flag,
  prompt_args, prompt_delivery, starter_prompt, bootstrap_file, skill_dir,
  startup_detection, activity_detection, state, rank,
  transports, default_transport, acp_recipe
) VALUES (
  'kiro', 'Kiro', '/api/v1/providers/kiro/icon', 'kiro-cli', '[]', '[]', '', '[]', 'flag-injection',
  'First, run: {ctl_bin} agent start-success. Then read AGENTS.md for context.',
  'AGENTS.md', '.agents/skills',
  '{"enabled":false,"startup_probe_seconds":20,"capture_interval_ms":500,"blocked_patterns":[],"auto_enter_patterns":[],"auto_enter_pre_keys":[],"startup_unknown_is_blocked":false,"sanitized_reason_mapping":[]}',
  '{"enabled":false,"sample_line_count":20,"ignore_bottom_lines":0,"check_interval_seconds":15,"min_gap_ms":100,"max_gap_ms":500}', 'active', 60,
  '["acp"]', 'acp',
  '{"command":"kiro-cli","args":["acp","--agent-engine","v3"],"env":{},"protocol_version":1,"adapter_package":"kiro-cli","adapter_version":"3.5.0"}'
) ON CONFLICT(provider) DO NOTHING;

INSERT INTO provider_models (provider, model_id, label, state, rank) VALUES
  ('kiro', 'default', 'Kiro default (chosen by Kiro)', 'active', 10)
ON CONFLICT(provider, model_id) DO NOTHING;

INSERT INTO provider_icons (provider, content_type, content) VALUES
  ('kiro', 'image/svg+xml', '<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64"><rect width="64" height="64" rx="15" fill="#7b3ff2"/><text x="32" y="43" text-anchor="middle" font-family="sans-serif" font-size="32" font-weight="700" fill="#fff">K</text></svg>')
ON CONFLICT(provider) DO NOTHING;

DELETE FROM provider_catalog_meta;
INSERT INTO provider_catalog_meta (catalog_etag) VALUES ('sha256:d063fb1a912b25366c6a86ed0dae31c523907876467cdc7a53b9041d5cb16a31');
COMMIT;
