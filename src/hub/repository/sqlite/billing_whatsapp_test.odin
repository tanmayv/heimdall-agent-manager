package sqlite

import "core:testing"
import domain "odin_test:hub/domain"

// REQ-WAI-1: migration 223 adds billing_plans.whatsapp_enabled (0 on every plan)
// and account_entitlements.override_whatsapp_enabled (NULL/0/1); the effective
// value is the override when set, else the entitled plan's value.
@(test)
test_whatsapp_entitlement_migration_defaults_and_overrides :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, path, opened := tmpl_open_file_prod(t, "whatsapp_entitlement")
	if !opened do return
	defer tmpl_remove_db(path)
	defer close(&conn)
	before, before_err := run_migrations(&conn, "/nonexistent/billing-migrations", stop_before = "223_whatsapp_invite_only.sql")
	if !testing.expect(t, before && before_err.code == .None, before_err.message) do return
	testing.expect(t, !table_column_exists(&conn, "billing_plans", "whatsapp_enabled"))
	// Existing accounts on every kind of plan, created before the migration.
	testing.expect(t, exec(&conn, `INSERT INTO users VALUES ('alice', 'alice', 'Alice', '', 'active', '2026-10-10T10:00:00Z', '2026-10-10T10:00:00Z');
		INSERT INTO users VALUES ('bob', 'bob', 'Bob', '', 'active', '2026-10-10T10:00:00Z', '2026-10-10T10:00:00Z');
		UPDATE account_billing SET plan_id = 'hobbyist', status = 'active', subscription_id = 'sub_alice' WHERE user_id = 'alice';`))
	migrated, migration_err := run_migrations(&conn, "/nonexistent/billing-migrations")
	if !testing.expect(t, migrated && migration_err.code == .None, migration_err.message) do return
	testing.expect(t, migration_applied(&conn, "223_whatsapp_invite_only.sql"))

	impl: Billing_Repo_SQLite
	repo, err := new_billing_repository(&impl, path, "sandbox", "pri_hobbyist", true)
	if !testing.expect_value(t, err.code, domain.Error_Code.None) do return
	defer close_billing_repository(&impl)
	plans_on, _ := billing_scalar(&impl, "SELECT COUNT(*) FROM billing_plans WHERE whatsapp_enabled != 0;")
	plans_all, _ := billing_scalar(&impl, "SELECT COUNT(*) FROM billing_plans;")
	testing.expect_value(t, plans_on, "0")
	testing.expect(t, plans_all != "0")
	existing, _ := billing_scalar(&impl, "SELECT COUNT(*) || ':' || SUM(whatsapp_enabled) || ':' || COUNT(override_whatsapp_enabled) FROM account_entitlements;")
	testing.expect_value(t, existing, "2:0:0")
	plans, plans_err := repo.list_plans(repo.ctx)
	testing.expect_value(t, plans_err.code, domain.Error_Code.None)
	for plan in plans do testing.expect(t, !plan.entitlements.whatsapp_enabled, plan.plan_id)

	// Paid and free accounts alike are off by default.
	for user in ([]string{"alice", "bob"}) {
		account, get_err := repo.get_account(repo.ctx, user, "2026-10-10T10:00:00Z")
		testing.expect_value(t, get_err.code, domain.Error_Code.None)
		testing.expect(t, !account.entitlements.whatsapp_enabled, user)
	}
	// New accounts get the free plan's value from the recreated trigger.
	testing.expect(t, exec(&conn, "INSERT INTO users VALUES ('fresh', 'fresh', 'Fresh', '', 'active', '2026-10-10T10:00:00Z', '2026-10-10T10:00:00Z');"))
	fresh, _ := billing_scalar(&impl, "SELECT max_bridges || ':' || shells_enabled || ':' || whatsapp_enabled || ':' || COALESCE(override_whatsapp_enabled, 'null') FROM account_entitlements WHERE user_id = 'fresh';")
	testing.expect_value(t, fresh, "1:0:0:null")

	// An admin grant (override 1) enables WhatsApp regardless of plan.
	testing.expect(t, exec(&conn, "UPDATE account_entitlements SET override_whatsapp_enabled = 1 WHERE user_id = 'bob';"))
	granted, _ := repo.get_account(repo.ctx, "bob", "2026-10-10T10:00:00Z")
	testing.expect(t, granted.entitlements.whatsapp_enabled)
	testing.expect(t, billing_refresh_parameters(&impl, "bob", "2026-10-10T10:00:00Z"))
	snapshot, _ := billing_scalar(&impl, "SELECT whatsapp_enabled FROM account_entitlements WHERE user_id = 'bob';")
	testing.expect_value(t, snapshot, "1")

	// A plan that includes WhatsApp applies while override is NULL...
	testing.expect(t, exec(&conn, "UPDATE billing_plans SET whatsapp_enabled = 1 WHERE plan_id = 'hobbyist';"))
	plan_on, _ := repo.get_account(repo.ctx, "alice", "2026-10-10T10:00:00Z")
	testing.expect(t, plan_on.entitlements.whatsapp_enabled)
	// ...and an explicit override 0 still wins over it.
	testing.expect(t, exec(&conn, "UPDATE account_entitlements SET override_whatsapp_enabled = 0 WHERE user_id = 'alice';"))
	revoked, _ := repo.get_account(repo.ctx, "alice", "2026-10-10T10:00:00Z")
	testing.expect(t, !revoked.entitlements.whatsapp_enabled)
	testing.expect(t, billing_refresh_parameters(&impl, "alice", "2026-10-10T10:00:00Z"))
	alice_snapshot, _ := billing_scalar(&impl, "SELECT whatsapp_enabled FROM account_entitlements WHERE user_id = 'alice';")
	testing.expect_value(t, alice_snapshot, "0")
	// Clearing the override returns to the plan value.
	testing.expect(t, exec(&conn, "UPDATE account_entitlements SET override_whatsapp_enabled = NULL WHERE user_id = 'alice';"))
	cleared, _ := repo.get_account(repo.ctx, "alice", "2026-10-10T10:00:00Z")
	testing.expect(t, cleared.entitlements.whatsapp_enabled)
	// Only NULL/0/1 are accepted.
	testing.expect(t, !exec(&conn, "UPDATE account_entitlements SET override_whatsapp_enabled = 2 WHERE user_id = 'alice';"))
	testing.expect(t, !exec(&conn, "UPDATE billing_plans SET whatsapp_enabled = 2 WHERE plan_id = 'free';"))
}

// A crash between 223's COMMIT and its ledger row is recovered on restart.
@(test)
test_whatsapp_entitlement_migration_ledger_recovery :: proc(t: ^testing.T) {
	conn, opened, _ := open(":memory:")
	if !testing.expect(t, opened) do return
	defer close(&conn)
	migrated, err := run_migrations(&conn)
	if !testing.expect(t, migrated, err.message) do return
	testing.expect(t, exec(&conn, "DELETE FROM schema_migrations WHERE version = '223_whatsapp_invite_only.sql';"))
	migrated, err = run_migrations(&conn)
	testing.expect(t, migrated, err.message)
	testing.expect(t, migration_applied(&conn, "223_whatsapp_invite_only.sql"))
}
