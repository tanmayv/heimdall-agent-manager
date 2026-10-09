-- REQ-PROVIDER-CATALOG-2: measured machine availability and durable user
-- enablement are separate facts. Neither table can author a launch recipe.
CREATE TABLE IF NOT EXISTS bridge_provider_status (
  bridge_id    TEXT NOT NULL,
  provider     TEXT NOT NULL,
  binary_path  TEXT NOT NULL DEFAULT '',
  version_text TEXT NOT NULL DEFAULT '',
  state        TEXT NOT NULL CHECK (state IN ('absent', 'present')),
  checked_at   TEXT NOT NULL,
  PRIMARY KEY (bridge_id, provider)
);

CREATE TABLE IF NOT EXISTS bridge_provider_settings (
  bridge_id  TEXT NOT NULL,
  provider   TEXT NOT NULL REFERENCES provider_catalog(provider),
  enabled    INTEGER NOT NULL DEFAULT 0 CHECK (enabled IN (0, 1)),
  updated_at TEXT NOT NULL,
  PRIMARY KEY (bridge_id, provider)
);
