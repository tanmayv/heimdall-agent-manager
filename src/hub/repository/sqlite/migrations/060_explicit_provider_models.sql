-- REQ-PROVIDER-CATALOG-3/4: literal model ids replace tiers and launch choices
-- live only on concrete instances/fleet requests. Catalog and bridge status own
-- provider availability; bridge/agent defaults are intentionally removed.
ALTER TABLE agent_instances RENAME COLUMN tier TO model;
ALTER TABLE agent_instances ADD COLUMN kind TEXT NOT NULL DEFAULT 'agent';

ALTER TABLE actions RENAME COLUMN target_tier TO target_model;

ALTER TABLE agents DROP COLUMN default_provider;
ALTER TABLE agents DROP COLUMN default_tier;
ALTER TABLE agent_bridge_support DROP COLUMN provider;
ALTER TABLE agent_bridge_support DROP COLUMN tier;
