#+private file
package sqlite

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

FMI_SETTINGS :: "253_shared_fleet_settings.sql"
FMI_APPLICATIONS :: "254_fleet_applications.sql"
FMI_REMOTE :: [3]string{"webhooks_002_dedupe_header.sql", "251_opencode_acp_provider.sql", "252_extension_version_sync_0_5_88.sql"}

fmi_text :: proc(conn: ^Conn, query: string) -> string {
	stmt: sqlite3_stmt
	if sqlite3_prepare_v2(conn.db, strings.clone_to_cstring(query, context.temp_allocator), -1, &stmt, nil) != SQLITE_OK do return ""
	defer sqlite3_finalize(stmt)
	if sqlite3_step(stmt) != SQLITE_ROW do return ""
	return strings.clone(column_text_unowned(stmt, 0), context.temp_allocator)
}

fmi_ledger :: proc(conn: ^Conn) -> string {
	return fmi_text(conn, "SELECT group_concat(entry, '|') FROM (SELECT version || ':' || applied_at AS entry FROM schema_migrations ORDER BY version);")
}

@(test)
test_fleet_integration_migration_registry_matches_disk_and_embedded_tail :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := strings.concatenate({#directory, "/migrations"})
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if !testing.expect(t, err == nil, "read migration directory") do return
	registered := make(map[string]bool)
	for name in migration_order {
		testing.expectf(t, !registered[name], "%s registered exactly once", name)
		registered[name] = true
		_, read_err := os.read_entire_file(strings.concatenate({dir, "/", name}), context.temp_allocator)
		testing.expectf(t, read_err == nil, "%s has a disk source", name)
	}
	disk_count := 0
	for entry in entries {
		if !strings.has_suffix(entry.name, ".sql") do continue
		disk_count += 1
		testing.expectf(t, registered[entry.name], "%s is registered", entry.name)
	}
	testing.expect_value(t, disk_count, len(migration_order))
	for name in ([5]string{FMI_REMOTE[0], FMI_REMOTE[1], FMI_REMOTE[2], FMI_SETTINGS, FMI_APPLICATIONS}) {
		disk, read_err := os.read_entire_file(strings.concatenate({dir, "/", name}), context.temp_allocator)
		if !testing.expectf(t, read_err == nil, "read %s", name) do continue
		embedded := migration_sql(name, "")
		testing.expectf(t, len(embedded) > 0 && embedded == string(disk), "%s embeds the exact SQL file bytes", name)
	}
	order := migration_order
	tail := order[len(order)-4:]
	for name, i in ([4]string{FMI_REMOTE[1], FMI_REMOTE[2], FMI_SETTINGS, FMI_APPLICATIONS}) {
		testing.expect_value(t, tail[i], name)
	}
	testing.expect(t, !registered["251_shared_fleet_settings.sql"] && !registered["252_fleet_applications.sql"], "unpublished conflicting identities are absent")
}

fmi_expect_schema :: proc(t: ^testing.T, conn: ^Conn) {
	for name in migration_order {
		testing.expect_value(t, fmi_text(conn, fmt.tprintf("SELECT count(*) FROM schema_migrations WHERE version='%s';", name)), "1")
	}
	testing.expect(t, table_column_exists(conn, "event_webhooks", "dedupe_header"))
	testing.expect_value(t, fmi_text(conn, "SELECT transports || ':' || default_transport FROM provider_catalog WHERE provider='opencode';"), `["acp"]:acp`)
	for provider in ([3]string{"antigravity", "claude", "codex"}) {
		testing.expect_value(t, fmi_text(conn, fmt.tprintf("SELECT json_extract(extension,'$.min_version') FROM provider_catalog WHERE provider='%s';", provider)), "0.5.88")
	}
	for name in ([7]string{"bridge_fleet_settings", "bridge_fleet_agent_overrides", "instance_fleet_scope", "bridge_fleet_applications", "fleet_override_agent_delete_revision", "fleet_applications_active", "idx_fleet_actions_instance"}) {
		testing.expectf(t, sqlite_object_exists(conn, name), "%s installed", name)
	}
	testing.expect_value(t, fmi_text(conn, "SELECT count(*) FROM schema_migrations WHERE version IN ('251_shared_fleet_settings.sql','252_fleet_applications.sql');"), "0")
	testing.expect_value(t, fmi_text(conn, "PRAGMA integrity_check;"), "ok")
}

// Both histories are real file databases reopened before each repeat startup.
// The upgrade boundary is exactly the published remote tip, before either Fleet migration.
fmi_upgrade :: proc(t: ^testing.T, from_remote: bool) {
	context.allocator = context.temp_allocator
	conn, path, opened := tmpl_open_file_prod(t, "fleet_main_integration")
	defer tmpl_remove_db(path)
	if !opened do return
	defer close(&conn)
	if from_remote {
		ok, err := run_migrations(&conn, stop_before = FMI_SETTINGS)
		if !testing.expect(t, ok, err.message) do return
		for name in FMI_REMOTE do testing.expect(t, migration_applied(&conn, name))
		testing.expect(t, !sqlite_object_exists(&conn, "bridge_fleet_settings") && !sqlite_object_exists(&conn, "bridge_fleet_applications"))
		if !testing.expect(t, exec(&conn, `
			UPDATE schema_migrations SET applied_at='remote-original';
			INSERT INTO event_webhooks(webhook_id,owner_user_id,token_hash,created_at,updated_at,dedupe_header)
			VALUES('existing-webhook','owner','original-hash','then','then','Svix-Id');
			UPDATE provider_catalog SET display_name='Operator OpenCode' WHERE provider='opencode';
		`)) {
			return
		}
	}
	remote_ledger := fmi_ledger(&conn)
	ok, err := run_migrations(&conn, migrations_dir = "")
	if !testing.expect(t, ok, err.message) do return
	fmi_expect_schema(t, &conn)
	if from_remote {
		testing.expect_value(t, fmi_text(&conn, "SELECT group_concat(entry, '|') FROM (SELECT version || ':' || applied_at AS entry FROM schema_migrations WHERE applied_at='remote-original' ORDER BY version);"), remote_ledger)
	}
	// Persist settings, an override, scope and an in-flight application, then prove
	// startup preserves them instead of recreating an empty Fleet configuration.
	if !testing.expect(t, exec(&conn, `
		INSERT INTO users(user_id,name,display_name,status,created_at,updated_at) VALUES('owner','Owner','Owner','active','then','then');
		INSERT INTO bridges(bridge_id,owner_user_id,created_at,updated_at) VALUES('bridge','owner','then','then');
		INSERT INTO agents(agent_id,owner_user_id,name,slug,created_at,updated_at) VALUES('agent','owner','Agent','agent','then','then');
		INSERT INTO agent_instances(agent_instance_id,owner_user_id,agent_id,bridge_id,runtime_status,created_at,updated_at) VALUES('instance','owner','agent','bridge','stopped','then','then');
		INSERT INTO bridge_fleet_settings VALUES('bridge','owner',2,'codex','profile','model');
		INSERT INTO bridge_fleet_agent_overrides VALUES('bridge','agent','claude','override-profile','override-model');
		INSERT INTO instance_fleet_scope VALUES('instance','chain');
		INSERT INTO bridge_fleet_applications(application_id,bridge_id,owner_user_id,request_id,request_json,authority_json,revision,state,application_json)
		VALUES('application','bridge','owner','request','{"draft":"original"}','{"authority":"original"}',2,'restarting','{"sentinel":"original"}');
	`)) {
		return
	}
	ledger := fmi_ledger(&conn)
	for _ in 0..<2 {
		close(&conn)
		conn, opened, _ = open(path)
		if !testing.expect(t, opened, "reopen integrated database") do return
		ok, err = run_migrations(&conn)
		if !testing.expect(t, ok, err.message) do return
		fmi_expect_schema(t, &conn)
		testing.expect_value(t, fmi_ledger(&conn), ledger)
		testing.expect_value(t, fmi_text(&conn, "SELECT revision || ':' || provider_profile || ':' || model FROM bridge_fleet_settings WHERE bridge_id='bridge';"), "2:profile:model")
		testing.expect_value(t, fmi_text(&conn, "SELECT provider || ':' || provider_profile || ':' || model FROM bridge_fleet_agent_overrides WHERE agent_id='agent';"), "claude:override-profile:override-model")
		testing.expect_value(t, fmi_text(&conn, "SELECT scope FROM instance_fleet_scope WHERE agent_instance_id='instance';"), "chain")
		testing.expect_value(t, fmi_text(&conn, "SELECT request_json || ':' || authority_json || ':' || revision || ':' || state || ':' || application_json FROM bridge_fleet_applications WHERE application_id='application';"), `{"draft":"original"}:{"authority":"original"}:2:restarting:{"sentinel":"original"}`)
		if from_remote {
			testing.expect_value(t, fmi_text(&conn, "SELECT token_hash || ':' || dedupe_header FROM event_webhooks WHERE webhook_id='existing-webhook';"), "original-hash:Svix-Id")
			testing.expect_value(t, fmi_text(&conn, "SELECT display_name FROM provider_catalog WHERE provider='opencode';"), "Operator OpenCode")
		}
		testing.expect_value(t, fmi_text(&conn, "PRAGMA foreign_key_check;"), "")
	}
}

@(test)
test_fleet_integration_fresh_bootstrap_and_restart :: proc(t: ^testing.T) {
	fmi_upgrade(t, false)
}

@(test)
test_fleet_integration_upgrade_from_remote_0_5_88_and_restart :: proc(t: ^testing.T) {
	fmi_upgrade(t, true)
}
