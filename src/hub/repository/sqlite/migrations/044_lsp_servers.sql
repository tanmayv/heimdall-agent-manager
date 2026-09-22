CREATE TABLE IF NOT EXISTS lsp_server_configs (
    config_id       TEXT PRIMARY KEY,
    owner_user_id   TEXT NOT NULL,
    bridge_id       TEXT NOT NULL,
    language        TEXT NOT NULL,
    cmd             TEXT NOT NULL,
    args            TEXT NOT NULL DEFAULT '',
    file_extensions TEXT NOT NULL DEFAULT '',
    root_markers    TEXT NOT NULL DEFAULT '',
    dir_prefix      TEXT NOT NULL DEFAULT '',
    created_at      TEXT NOT NULL,
    updated_at      TEXT NOT NULL,
    UNIQUE (owner_user_id, bridge_id, language, dir_prefix)
);
CREATE INDEX IF NOT EXISTS lsp_server_configs_bridge ON lsp_server_configs(owner_user_id, bridge_id);
