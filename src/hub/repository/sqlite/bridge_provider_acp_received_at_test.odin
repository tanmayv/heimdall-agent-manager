package sqlite

import "core:testing"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// R2 item 3: the Hub records when it stored each ACP report (its own clock),
// so staleness never depends on the bridge-reported checked_at.
@(test)
test_bridge_provider_acp_received_at_migration_and_upsert :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, opened, _ := open(":memory:")
	if !testing.expect(t, opened) do return
	defer close(&conn)
	migrated, err := run_migrations(&conn, stop_before = "268_bridge_provider_acp_received_at.sql")
	if !testing.expect(t, migrated, err.message) do return
	testing.expect(t, !table_column_exists(&conn, "bridge_provider_status", "acp_adapter_received_at"))
	testing.expect(t, exec(&conn, "INSERT INTO bridge_provider_status(bridge_id,provider,profile_id,state,checked_at,acp_adapter) VALUES('b','claude','claude','present','','{\"state\":\"ready\",\"checked_at\":\"2026-11-01T00:00:00Z\"}');"))
	migrated, err = run_migrations(&conn)
	if !testing.expect(t, migrated, err.message) do return
	migrated, err = run_migrations(&conn) // ledger + completion guard
	testing.expect(t, migrated, err.message)
	embedded := migration_sql("268_bridge_provider_acp_received_at.sql", "")
	disk := migration_sql("268_bridge_provider_acp_received_at.sql", "src/hub/repository/sqlite/migrations")
	testing.expect_value(t, embedded, disk)

	impl: Provider_Repo_SQLite
	repo := new_provider_repository(&impl, &conn)
	received := proc(t: ^testing.T, repo: ^iface.Provider_Repository, profile: string) -> string {
		items, err := iface.bridge_provider_status_list(repo, "b")
		testing.expect_value(t, err.code, domain.Error_Code.None)
		for item in items do if item.profile_id == profile do return item.acp_adapter_received_at
		return "<none>"
	}
	testing.expect_value(t, received(t, &repo, "claude"), "") // stored before the column: stale once

	before := time.now()
	fresh := proc(t: ^testing.T, value: string, before: time.Time) {
		at, consumed := time.rfc3339_to_time_utc(value)
		testing.expectf(t, consumed > 0 && time.diff(time.time_add(before, -2 * time.Second), at) >= 0 && time.diff(at, time.now()) >= -time.Second, "Hub clock at upsert: %q", value)
	}
	adapter := proc(repo: ^iface.Provider_Repository) -> string {
		items, _ := iface.bridge_provider_status_list(repo, "b")
		for item in items do if item.profile_id == "claude" do return item.acp_adapter_json
		return ""
	}
	// A report whose body is rejected (older checked_at) still counts as heard
	// from: the receipt moves, the stored body does not.
	ok, upsert_err := iface.bridge_provider_status_upsert(&repo, {bridge_id = "b", provider = "claude", profile_id = "claude", state = "present",
		acp_adapter_json = `{"state":"missing","checked_at":"2020-01-01T00:00:00Z"}`})
	testing.expect(t, ok && upsert_err.code == .None)
	fresh(t, received(t, &repo, "claude"), before)
	testing.expect_value(t, adapter(&repo), `{"state":"ready","checked_at":"2026-11-01T00:00:00Z"}`)
	// So does a report with no ACP body or no checked_at.
	exec(&conn, "UPDATE bridge_provider_status SET acp_adapter_received_at='2020-01-01T00:00:00Z';")
	ok, upsert_err = iface.bridge_provider_status_upsert(&repo, {bridge_id = "b", provider = "claude", profile_id = "claude", state = "present"})
	testing.expect(t, ok && upsert_err.code == .None)
	fresh(t, received(t, &repo, "claude"), before)
	exec(&conn, "UPDATE bridge_provider_status SET acp_adapter_received_at='2020-01-01T00:00:00Z';")
	ok, upsert_err = iface.bridge_provider_status_upsert(&repo, {bridge_id = "b", provider = "claude", profile_id = "claude", state = "present", acp_adapter_json = `{"state":"ready"}`})
	testing.expect(t, ok && upsert_err.code == .None)
	fresh(t, received(t, &repo, "claude"), before)
	ok, upsert_err = iface.bridge_provider_status_upsert(&repo, {bridge_id = "b", provider = "claude", profile_id = "claude", state = "present",
		acp_adapter_json = `{"state":"ready","checked_at":"2026-11-02T00:00:00Z"}`})
	testing.expect(t, ok && upsert_err.code == .None)
	fresh(t, received(t, &repo, "claude"), before)
	testing.expect_value(t, adapter(&repo), `{"state":"ready","checked_at":"2026-11-02T00:00:00Z"}`)
	// A profile-only report never carries an ACP receipt.
	ok, upsert_err = iface.bridge_provider_status_upsert(&repo, {bridge_id = "b", provider = "claude", profile_id = "work", state = "present",
		acp_adapter_json = `{"state":"ready","checked_at":"2026-11-03T00:00:00Z"}`})
	testing.expect(t, ok && upsert_err.code == .None)
	testing.expect_value(t, received(t, &repo, "work"), "")
}
