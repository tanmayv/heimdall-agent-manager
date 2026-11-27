package sqlite

import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import provider "odin_test:hub/service/provider"

// G6 (269): the provider-wide transport becomes each profile's own value.
// Backfill: a provider-wide value applies to every profile of that provider on
// the same bridge; NULL stays NULL; enabled and updated_at are preserved, and a
// new row holds only the transport (enabled NULL: still derived on every read).
@(test)
test_profile_transport_migration_backfills_each_profile :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, opened, _ := open(":memory:")
	if !testing.expect(t, opened) do return
	defer close(&conn)
	migrated, err := run_migrations(&conn, stop_before = "269_profile_transport.sql")
	if !testing.expect(t, migrated, err.message) do return
	for sql in ([]string{
		"INSERT INTO bridges(bridge_id,owner_user_id,created_at,updated_at) VALUES('b1','owner','',''),('b2','owner','','');",
		"INSERT INTO bridge_provider_profiles(bridge_id,profile_id,provider,state,enabled) VALUES('b1','work','claude','ok',1),('b1','home','claude','ok',1),('b1','away','claude','ok',1),('b1','off','claude','ok',0),('b1','cx','codex','ok',1),('b1','cp','copilot','ok',1),('b2','work2','claude','ok',1);",
		"INSERT INTO bridge_provider_status(bridge_id,provider,profile_id,state,checked_at) VALUES('b1','claude','home','present',''),('b1','claude','off','present','');",
		// b1: claude is ACP provider-wide; codex follows the catalog; copilot is PTY.
		"INSERT INTO bridge_provider_settings(bridge_id,profile_id,provider,enabled,updated_at,transport) VALUES('b1','claude','claude',1,'t-claude','acp'),('b1','work','claude',0,'t-work',NULL),('b1','codex','codex',1,'t-codex',NULL),('b1','copilot','copilot',0,'t-copilot','pty'),('b1','cp','copilot',1,'t-cp',NULL);",
		// b2: claude has no provider-wide value, so its profile stays NULL.
		"INSERT INTO bridge_provider_settings(bridge_id,profile_id,provider,enabled,updated_at,transport) VALUES('b2','claude','claude',1,'t2',NULL),('b2','work2','claude',1,'t2-work',NULL);",
	}) {testing.expect(t, exec(&conn, sql), sql)}
	// 211 still refuses a per-profile value before 269.
	testing.expect(t, !exec(&conn, "UPDATE bridge_provider_settings SET transport='pty' WHERE bridge_id='b1' AND profile_id='work';"))

	migrated, err = run_migrations(&conn)
	if !testing.expect(t, migrated, err.message) do return
	testing.expect(t, migration_applied(&conn, "269_profile_transport.sql"))

	impl: Provider_Repo_SQLite
	repo := new_provider_repository(&impl, &conn)
	// enabled: "1"/"0" explicit, "" derived (NULL).
	Row :: struct {profile, transport, updated_at, enabled: string}
	expect_rows :: proc(t: ^testing.T, repo: ^iface.Provider_Repository, bridge: string, want: []Row, loc := #caller_location) {
		settings, serr := iface.bridge_provider_setting_list(repo, bridge)
		testing.expect_value(t, serr.code, domain.Error_Code.None, loc = loc)
		testing.expect_value(t, len(settings), len(want), loc = loc)
		for w in want {
			found := false
			for s in settings do if s.profile_id == w.profile {
				found = true
				enabled := "" if s.enabled_implicit else ("1" if s.enabled else "0")
				testing.expectf(t, s.transport == w.transport && enabled == w.enabled && s.updated_at == w.updated_at, "%s: got transport=%q enabled=%q updated_at=%q, want %v", w.profile, s.transport, enabled, s.updated_at, w, loc = loc)
			}
			testing.expectf(t, found, "%s: row missing", w.profile, loc = loc)
		}
	}
	expect_rows(t, &repo, "b1", []Row{
		{"claude", "acp", "t-claude", "1"},
		{"work", "acp", "t-work", "0"},    // existing row: transport copied, enabled kept
		{"home", "acp", "t-claude", ""},   // new rows: transport only, enablement derived
		{"away", "acp", "t-claude", ""},
		{"off", "acp", "t-claude", ""},
		{"codex", "", "t-codex", "1"},     // NULL stays NULL; cx gets no row
		{"copilot", "pty", "t-copilot", "0"},
		{"cp", "pty", "t-cp", "1"},
	})
	expect_rows(t, &repo, "b2", []Row{{"claude", "", "t2", "1"}, {"work2", "", "t2-work", "1"}})

	// Every profile resolves to the transport it had before the migration.
	svc := provider.Provider_Service{repo = &repo}
	for c in ([]struct {bridge, provider, profile, want: string}{
		{"b1", "claude", "claude", "acp"}, {"b1", "claude", "work", "acp"}, {"b1", "claude", "home", "acp"},
		{"b1", "codex", "cx", "pty"}, {"b1", "copilot", "cp", "pty"}, {"b2", "claude", "work2", "pty"},
	}) {
		got, rerr := provider.resolve_runtime_transport(&svc, c.bridge, c.provider, c.profile, check_ready = false)
		testing.expectf(t, rerr.code == .None && got == c.want, "%s/%s: %q %v", c.bridge, c.profile, got, rerr.code)
	}

	// Enablement stays derived for transport-only rows, exactly as with no row.
	svc_enabled :: proc(t: ^testing.T, svc: ^provider.Provider_Service, bridge, profile: string) -> bool {
		views, verr := provider.list_bridge_providers(svc, bridge)
		testing.expect_value(t, verr.code, domain.Error_Code.None)
		defer provider.bridge_provider_views_destroy(views)
		for v in views do if v.profile_id == profile do return v.enabled
		testing.expectf(t, false, "%s: no view", profile)
		return false
	}
	testing.expect(t, svc_enabled(t, &svc, "b1", "home"))   // detected + enabled profile
	testing.expect(t, !svc_enabled(t, &svc, "b1", "away"))  // not detected yet
	testing.expect(t, !svc_enabled(t, &svc, "b1", "off"))   // profile disabled
	// A profile detected after the migration becomes enabled...
	_, uerr := iface.bridge_provider_status_upsert(&repo, {bridge_id = "b1", provider = "claude", profile_id = "away", state = "present"})
	testing.expect_value(t, uerr.code, domain.Error_Code.None)
	testing.expect(t, svc_enabled(t, &svc, "b1", "away"))
	// ...and an uninstalled CLI stops being enabled.
	_, uerr = iface.bridge_provider_status_upsert(&repo, {bridge_id = "b1", provider = "claude", profile_id = "home", state = "absent"})
	testing.expect(t, !svc_enabled(t, &svc, "b1", "home"))
	// A transport save on a disabled profile does not pin it disabled.
	testing.expect_value(t, iface.set_provider_transport(&repo, "b1", "claude", "pty", "t-off", "off").code, domain.Error_Code.None)
	testing.expect(t, !svc_enabled(t, &svc, "b1", "off"))
	testing.expect(t, exec(&conn, "UPDATE bridge_provider_profiles SET enabled=1 WHERE bridge_id='b1' AND profile_id='off';"))
	testing.expect(t, svc_enabled(t, &svc, "b1", "off"))
	// An explicit enable/disable still wins over detection, and a later
	// transport save keeps it.
	_, uerr = iface.bridge_provider_setting_upsert(&repo, {bridge_id = "b1", provider = "claude", profile_id = "away", enabled = false, updated_at = "t-x"})
	testing.expect(t, !svc_enabled(t, &svc, "b1", "away"))
	testing.expect_value(t, iface.set_provider_transport(&repo, "b1", "claude", "acp", "t-y", "away").code, domain.Error_Code.None)
	testing.expect(t, !svc_enabled(t, &svc, "b1", "away"))
	_, uerr = iface.bridge_provider_setting_upsert(&repo, {bridge_id = "b1", provider = "claude", profile_id = "home", enabled = true, updated_at = "t-z"})
	testing.expect(t, svc_enabled(t, &svc, "b1", "home"))   // explicit enable over an absent CLI

	// The per-profile CHECK admits any profile and still rejects other values.
	testing.expect(t, exec(&conn, "UPDATE bridge_provider_settings SET transport='pty' WHERE bridge_id='b1' AND profile_id='work';"))
	testing.expect(t, !exec(&conn, "UPDATE bridge_provider_settings SET transport='other' WHERE bridge_id='b1' AND profile_id='work';"))
	// The rebuilt table keeps its key and foreign key.
	testing.expect(t, !exec(&conn, "INSERT INTO bridge_provider_settings(bridge_id,profile_id,provider,enabled,updated_at) VALUES('b1','work','claude',1,'');"))
	testing.expect(t, !exec(&conn, "INSERT INTO bridge_provider_settings(bridge_id,profile_id,provider,enabled,updated_at) VALUES('b1','ghost','no_such_provider',1,'');"))

	// A committed migration whose ledger write was lost is not re-run: the
	// completion guard keeps a later per-profile choice.
	testing.expect(t, exec(&conn, "UPDATE bridge_provider_settings SET transport=NULL WHERE bridge_id='b1' AND profile_id='home';"))
	testing.expect(t, exec(&conn, "DELETE FROM schema_migrations WHERE version='269_profile_transport.sql';"))
	migrated, err = run_migrations(&conn)
	testing.expect(t, migrated, err.message)
	testing.expect(t, migration_applied(&conn, "269_profile_transport.sql"))
	home, _ := iface.get_provider_transport(&repo, "b1", "claude", "home")
	testing.expect_value(t, home, "")

	embedded := migration_sql("269_profile_transport.sql", "")
	disk := migration_sql("269_profile_transport.sql", "src/hub/repository/sqlite/migrations")
	testing.expect_value(t, embedded, disk)
}
