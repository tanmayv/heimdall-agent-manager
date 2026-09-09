-- First-time users must always have a durable agent to start. This migration
-- (a) seeds a 'coordinator' agent for every existing user that has none, and
-- (b) remaps agents that referenced the removed built-in 'System Reviewer'
-- template ('tmpl_system_reviewer') onto the new default 'tmpl_empty' template.
--
-- Idempotent:
--   (a) the NOT EXISTS guard skips users that already have a 'coordinator' agent,
--       and the deterministic agent_id ('agt_coordinator_' || user_id) keeps the
--       insert stable across re-runs;
--   (b) the WHERE clause matches only the stale template id, so re-running after
--       the remap is a no-op. The coordinator agent inherits the user's own
--       created_at/updated_at so timestamps stay deterministic.
INSERT INTO agents (agent_id, owner_user_id, name, slug, template_id, default_provider, default_tier, instructions, state, created_at, updated_at)
SELECT 'agt_coordinator_' || u.user_id,
       u.user_id,
       'coordinator',
       'coordinator',
       'tmpl_empty',
       '',
       '',
       '',
       'active',
       u.created_at,
       u.updated_at
FROM users u
WHERE NOT EXISTS (
        SELECT 1 FROM agents a
        WHERE a.owner_user_id = u.user_id
          AND a.slug = 'coordinator'
);

UPDATE agents SET template_id = 'tmpl_empty' WHERE template_id = 'tmpl_system_reviewer';
