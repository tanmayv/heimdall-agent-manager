-- REQ-1: human-readable display_name on Agent_Instance records (defaults to "<agent-name> #<n>").
ALTER TABLE agent_instances ADD COLUMN display_name TEXT NOT NULL DEFAULT '';
