-- No legacy import: revision zero remains legacy until the first Apply.
CREATE TABLE IF NOT EXISTS bridge_fleet_settings (
    bridge_id TEXT PRIMARY KEY REFERENCES bridges(bridge_id) ON DELETE CASCADE,
    owner_user_id TEXT NOT NULL,
    revision INTEGER NOT NULL CHECK(revision > 0),
    provider TEXT NOT NULL,
    provider_profile TEXT NOT NULL,
    model TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_bridge_fleet_owner ON bridge_fleet_settings(owner_user_id, bridge_id);
CREATE TABLE IF NOT EXISTS bridge_fleet_agent_overrides (
    bridge_id TEXT NOT NULL REFERENCES bridge_fleet_settings(bridge_id) ON DELETE CASCADE,
    agent_id TEXT NOT NULL REFERENCES agents(agent_id) ON DELETE CASCADE,
    provider TEXT NOT NULL,
    provider_profile TEXT NOT NULL,
    model TEXT NOT NULL,
    PRIMARY KEY(bridge_id, agent_id)
);
CREATE INDEX IF NOT EXISTS idx_bridge_fleet_override_agent ON bridge_fleet_agent_overrides(agent_id, bridge_id);
CREATE TRIGGER IF NOT EXISTS fleet_override_agent_delete_revision
BEFORE DELETE ON agents
BEGIN
    UPDATE bridge_fleet_settings SET revision=revision+1
    WHERE bridge_id IN (SELECT bridge_id FROM bridge_fleet_agent_overrides WHERE agent_id=old.agent_id);
END;

-- Separate provenance from kind='agent': legacy unknown is absence of a row.
CREATE TABLE IF NOT EXISTS instance_fleet_scope (
    agent_instance_id TEXT PRIMARY KEY REFERENCES agent_instances(agent_instance_id) ON DELETE CASCADE,
    scope TEXT NOT NULL CHECK(scope IN ('chain','manual','excluded'))
);
CREATE INDEX IF NOT EXISTS idx_fleet_bots_instance ON bots(agent_instance_id);
-- Scope's nonempty-target probe has its own partial index. A generic target
-- index displaces action_runs_instance_routed on the selective delivery path.
CREATE INDEX IF NOT EXISTS idx_fleet_actions_instance ON action_runs(target_instance_id) WHERE target_instance_id != '';
CREATE INDEX IF NOT EXISTS idx_fleet_members_instance ON task_chain_members(agent_instance_id, owner_user_id, chain_id);
