package sqlite

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

@(test)
test_provider_catalog_migration_and_repository :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("/tmp/test_provider_catalog_%d.db", os.get_pid())
	os.remove(db_path)
	defer os.remove(db_path)

	conn, open_ok, open_err := open(db_path)
	if !testing.expect(t, open_ok, fmt.tprintf("database opens: %s", open_err.message)) do return
	defer close(&conn)

	migrated, migration_err := run_migrations(&conn)
	if !testing.expect(t, migrated, fmt.tprintf("migrations succeed: %s", migration_err.message)) do return
	testing.expect(
		t,
		sqlite_object_exists(&conn, "provider_catalog"),
		"provider catalog table exists",
	)
	testing.expect(
		t,
		sqlite_object_exists(&conn, "provider_models"),
		"provider models table exists",
	)
	testing.expect(
		t,
		sqlite_object_exists(&conn, "provider_catalog_meta"),
		"provider catalog meta table exists",
	)
	testing.expect(
		t,
		sqlite_object_exists(&conn, "provider_icons"),
		"provider icon bytes table exists",
	)
	testing.expect(
		t,
		migration_applied(&conn, "058_provider_catalog.sql"),
		"provider catalog migration is recorded",
	)

	impl := Provider_Repo_SQLite{}
	repo := new_provider_repository(&impl, &conn)
	providers, list_err := iface.provider_catalog_list(&repo)
	if !testing.expect_value(t, list_err.code, domain.Error_Code.None) do return
	defer domain.provider_catalog_destroy(providers)

	if !testing.expect_value(t, len(providers), 4) do return
	testing.expect_value(t, providers[0].provider, "claude")
	testing.expect_value(t, providers[1].provider, "codex")
	testing.expect_value(t, providers[2].provider, "copilot")
	testing.expect_value(t, providers[3].provider, "antigravity")
	testing.expect_value(t, providers[0].binary, "claude")
	testing.expect_value(t, providers[1].model_flag, "-m")
	testing.expect_value(t, providers[3].binary, "agy")
	testing.expect_value(t, providers[3].yolo_args_json, `["--dangerously-skip-permissions"]`)
	testing.expect_value(t, providers[3].prompt_args_json, `["--prompt-interactive"]`)
	testing.expect(
		t,
		strings.contains(
			providers[3].startup_detection_json,
			`"auto_enter_patterns":["Do you trust the contents of this project?"]`,
		),
		"Antigravity startup detection recognizes its project trust prompt",
	)
	testing.expect_value(t, len(providers[0].models), 3)
	testing.expect_value(t, len(providers[1].models), 4)
	testing.expect_value(t, providers[0].models[0].model_id, "claude-opus-5")
	testing.expect_value(t, providers[1].models[0].model_id, "gpt-5")
	testing.expect(
		t,
		strings.contains(
			providers[0].startup_detection_json,
			`"auto_enter_patterns":["Choose the text style that looks best with your terminal","Yes, I trust this folder"]`,
		),
		"Claude startup detection recognizes first-run theme and trust prompts",
	)
	testing.expect(
		t,
		strings.contains(providers[0].startup_detection_json, `"auto_enter_pre_keys":["Up","Up"]`),
		"Claude startup detection selects the safe affirmative choices before Enter",
	)
	testing.expect(
		t,
		strings.contains(
			providers[0].startup_detection_json,
			`"blocked_patterns":["Select login method:","Not logged in. Run claude auth login to authenticate.","Please run /login"]`,
		),
		"Claude authentication prompts block instead of being auto-approved",
	)
	testing.expect(
		t,
		strings.contains(
			providers[1].startup_detection_json,
			`"auto_enter_patterns":["Do you trust the contents of this directory?","Allow for this session"]`,
		),
		"Codex startup detection recognizes directory trust and session approval prompts",
	)
	testing.expect(
		t,
		strings.contains(providers[1].startup_detection_json, `"auto_enter_pre_keys":["",""]`),
		"Codex startup detection accepts the already-selected safe choices",
	)

	_, jetski_found, jetski_err := iface.provider_catalog_get(&repo, "jetski")
	testing.expect_value(t, jetski_err.code, domain.Error_Code.None)
	testing.expect(t, !jetski_found, "removed jetski provider is not seeded")
	_, pi_found, pi_err := iface.provider_catalog_get(&repo, "pi")
	testing.expect_value(t, pi_err.code, domain.Error_Code.None)
	testing.expect(t, !pi_found, "removed pi provider is not seeded")

	etag, etag_err := iface.provider_catalog_etag(&repo)
	defer delete(etag)
	testing.expect_value(t, etag_err.code, domain.Error_Code.None)
	testing.expect(t, strings.has_prefix(etag, "sha256:"), "catalog etag is explicitly SHA-256")
	testing.expect_value(t, len(etag), len("sha256:") + 64)

	icon, icon_found, icon_err := iface.provider_icon_get(&repo, "codex")
	defer if icon_found do domain.provider_icon_destroy(icon)
	testing.expect_value(t, icon_err.code, domain.Error_Code.None)
	testing.expect(t, icon_found, "catalog icon exists")
	testing.expect_value(t, icon.content_type, "image/svg+xml")
	testing.expect(
		t,
		strings.has_prefix(icon.content, "<svg"),
		"icon bytes are served from the Hub database",
	)

	// The append-only migration ledger makes the catalog seed idempotent.
	migrated_again, migration_again_err := run_migrations(&conn)
	testing.expect(
		t,
		migrated_again,
		fmt.tprintf("second migration pass succeeds: %s", migration_again_err.message),
	)
}
