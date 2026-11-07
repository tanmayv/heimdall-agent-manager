BEGIN IMMEDIATE;
-- Existing hashes cannot recover a historical command/effect association.
-- Empty prior command IDs remain explicitly unknown; never infer/backfill.
ALTER TABLE owner_legacy_source_effects ADD COLUMN command_id TEXT NOT NULL DEFAULT '';
CREATE TRIGGER owner_legacy_effect_command_admission BEFORE INSERT ON owner_legacy_source_effects
WHEN length(NEW.command_id)=0 OR length(NEW.command_id)>160
BEGIN SELECT RAISE(ABORT,'legacy effect requires explicit original command identity'); END;
CREATE TRIGGER owner_legacy_effect_command_immutable BEFORE UPDATE ON owner_legacy_source_effects
WHEN NEW.command_id IS NOT OLD.command_id
BEGIN SELECT RAISE(ABORT,'legacy command association is immutable'); END;
INSERT INTO schema_migrations(version) VALUES('205_owner_legacy_effect_identity.sql');
COMMIT;
