-- Preserve tracked extension/update commands while allowing pinned ACP installs.
BEGIN IMMEDIATE;
CREATE TABLE provider_extension_commands_acp (
 command_id TEXT PRIMARY KEY,
 bridge_id TEXT NOT NULL REFERENCES bridges(bridge_id),
 kind TEXT NOT NULL CHECK(kind IN ('bridge_update','discovery','install','uninstall','install_acp_adapter')),
 provider TEXT NOT NULL DEFAULT '',
 parent_id TEXT NOT NULL DEFAULT '',
 state TEXT NOT NULL,
 message TEXT NOT NULL DEFAULT '',
 target_version TEXT NOT NULL DEFAULT '',
 target_commit TEXT NOT NULL DEFAULT '',
 source_version TEXT NOT NULL DEFAULT '',
 source_commit TEXT NOT NULL DEFAULT '',
 update_extensions INTEGER NOT NULL DEFAULT 0,
 progress INTEGER NOT NULL DEFAULT 0,
 profile_id TEXT NOT NULL DEFAULT ''
);
INSERT INTO provider_extension_commands_acp SELECT command_id,bridge_id,kind,provider,parent_id,state,message,target_version,target_commit,source_version,source_commit,update_extensions,progress,profile_id FROM provider_extension_commands;
DROP TABLE provider_extension_commands;
ALTER TABLE provider_extension_commands_acp RENAME TO provider_extension_commands;
CREATE INDEX provider_extension_commands_bridge ON provider_extension_commands(bridge_id);
CREATE UNIQUE INDEX provider_extension_commands_followup ON provider_extension_commands(parent_id,kind,provider,profile_id) WHERE parent_id<>'';
COMMIT;
