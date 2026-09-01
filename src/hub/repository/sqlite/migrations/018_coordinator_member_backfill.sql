-- H9: task_chain_members (role='coordinator') is now the SINGLE canonical source
-- of who coordinates a chain. Historically the coordinator lived in the
-- task_chains.coordinator_agent_instance_id column; some chains have that column
-- set but NO matching coordinator member row (the dual-source drift that locked a
-- real coordinator out). Backfill a coordinator member for every such chain so no
-- chain loses its coordinator when the members table becomes authoritative.
--
-- Idempotent: INSERT OR IGNORE keys on the (chain_id, agent_instance_id) primary
-- key, and the NOT EXISTS guard skips chains that already have a coordinator
-- member. Re-running is a no-op.
INSERT OR IGNORE INTO task_chain_members (chain_id, agent_instance_id, agent_id, owner_user_id, role, created_at)
SELECT c.chain_id,
       c.coordinator_agent_instance_id,
       '',
       c.owner_user_id,
       'coordinator',
       c.created_at
FROM task_chains c
WHERE c.coordinator_agent_instance_id IS NOT NULL
  AND c.coordinator_agent_instance_id <> ''
  AND NOT EXISTS (
        SELECT 1 FROM task_chain_members m
        WHERE m.chain_id = c.chain_id
          AND m.role = 'coordinator'
  );
