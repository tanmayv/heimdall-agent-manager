-- Opt-in Codex app-server runtime, detected on the bridge host (codex-cli
-- >= 0.162.0). This recipe is checked against the compiled Codex descriptor;
-- the bridge never downloads the CLI. Existing PTY launch columns, bridge
-- overrides, profiles, and instance transport snapshots remain unchanged.
-- Ship Hub and Bridge together: older bridges reject unknown ACP recipes.
BEGIN IMMEDIATE;
UPDATE provider_catalog
SET transports = '["pty","acp"]', default_transport = 'pty',
    acp_recipe = '{"command":"codex","args":["app-server"],"env":{},"protocol_version":1,"adapter_package":"codex","adapter_version":"0.162.0"}'
WHERE provider = 'codex';

DELETE FROM provider_catalog_meta;
INSERT INTO provider_catalog_meta (catalog_etag) VALUES ('sha256:7bf12dada36bd7ababf7478919e5ca9dffded62253f4268eeca168d06b6fd907');
COMMIT;
