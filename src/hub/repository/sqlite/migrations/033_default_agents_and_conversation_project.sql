-- Migration 033: Seed canonical coordinator/worker/reviewer agents and conversation project.
--
-- 1. Updates existing coordinator agents off 'tmpl_empty' onto 'tmpl_coordinator'.
-- 2. Seeds the 3 canonical durable agents (coordinator, worker, reviewer) for all existing users.
-- 3. Prunes stale non-canonical auto-seeded agents.
-- 4. Seeds a dedicated 'Conversation' project for all existing users with guidance instructions.
--
-- Idempotent:
--   - NOT EXISTS checks keyed on (owner_user_id, slug).
--   - Deterministic IDs ('agt_<role>_' || user_id, 'proj_conversation_' || user_id).
--   - Safe to execute repeatedly without duplicating rows or mutating user customizations.

-- Update existing coordinator agents from tmpl_empty to tmpl_coordinator
UPDATE agents
SET template_id = 'tmpl_coordinator'
WHERE slug = 'coordinator' AND template_id = 'tmpl_empty';

-- Seed coordinator agent for every user lacking one
INSERT INTO agents (agent_id, owner_user_id, name, slug, template_id, default_provider, default_tier, instructions, state, created_at, updated_at)
SELECT 'agt_coordinator_' || u.user_id,
       u.user_id,
       'coordinator',
       'coordinator',
       'tmpl_coordinator',
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

-- Seed worker agent for every user lacking one
INSERT INTO agents (agent_id, owner_user_id, name, slug, template_id, default_provider, default_tier, instructions, state, created_at, updated_at)
SELECT 'agt_worker_' || u.user_id,
       u.user_id,
       'worker',
       'worker',
       'tmpl_worker',
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
      AND a.slug = 'worker'
);

-- Seed reviewer agent for every user lacking one
INSERT INTO agents (agent_id, owner_user_id, name, slug, template_id, default_provider, default_tier, instructions, state, created_at, updated_at)
SELECT 'agt_reviewer_' || u.user_id,
       u.user_id,
       'reviewer',
       'reviewer',
       'tmpl_reviewer',
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
      AND a.slug = 'reviewer'
);

-- Prune any stale auto-seeded agents that are not among the 3 canonical identities
DELETE FROM agents
WHERE (owner_user_id = 'system' OR agent_id LIKE 'agt_system_%')
  AND slug NOT IN ('coordinator', 'worker', 'reviewer');

-- Seed dedicated Conversation project for every user lacking one
INSERT INTO projects (project_id, owner_user_id, name, slug, description, repo_url, vcs_kind, default_path, created_at, updated_at)
SELECT 'proj_conversation_' || u.user_id,
       u.user_id,
       'Conversation',
       'conversation',
       'Dedicated environment for open-ended conversation, brainstorming, and ad-hoc reasoning.

- Purpose: Dedicated environment for open-ended conversation and brainstorming.
- Project Transition: If user queries or goals involve a specific software project, repository, or multi-step engineering task, proactively recommend creating or switching to a dedicated project and launching a coordinator agent to orchestrate the work.
- User Primacy: All recommendations require explicit user approval; user requests always trump best practices.',
       '',
       '',
       '',
       u.created_at,
       u.updated_at
FROM users u
WHERE NOT EXISTS (
    SELECT 1 FROM projects p
    WHERE p.owner_user_id = u.user_id
      AND p.slug = 'conversation'
);
