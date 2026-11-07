BEGIN IMMEDIATE;
-- R3 review: a selected or frozen migration that cannot complete may be
-- aborted by the account owner. The fence row is deleted (every legacy guard
-- and the no-new-lease trigger then release the chain), and the migration id is
-- recorded so that the same selection can never be frozen or cut over again.
-- An imported migration can never be aborted.
CREATE TABLE owner_legacy_aborted_migrations (
  migration_id TEXT PRIMARY KEY,
  chain_id TEXT NOT NULL,
  account_id TEXT NOT NULL,
  owner_bridge_id TEXT NOT NULL,
  selection_digest TEXT NOT NULL
);
CREATE INDEX owner_legacy_aborted_chain ON owner_legacy_aborted_migrations(chain_id);
CREATE TRIGGER owner_legacy_aborted_immutable BEFORE UPDATE ON owner_legacy_aborted_migrations
BEGIN SELECT RAISE(ABORT,'aborted migration record is permanent'); END;
CREATE TRIGGER owner_legacy_aborted_no_delete BEFORE DELETE ON owner_legacy_aborted_migrations
BEGIN SELECT RAISE(ABORT,'aborted migration record is permanent'); END;
DROP TRIGGER owner_legacy_migration_no_delete;
CREATE TRIGGER owner_legacy_migration_no_delete BEFORE DELETE ON owner_legacy_migrations
WHEN OLD.state='imported' OR NOT EXISTS(SELECT 1 FROM owner_legacy_aborted_migrations a
  WHERE a.migration_id=OLD.migration_id AND a.chain_id=OLD.chain_id AND a.account_id=OLD.account_id)
BEGIN SELECT RAISE(ABORT,'legacy migration fence is permanent'); END;
CREATE TRIGGER owner_legacy_aborted_never_reselected BEFORE INSERT ON owner_legacy_migrations
WHEN EXISTS(SELECT 1 FROM owner_legacy_aborted_migrations a WHERE a.migration_id=NEW.migration_id)
BEGIN SELECT RAISE(ABORT,'aborted migration cannot be selected again'); END;
INSERT INTO schema_migrations(version) VALUES('208_owner_legacy_migration_abort.sql');
COMMIT;
