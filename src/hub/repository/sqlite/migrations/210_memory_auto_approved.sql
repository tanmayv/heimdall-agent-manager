-- F1: audit for agent memory proposals that the owner's
-- auto_approve_agent_memories setting approved without a human review.
-- '' for memories approved by a person or created before this migration.
ALTER TABLE memories ADD COLUMN auto_approved_at TEXT NOT NULL DEFAULT '';
