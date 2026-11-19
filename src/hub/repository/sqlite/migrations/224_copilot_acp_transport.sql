-- Copilot native ACP is opt-in; existing profiles and launches remain PTY.
BEGIN IMMEDIATE;
UPDATE provider_catalog SET transports='["pty","acp"]', default_transport='pty', acp_recipe='{"command":"copilot","args":["--acp","--stdio"],"env":{"COPILOT_AUTO_UPDATE":"false"},"protocol_version":1,"adapter_package":"@github/copilot","adapter_version":"1.0.114"}' WHERE provider='copilot';
DELETE FROM provider_catalog_meta;
INSERT INTO provider_catalog_meta(catalog_etag) VALUES ('sha256:a601c5c6fffc623c1824a1ffe5f7a9951fa4c2108ab48539f96390ba2c482f0c');
COMMIT;
