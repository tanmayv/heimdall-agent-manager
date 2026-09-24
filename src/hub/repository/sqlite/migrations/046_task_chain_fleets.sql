CREATE TABLE IF NOT EXISTS task_chain_fleets (
    task_chain_id TEXT NOT NULL,
    agent_id TEXT NOT NULL,
    capacity INTEGER NOT NULL DEFAULT 1,
    min_warm INTEGER NOT NULL DEFAULT 0,
    idle_ttl_seconds INTEGER NOT NULL DEFAULT 600,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    PRIMARY KEY (task_chain_id, agent_id),
    FOREIGN KEY (task_chain_id) REFERENCES task_chains(chain_id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_task_chain_fleets_chain ON task_chain_fleets(task_chain_id);
