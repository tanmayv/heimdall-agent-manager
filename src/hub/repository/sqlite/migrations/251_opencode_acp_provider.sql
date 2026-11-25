-- Operator-installed OpenCode with stdio ACP only.
BEGIN IMMEDIATE;
INSERT INTO provider_catalog (
  provider, display_name, icon_url, binary, base_args, yolo_args, model_flag,
  prompt_args, prompt_delivery, starter_prompt, bootstrap_file, skill_dir,
  startup_detection, activity_detection, state, rank,
  transports, default_transport, acp_recipe
) VALUES (
  'opencode', 'OpenCode', '/api/v1/providers/opencode/icon', 'opencode', '[]', '[]', '', '[]', 'flag-injection',
  'First, run: {ctl_bin} agent start-success. Then read AGENTS.md for context.',
  'AGENTS.md', '.agents/skills',
  '{"enabled":false,"startup_probe_seconds":20,"capture_interval_ms":500,"blocked_patterns":[],"auto_enter_patterns":[],"auto_enter_pre_keys":[],"startup_unknown_is_blocked":false,"sanitized_reason_mapping":[]}',
  '{"enabled":false,"sample_line_count":20,"ignore_bottom_lines":0,"check_interval_seconds":15,"min_gap_ms":100,"max_gap_ms":500}', 'active', 70,
  '["acp"]', 'acp',
  '{"command":"opencode","args":["acp"],"env":{},"protocol_version":1,"adapter_package":"opencode","adapter_version":"1.19.6"}'
) ON CONFLICT(provider) DO NOTHING;

INSERT INTO provider_models (provider, model_id, label, state, rank) VALUES
  ('opencode', 'default', 'OpenCode default (chosen by OpenCode)', 'active', 10)
ON CONFLICT(provider, model_id) DO NOTHING;

INSERT INTO provider_icons (provider, content_type, content) VALUES
  ('opencode', 'image/svg+xml', '<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64"><rect width="64" height="64" rx="15" fill="#7b3ff2"/><text x="32" y="43" text-anchor="middle" font-family="sans-serif" font-size="32" font-weight="700" fill="#fff">O</text></svg>')
ON CONFLICT(provider) DO NOTHING;

DELETE FROM provider_catalog_meta;
INSERT INTO provider_catalog_meta (catalog_etag) VALUES ('sha256:66130e4af1df89751f514a1328421e7c01b4587898f4f642578ff1589eca3ed6');
COMMIT;
