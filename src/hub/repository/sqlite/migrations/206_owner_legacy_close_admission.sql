BEGIN IMMEDIATE;
-- Selection closes the complete ordinary execution scope before any inventory.
-- Exact historical replay is resolved before admission by the repository.
DROP TRIGGER owner_legacy_effect_admission;
CREATE TRIGGER owner_legacy_effect_admission BEFORE INSERT ON owner_legacy_source_effects
WHEN NEW.state!='outstanding' OR NOT EXISTS(SELECT 1 FROM owner_legacy_source_generations g
  WHERE g.chain_id=NEW.chain_id AND g.account_id=NEW.account_id AND g.generation=NEW.generation)
  OR EXISTS(SELECT 1 FROM owner_legacy_migrations m WHERE m.chain_id=NEW.chain_id)
BEGIN SELECT RAISE(ABORT,'legacy source dispatch is fenced'); END;
INSERT INTO schema_migrations(version) VALUES('206_owner_legacy_close_admission.sql');
COMMIT;
