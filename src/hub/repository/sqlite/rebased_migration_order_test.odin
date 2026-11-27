#+private file
// Migrations 104 (chat FTS update guard) and 105 (full-scan indexes) were renumbered
// to follow main's 103_plan_enforcement.sql. These tests pin that order: a database
// stopped at main's latest migration upgrades through both, a fresh database applies
// every migration, with strictly increasing prefixes after 102. Extension migrations follow
// the deployed main identities 104/105 without renumbering either.
package sqlite

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"

RMO_MAIN_TIP :: "103_plan_enforcement.sql"
RMO_GUARD :: "104_guard_chat_fts_updates.sql"
RMO_INDEXES :: "105_full_scan_indexes.sql"
RMO_INDEX_NAMES :: [3]string{"idx_shell_sessions_kind_started", "idx_shell_sessions_retention", "idx_task_dependencies_chain"}
RMO_OWNER :: "rmo-owner"
RMO_NOW :: "2026-10-22T00:00:00Z"

rmo_text :: proc(conn: ^Conn, query: string) -> string {
	stmt: sqlite3_stmt = nil
	if sqlite3_prepare_v2(conn.db, strings.clone_to_cstring(query, context.temp_allocator), -1, &stmt, nil) != SQLITE_OK do return ""
	defer sqlite3_finalize(stmt)
	if sqlite3_step(stmt) != SQLITE_ROW do return ""
	return strings.clone(column_text_unowned(stmt, 0), context.temp_allocator)
}

// 104 replaces both chat FTS update triggers with versions that skip unchanged text.
rmo_guarded :: proc(conn: ^Conn) -> bool {
	conv := rmo_text(conn, "SELECT sql FROM sqlite_master WHERE type='trigger' AND name='chat_conversations_fts_au';")
	msgs := rmo_text(conn, "SELECT sql FROM sqlite_master WHERE type='trigger' AND name='chat_messages_fts_au';")
	return strings.contains(conv, "old.title IS NOT new.title") && strings.contains(msgs, "old.body IS NOT new.body")
}

rmo_expect_after :: proc(t: ^testing.T, conn: ^Conn, why: string) {
	testing.expectf(t, migration_applied(conn, RMO_MAIN_TIP), "%s: %s applied", why, RMO_MAIN_TIP)
	testing.expectf(t, migration_applied(conn, RMO_GUARD), "%s: %s applied", why, RMO_GUARD)
	testing.expectf(t, migration_applied(conn, RMO_INDEXES), "%s: %s applied", why, RMO_INDEXES)
	testing.expectf(t, table_column_exists(conn, "bridges", "plan_disabled_at"), "%s: main's plan column present", why)
	testing.expectf(t, rmo_guarded(conn), "%s: chat FTS update triggers are guarded", why)
	for name in RMO_INDEX_NAMES {
		testing.expectf(t, sqlite_object_exists(conn, name), "%s: index %s present", why, name)
	}
	ledger := rmo_text(conn, "SELECT count(*) FROM schema_migrations;")
	count, count_ok := strconv.parse_int(ledger)
	testing.expectf(t, count_ok && count == len(migration_order) + int(migration_applied(conn, "113_oidc_identities.sql")) + int(migration_applied(conn, "115_oidc_identities.sql")), "%s: ledger holds every migration (got %s, want %d)", why, ledger, len(migration_order))
}

@(test)
test_rebased_upgrade_from_main_tip_applies_104_and_105 :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, path, ok := tmpl_open_file_prod(t, "rmo_upgrade")
	defer tmpl_remove_db(path)
	if !ok do return
	defer close(&conn)
	mig_ok, _ := run_migrations(&conn, stop_before = RMO_GUARD)
	if !testing.expect(t, mig_ok, "migrate to main's tip") do return
	testing.expect(t, fts5_available(&conn), "test build has FTS5, so 104 really runs")
	testing.expect(t, migration_applied(&conn, RMO_MAIN_TIP), "main's tip applied")
	testing.expect(t, !migration_applied(&conn, RMO_GUARD) && !migration_applied(&conn, RMO_INDEXES), "ours not yet applied")
	testing.expect(t, !rmo_guarded(&conn), "main's tip has the unguarded triggers")
	for name in RMO_INDEX_NAMES do testing.expectf(t, !sqlite_object_exists(&conn, name), "%s absent at main's tip", name)

	user_impl: User_Repo_SQLite
	_ = new_user_repository(&user_impl, &conn)
	_, user_ok, _ := user_save_sqlite(&user_impl, domain.User{user_id = RMO_OWNER, name = RMO_OWNER, status = .Active, created_at = RMO_NOW, updated_at = RMO_NOW})
	if !testing.expect(t, user_ok, "seed user") do return
	shell_impl: Shell_Session_Repo_SQLite
	_ = new_shell_session_repository(&shell_impl, &conn)
	saved, _ := shell_session_upsert_sqlite(&shell_impl, domain.Shell_Session{session_id = "sh_rmo", owner_user_id = RMO_OWNER,
		bridge_id = "bridge_rmo", kind = "server", status = "running", cmd = "true", started_at = RMO_NOW, created_at = RMO_NOW})
	if !testing.expect(t, saved, "seed shell row") do return

	mig_ok, _ = run_migrations(&conn)
	if !testing.expect(t, mig_ok, "upgrade through 104 and 105") do return
	rmo_expect_after(t, &conn, "upgrade")
	row, found, _ := shell_session_get_sqlite(&shell_impl, RMO_OWNER, "sh_rmo")
	testing.expect(t, found && row.status == "running", "existing row survives the upgrade")
	mig_ok, _ = run_migrations(&conn)
	testing.expect(t, mig_ok, "second run is a no-op")
}

@(test)
test_rebased_fresh_database_applies_every_migration :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, path, ok := tmpl_open_file_prod(t, "rmo_fresh")
	defer tmpl_remove_db(path)
	if !ok do return
	defer close(&conn)
	mig_ok, _ := run_migrations(&conn)
	if !testing.expect(t, mig_ok, "fresh migrate") do return
	for name in migration_order do testing.expectf(t, migration_applied(&conn, name), "fresh database records %s", name)
	rmo_expect_after(t, &conn, "fresh")
}

// Older numbers (043, 044, 048, 072) were shared before this rule; anything after
// 102 must be unique and in ascending order within its migration namespace.
@(test)
test_rebased_migration_numbers_after_102_are_unique :: proc(t: ^testing.T) {
	order := migration_order
	// The historical extension sequence stays fixed; future release bumps append
	// new migrations after it.
	start := 0
	for name, i in order {
		if name == "102_drop_bridge_enrollments.sql" { start = i; break }
	}
	tail := order[start:]
	expected := [14]string{"102_drop_bridge_enrollments.sql", RMO_MAIN_TIP, RMO_GUARD, RMO_INDEXES,
		"106_agent_extension_events.sql", "107_provider_extension.sql", "108_agent_permission_mode.sql",
		"109_instance_permission_mode.sql", "110_provider_ask_args.sql",
		"111_extension_startup_loading.sql", "112_codex_extension.sql", "113_antigravity_extension.sql",
		"114_extension_version_sync.sql", "115_provider_extension_commands.sql"}
	for name, i in expected do testing.expect_value(t, tail[i], name)
	prev, events_prev := 0, 0
	for name in order {
		if name == "pipeline_001_deliveries.sql" || name == "pipeline_002_read_ack.sql" || name == "acp_delivery_001_input_deliveries.sql" do continue
		if name == "webhooks_002_dedupe_header.sql" || name == "webhooks_001.sql" || name == "actions_011_prompt_expiry.sql" || name == "events_009_incremental_inbox.sql" || name == "actions_010_agent_automation_audit.sql" || name == "actions_007_filter_tree.sql" || name == "events_008_state_heads.sql" || name == "actions_009_batch_history.sql" || name == "actions_008_target_batches.sql" || name == "events_007_entity_versions.sql" || name == "actions_006_template_vars.sql" || name == "actions_001_reset.sql" || name == "actions_002_lookup_indexes.sql" || name == "actions_003_history_performance.sql" || name == "actions_004_bot_activity.sql" || name == "actions_005_settle.sql" || name == "agents_001_start_ref.sql" || name == "native_001_oidc_identities.sql" || name == "whatsapp_001_invite_only.sql" || name == "bots_web_001_channel.sql" || name == "bots_web_002_attachments.sql" || name == "bots_web_003_action_refs.sql" || name == "coordinator_idle_001_user_activity.sql" || name == "coordinator_idle_002_stop_reason.sql" do continue
		if strings.has_prefix(name, "events_") {
			if !testing.expectf(t, len(name) > 10, "%s has an events sequence", name) do continue
			n, n_ok := strconv.parse_int(name[7:10])
			testing.expectf(t, n_ok && n > events_prev && name[10] == '_', "%s follows events sequence %d", name, events_prev)
			events_prev = n
			continue
		}
		n, n_ok := strconv.parse_int(name[:3])
		if !testing.expectf(t, n_ok, "%s has a numeric prefix", name) do continue
		if n > 102 do testing.expectf(t, n > prev, "%s must be numbered after %d", name, prev)
		prev = max(prev, n)
	}
}


@(test)
test_extension_upgrade_from_deployed_main_keeps_migration_identities :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, path, ok := tmpl_open_file_prod(t, "rmo_extension_upgrade")
	defer tmpl_remove_db(path)
	if !ok do return
	defer close(&conn)
	mig_ok, _ := run_migrations(&conn, stop_before = "106_agent_extension_events.sql")
	if !testing.expect(t, mig_ok, "migrate through deployed main 105") do return
	testing.expect(t, migration_applied(&conn, RMO_GUARD) && migration_applied(&conn, RMO_INDEXES), "main migration identities recorded")
	testing.expect(t, rmo_guarded(&conn), "main FTS guard is installed")
	testing.expect(t, !table_column_exists(&conn, "agent_instances", "provider_session_id"), "extension not installed yet")
	testing.expect_value(t, rmo_text(&conn, "SELECT count(*) FROM schema_migrations;"), "108")
	main_applied_at := rmo_text(&conn, "SELECT applied_at FROM schema_migrations WHERE version='105_full_scan_indexes.sql';")
	mig_ok, _ = run_migrations(&conn)
	if !testing.expect(t, mig_ok, "upgrade through extension migrations") do return
	rmo_expect_after(t, &conn, "extension upgrade")
	testing.expect_value(t, rmo_text(&conn, "SELECT applied_at FROM schema_migrations WHERE version='105_full_scan_indexes.sql';"), main_applied_at)
	testing.expect(t, !sqlite_object_exists(&conn, "agent_extension_events_instance_agent"), "transient migration retires extension event log")
	testing.expect(t, table_column_exists(&conn, "provider_catalog", "extension"), "provider extension descriptor exists")
	testing.expect(t, table_column_exists(&conn, "agents", "permission_mode"), "agent permission override exists")
	testing.expect(t, table_column_exists(&conn, "agent_instances", "permission_mode"), "instance permission override exists")
	testing.expect(t, sqlite_trigger_mentions(&conn, "instance_reconfiguration_commit", "permission_mode"), "commit applies instance permission mode")
	testing.expect(t, table_column_exists(&conn, "provider_catalog", "ask_args"), "ask arguments exist")
	mig_ok, _ = run_migrations(&conn)
	testing.expect(t, mig_ok, "extension upgrade is idempotent")
}

// Both deployed histories must converge without renaming any ledger identity.
rmo_bots_upgrade :: proc(t: ^testing.T, staging: bool) {
	context.allocator = context.temp_allocator
	conn, path, ok := tmpl_open_file_prod(t, "rmo_bots_upgrade")
	defer tmpl_remove_db(path)
	if !ok do return
	defer close(&conn)
	main_sync :: "209_extension_version_sync_0_5_55.sql"
	mig_ok, _ := run_migrations(&conn, stop_before = main_sync)
	if !testing.expect(t, mig_ok, "migrate shared history") do return
	first := main_sync
	if staging do first = "209_bots.sql"
	sql_name := first
	if staging do sql_name = "213_bots.sql"
	sql := migration_sql(sql_name, "")
	defer delete(sql)
	if !testing.expect(t, exec(&conn, sql), "apply deployed branch migration") do return
	if !testing.expect(t, exec(&conn, strings.concatenate({"INSERT INTO schema_migrations(version) VALUES ('", first, "');"}, context.temp_allocator)), "record deployed identity") do return
	testing.expect_value(t, migration_applied(&conn, "209_bots.sql"), staging)
	testing.expect_value(t, migration_applied(&conn, main_sync), !staging)
	testing.expect(t, !migration_applied(&conn, "214_agent_writes.sql") && !migration_applied(&conn, "215_bots_whatsapp.sql"), "later bots migrations absent")
	mig_ok, _ = run_migrations(&conn)
	if !testing.expect(t, mig_ok, "upgrade deployed history") do return
	for name in ([5]string{main_sync, "213_bots.sql", "214_agent_writes.sql", "215_bots_whatsapp.sql", "216_bots_media.sql"}) {
		testing.expectf(t, migration_applied(&conn, name), "%s applied", name)
	}
	for name in ([9]string{"bots", "bot_placement_candidates", "channel_bindings", "channel_pairings", "channel_cursors", "channel_messages", "bot_deliveries", "bot_delivery_attempts", "channel_push_events"}) {
		testing.expectf(t, sqlite_object_exists(&conn, name), "%s present", name)
	}
	mig_ok, _ = run_migrations(&conn)
	testing.expect(t, mig_ok, "repeat upgrade is idempotent")
}

@(test)
test_bots_upgrade_from_staging_209 :: proc(t: ^testing.T) {
	rmo_bots_upgrade(t, true)
}

@(test)
test_bots_upgrade_from_production_209 :: proc(t: ^testing.T) {
	rmo_bots_upgrade(t, false)
}

// Reconstruct the deployed staging order, including partial rollouts, rather
// than relabeling a database that already ran main's transport migration.
@(test)
test_bots_renumber_upgrade_from_staging_legacy_names :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	names := [4]string{"213_bots.sql", "214_agent_writes.sql", "215_bots_whatsapp.sql", "216_bots_media.sql"}
	old_names := [4]string{"209_bots.sql", "210_agent_writes.sql", "211_bots_whatsapp.sql", "212_bots_media.sql"}
	for applied in 1 ..= 4 {
		conn, path, ok := tmpl_open_file_prod(t, "bots_legacy_names")
		defer tmpl_remove_db(path)
		if !ok do return
		defer close(&conn)
		migrated, err := run_migrations(&conn, stop_before = "210_extension_version_sync_0_5_56.sql")
		if !testing.expect(t, migrated, err.message) do return
		for i in 0 ..< applied {
			sql := migration_sql(names[i], "")
			executed := exec(&conn, sql)
			delete(sql)
			if !testing.expectf(t, executed, "apply deployed %s", old_names[i]) do return
			testing.expect(t, exec(&conn, fmt.tprintf("INSERT INTO schema_migrations(version,applied_at) VALUES ('%s','staging-original');", old_names[i])))
		}
		testing.expect(t, exec(&conn, "INSERT INTO bots(bot_id,owner_user_id,agent_id,created_at,updated_at) VALUES ('legacy-bot','legacy-owner','legacy-agent','created','updated');"))
		if applied >= 2 {
			testing.expect(t, exec(&conn, "INSERT INTO agent_writes(write_id,owner_user_id,actor_agent_instance_id,resource_kind,resource_id,action,created_at) VALUES ('legacy-write','legacy-owner','legacy-instance','memory','legacy-memory','create','created');"))
		}
		if applied == 4 {
			// Replaying 215 would discard these media columns; replaying 216
			// would fail on the existing attachment table.
			testing.expect(t, exec(&conn, "INSERT INTO channel_push_events(seq,provider,event_key,kind,external_chat_id,received_at,media_kind,media_ref,media_name) VALUES (41,'whatsapp','legacy-media','media','chat','received','image','file-ref','photo.png');"))
		}
		testing.expect(t, !table_column_exists(&conn, "agent_instances", "runtime_transport"), "staging has not run main 211")
		for _ in 0 ..< 2 {
			migrated, err = run_migrations(&conn)
			if !testing.expect(t, migrated, err.message) do return
			for name, i in names {
				testing.expectf(t, migration_applied(&conn, name), "%s recognized", name)
				if i < applied {
					testing.expect_value(t, rmo_text(&conn, fmt.tprintf("SELECT applied_at FROM schema_migrations WHERE version='%s';", old_names[i])), "staging-original")
					testing.expect_value(t, rmo_text(&conn, fmt.tprintf("SELECT count(*) FROM schema_migrations WHERE version='%s';", name)), "0")
				} else {
					testing.expect_value(t, rmo_text(&conn, fmt.tprintf("SELECT count(*) FROM schema_migrations WHERE version='%s';", name)), "1")
				}
			}
			testing.expect_value(t, rmo_text(&conn, "SELECT agent_id || ':' || created_at || ':' || updated_at FROM bots WHERE bot_id='legacy-bot';"), "legacy-agent:created:updated")
			if applied >= 2 {
				testing.expect_value(t, rmo_text(&conn, "SELECT resource_id FROM agent_writes WHERE write_id='legacy-write';"), "legacy-memory")
			}
			if applied == 4 {
				testing.expect_value(t, rmo_text(&conn, "SELECT CAST(seq AS TEXT) || ':' || kind || ':' || media_kind || ':' || media_ref || ':' || media_name FROM channel_push_events WHERE event_key='legacy-media';"), "41:media:image:file-ref:photo.png")
			}
			testing.expect(t, table_column_exists(&conn, "agent_instances", "runtime_transport"))
			testing.expect(t, sqlite_object_exists(&conn, "acp_assistant_turns"))
			for name in ([3]string{"210_extension_version_sync_0_5_56.sql", "211_provider_transport.sql", "212_extension_version_sync_0_5_57.sql"}) {
				testing.expectf(t, migration_applied(&conn, name), "main %s runs after staging bots", name)
			}
			testing.expect_value(t, rmo_text(&conn, "PRAGMA integrity_check;"), "ok")
		}
	}
}

@(test)
test_bots_renumber_upgrade_from_production_0_5_57 :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, path, ok := tmpl_open_file_prod(t, "bots_prod_0_5_57")
	defer tmpl_remove_db(path)
	if !ok do return
	defer close(&conn)
	migrated, err := run_migrations(&conn, stop_before = "213_bots.sql")
	if !testing.expect(t, migrated, err.message) do return
	testing.expect(t, migration_applied(&conn, "212_extension_version_sync_0_5_57.sql"))
	testing.expect(t, !sqlite_object_exists(&conn, "bots"))
	testing.expect(t, table_column_exists(&conn, "agent_instances", "runtime_transport"))
	for _ in 0 ..< 2 {
		migrated, err = run_migrations(&conn)
		if !testing.expect(t, migrated, err.message) do return
		for name in ([4]string{"213_bots.sql", "214_agent_writes.sql", "215_bots_whatsapp.sql", "216_bots_media.sql"}) {
			testing.expectf(t, migration_applied(&conn, name), "%s applied", name)
		}
		testing.expect(t, sqlite_object_exists(&conn, "channel_attachments"))
		testing.expect_value(t, rmo_text(&conn, "PRAGMA integrity_check;"), "ok")
	}
}

// PR #29's namespaced WhatsApp migration and Copilot's numeric migration must
// both survive the release merge, including upgrades from either boundary.
@(test)
test_release_0_5_64_upgrades_whatsapp_and_copilot :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	for stop in ([2]string{"whatsapp_001_invite_only.sql", "224_copilot_acp_transport.sql"}) {
		conn, path, ok := tmpl_open_file_prod(t, "release_0_5_64")
		if !ok do return
		migrated, err := run_migrations(&conn, stop_before = stop)
		if testing.expect(t, migrated, err.message) {
			testing.expect(t, !migration_applied(&conn, "224_copilot_acp_transport.sql"))
			for _ in 0 ..< 2 {
				migrated, err = run_migrations(&conn)
				if !testing.expect(t, migrated, err.message) do break
				testing.expect(t, migration_applied(&conn, "whatsapp_001_invite_only.sql"))
				testing.expect(t, migration_applied(&conn, "224_copilot_acp_transport.sql"))
				testing.expect(t, migration_applied(&conn, "225_extension_version_sync_0_5_64.sql"))
				testing.expect(t, table_column_exists(&conn, "account_entitlements", "override_whatsapp_enabled"))
				testing.expect_value(t, rmo_text(&conn, "SELECT default_transport FROM provider_catalog WHERE provider='copilot';"), "pty")
				testing.expect_value(t, rmo_text(&conn, "SELECT transports FROM provider_catalog WHERE provider='copilot';"), "[\"pty\",\"acp\"]")
				testing.expect_value(t, rmo_text(&conn, "PRAGMA integrity_check;"), "ok")
			}
		}
		close(&conn)
		tmpl_remove_db(path)
	}
}

// A released 0.5.95 database already has slot 265. Reconciliation must
// preserve that ledger entry, then apply each settings-panel schema change.
@(test)
test_release_0_5_95_upgrades_settings_panel :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	release_sync :: "265_extension_version_sync_0_5_95.sql"
	transport_override :: "266_instance_runtime_transport_override.sql"
	waiting_for_idle :: "267_reconfiguration_waiting_for_idle.sql"

	conn, path, ok := tmpl_open_file_prod(t, "release_0_5_95")
	defer tmpl_remove_db(path)
	if !ok do return
	defer close(&conn)
	migrated, err := run_migrations(&conn, stop_before = transport_override)
	if !testing.expect(t, migrated, err.message) do return
	testing.expect(t, migration_applied(&conn, release_sync))
	testing.expect_value(t, rmo_text(&conn, "SELECT json_extract(extension, '$.min_version') FROM provider_catalog WHERE provider='codex';"), "0.5.95")
	testing.expect(t, !table_column_exists(&conn, "agent_instances", "runtime_transport_override"))
	testing.expect(t, !sqlite_table_sql_mentions(&conn, "instance_reconfigurations", "waiting_for_idle"))

	// If the release sync is replayed it replaces the catalog etag.
	if !testing.expect(t, exec(&conn, "UPDATE provider_catalog_meta SET catalog_etag='release-upgrade-fixture';")) do return

	migrated, err = run_migrations(&conn, stop_before = waiting_for_idle)
	if !testing.expect(t, migrated, err.message) do return
	testing.expect(t, migration_applied(&conn, transport_override))
	testing.expect(t, table_column_exists(&conn, "agent_instances", "runtime_transport_override"))
	testing.expect(t, !sqlite_table_sql_mentions(&conn, "instance_reconfigurations", "waiting_for_idle"))

	for _ in 0 ..< 2 {
		migrated, err = run_migrations(&conn)
		if !testing.expect(t, migrated, err.message) do return
		testing.expect(t, migration_applied(&conn, release_sync))
		testing.expect(t, migration_applied(&conn, transport_override))
		testing.expect(t, migration_applied(&conn, waiting_for_idle))
		testing.expect(t, sqlite_table_sql_mentions(&conn, "instance_reconfigurations", "waiting_for_idle"))
		testing.expect(t, sqlite_trigger_mentions(&conn, "instance_reconfiguration_commit", "runtime_transport_override"))
		testing.expect_value(t, rmo_text(&conn, "SELECT catalog_etag FROM provider_catalog_meta;"), "release-upgrade-fixture")
		testing.expect_value(t, rmo_text(&conn, "PRAGMA integrity_check;"), "ok")
	}
}
