-- Convert memory targeting from single scalar scope columns
-- (agent_id/project_id/template_id/bridge_id) to JSON-array list columns
-- (agent_ids/project_ids/template_ids/bridge_ids). An empty list ('[]') means
-- "applies to all" for that dimension; a non-empty list means the value must be
-- a member. Backfill each list from its prior scalar (empty -> '[]', non-empty
-- -> a single-element array), then drop the scalar columns.
ALTER TABLE memories ADD COLUMN agent_ids TEXT NOT NULL DEFAULT '[]';
ALTER TABLE memories ADD COLUMN project_ids TEXT NOT NULL DEFAULT '[]';
ALTER TABLE memories ADD COLUMN template_ids TEXT NOT NULL DEFAULT '[]';
ALTER TABLE memories ADD COLUMN bridge_ids TEXT NOT NULL DEFAULT '[]';
UPDATE memories SET
  agent_ids = CASE WHEN agent_id = '' THEN '[]' ELSE '["' || agent_id || '"]' END,
  project_ids = CASE WHEN project_id = '' THEN '[]' ELSE '["' || project_id || '"]' END,
  template_ids = CASE WHEN template_id = '' THEN '[]' ELSE '["' || template_id || '"]' END,
  bridge_ids = CASE WHEN bridge_id = '' THEN '[]' ELSE '["' || bridge_id || '"]' END;
ALTER TABLE memories DROP COLUMN agent_id;
ALTER TABLE memories DROP COLUMN project_id;
ALTER TABLE memories DROP COLUMN template_id;
ALTER TABLE memories DROP COLUMN bridge_id;
