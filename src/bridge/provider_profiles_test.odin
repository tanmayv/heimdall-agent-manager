package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import vault "odin_test:lib/vault"

// REQ-PROF-1, 2, 4: provider profile store, validation and env layering. The tests
// share the store globals, so each holds g_profile_test_mu for its whole run.

g_profile_test_mu: sync.Mutex
@(private = "file")
g_profile_test_kr_storage: vault.Vault_Keyring
@(private = "file")
g_profile_test_seq: int
// Package-level so the slice outlives profile_test_setup (a slice literal would not).
@(private = "file")
PROFILE_TEST_CATALOG := [?]string{"claude", "codex", "pi", "copilot"}

@(private = "file")
profile_test_setup :: proc(t: ^testing.T) -> string {
	sync.mutex_lock(&g_profile_test_mu)
	dir := strings.concatenate({os.get_env("TMPDIR", context.temp_allocator) if os.get_env("TMPDIR", context.temp_allocator) != "" else "/tmp", "/ham-profile-test-", random_hex_string_temp(8)}, context.temp_allocator)
	g_profile_test_seq += 1
	dir = strings.concatenate({dir, "-", random_hex_string_temp(4), "-"}, context.temp_allocator)
	dir = fmt.tprintf("%s%d-%d", dir, os.get_pid(), g_profile_test_seq)
	_ = os.remove_all(dir)
	testing.expect(t, os.make_directory(dir, {.Read_User, .Write_User, .Execute_User}) == nil)
	g_profile_test_store_path = strings.concatenate({dir, "/provider_profiles.json"}, context.temp_allocator)
	g_profile_test_kr_storage = test_keyring_from_hex(PROFILE_OP_KEY1, 1)
	g_profile_test_keyring = &g_profile_test_kr_storage
	g_profile_test_use_keyring = true
	g_profile_test_catalog = PROFILE_TEST_CATALOG[:]
	return dir
}

@(private = "file")
profile_test_teardown :: proc(dir: string) {
	_ = os.remove_all(dir)
	g_profile_test_store_path = ""
	vault.keyring_wipe(&g_profile_test_kr_storage)
	g_profile_test_keyring = nil
	g_profile_test_use_keyring = false
	g_profile_test_catalog = nil
	sync.mutex_unlock(&g_profile_test_mu)
}

@(private = "file")
random_hex_string_temp :: proc(n: int) -> string {
	buf := make([]byte, n, context.temp_allocator)
	digits := "0123456789abcdef"
	seed := int(profile_now_ms()) + int(uintptr(raw_data(buf)))
	for i in 0 ..< n do buf[i] = digits[(seed + i * 31) % 16]
	return string(buf)
}

@(test)
test_profile_id_namespace_and_metadata :: proc(t: ^testing.T) {
	dir := profile_test_setup(t)
	defer profile_test_teardown(dir)
	ok_p := Provider_Profile{profile_id = "claude_k3fq", provider = "claude", enabled = true, accent = "#a1B2c3"}
	testing.expect_value(t, profile_validate_metadata(&ok_p), Profile_Error.None)
	def := Provider_Profile{profile_id = "claude", provider = "claude"}
	testing.expect_value(t, profile_validate_metadata(&def), Profile_Error.None)
	// A custom profile may never take any catalog slug.
	clash := Provider_Profile{profile_id = "codex", provider = "claude"}
	testing.expect_value(t, profile_validate_metadata(&clash), Profile_Error.Reserved_Id)
	for bad in ([]string{"", "Claude", "1abc", "a b", "abcdefghijklmnopqrstuvwxyz0123456", "a.b"}) {
		p := Provider_Profile{profile_id = bad, provider = "claude"}
		testing.expectf(t, profile_validate_metadata(&p) == .Invalid_Id, "id %q accepted", bad)
	}
	unknown := Provider_Profile{profile_id = "x_1", provider = "nope"}
	testing.expect_value(t, profile_validate_metadata(&unknown), Profile_Error.Unknown_Provider)
	accent := Provider_Profile{profile_id = "x_1", provider = "claude", accent = "red"}
	testing.expect_value(t, profile_validate_metadata(&accent), Profile_Error.Invalid_Accent)
	label := Provider_Profile{profile_id = "x_1", provider = "claude", label_enc = "Work"}
	testing.expect_value(t, profile_validate_metadata(&label), Profile_Error.Invalid_Label)
}

@(test)
test_profile_secret_validation :: proc(t: ^testing.T) {
	dir := profile_test_setup(t)
	defer profile_test_teardown(dir)
	s := Provider_Profile_Secret{config_dir = "/abs/cfg", env = []Provider_Profile_Env{{name = "ANTHROPIC_BASE_URL", value = "x"}}, args = []string{"--chrome"}}
	testing.expect_value(t, profile_validate_secret("claude", &s), Profile_Error.None)
	rel := Provider_Profile_Secret{home_dir = "rel/home"}
	testing.expect_value(t, profile_validate_secret("claude", &rel), Profile_Error.Path_Invalid)
	dots := Provider_Profile_Secret{home_dir = "a/../b"} // relative even after cleaning
	testing.expect_value(t, profile_validate_secret("claude", &dots), Profile_Error.Path_Invalid)
	nocfg := Provider_Profile_Secret{config_dir = "/abs"}
	testing.expect_value(t, profile_validate_secret("copilot", &nocfg), Profile_Error.Config_Dir_Unsupported)
	hd := Provider_Profile_Secret{env = []Provider_Profile_Env{{name = "HEIMDALL_AGENT_TOKEN", value = "x"}}}
	testing.expect_value(t, profile_validate_secret("claude", &hd), Profile_Error.Env_Forbidden)
	home := Provider_Profile_Secret{home_dir = "/h", env = []Provider_Profile_Env{{name = "XDG_CONFIG_HOME", value = "/x"}}}
	testing.expect_value(t, profile_validate_secret("claude", &home), Profile_Error.Env_Forbidden)
	cfg := Provider_Profile_Secret{config_dir = "/c", env = []Provider_Profile_Env{{name = "CLAUDE_CONFIG_DIR", value = "/x"}}}
	testing.expect_value(t, profile_validate_secret("claude", &cfg), Profile_Error.Env_Forbidden)
	dup := Provider_Profile_Secret{env = []Provider_Profile_Env{{name = "A", value = "1"}, {name = "A", value = "2"}}}
	testing.expect_value(t, profile_validate_secret("claude", &dup), Profile_Error.Env_Invalid)
	badname := Provider_Profile_Secret{env = []Provider_Profile_Env{{name = "1A", value = "1"}}}
	testing.expect_value(t, profile_validate_secret("claude", &badname), Profile_Error.Env_Invalid)
	emptyarg := Provider_Profile_Secret{args = []string{""}}
	testing.expect_value(t, profile_validate_secret("claude", &emptyarg), Profile_Error.Args_Invalid)
	notexec := Provider_Profile_Secret{binary = "/nonexistent/claude"}
	testing.expect_value(t, profile_validate_secret("claude", &notexec), Profile_Error.Binary_Invalid)
}

@(test)
test_profile_env_plan_order :: proc(t: ^testing.T) {
	p := Provider_Profile{profile_id = "claude_w", provider = "claude", secret = Provider_Profile_Secret{
		home_dir = "/p/home", env = []Provider_Profile_Env{{name = "FOO", value = "bar"}},
	}}
	plan := profile_env_plan(&p)
	env := profile_apply_env_plan([]string{"HOME=/inst/home", "XDG_CONFIG_HOME=/inst/home/.config", "CLAUDE_CONFIG_DIR=/leak", "PATH=/bin", "FOO=old"}, plan)
	joined := strings.join(env, "\n", context.temp_allocator)
	testing.expect(t, strings.contains(joined, "HOME=/p/home\n") || strings.has_prefix(joined, "HOME=/p/home"))
	testing.expect(t, strings.contains(joined, "XDG_CONFIG_HOME=/p/home/.config"))
	testing.expect(t, !strings.contains(joined, "/inst/home"))
	testing.expect(t, strings.contains(joined, "CLAUDE_CONFIG_DIR=/p/home/.claude") && !strings.contains(joined, "/leak"))
	testing.expect(t, strings.contains(joined, "PATH=/bin"))
	testing.expect(t, strings.contains(joined, "FOO=bar") && !strings.contains(joined, "FOO=old"))
	c := Provider_Profile{profile_id = "codex_w", provider = "codex", secret = Provider_Profile_Secret{config_dir = "/c/codex/"}}
	cplan := profile_env_plan(&c)
	cenv := strings.join(profile_apply_env_plan([]string{"CODEX_HOME=/real", "HOME=/inst"}, cplan), "\n", context.temp_allocator)
	testing.expect(t, strings.contains(cenv, "CODEX_HOME=/c/codex") && !strings.contains(cenv, "/real"))
	testing.expect(t, strings.contains(cenv, "HOME=/inst"))
}

@(test)
test_profile_store_roundtrip_encrypted_and_keep :: proc(t: ^testing.T) {
	dir := profile_test_setup(t)
	defer profile_test_teardown(dir)
	cfg := strings.concatenate({dir, "/cfg-work"}, context.temp_allocator)
	p := Provider_Profile{profile_id = "claude_w", provider = "claude", enabled = true, secret = Provider_Profile_Secret{
		config_dir = cfg, env = []Provider_Profile_Env{{name = "API_KEY", value = "s3cret-value", sensitive = true}, {name = "PLAIN", value = "v"}},
		args = []string{"--chrome"},
	}}
	testing.expect_value(t, profile_upsert(&p, nil, 1000), Profile_Error.None)
	testing.expect(t, os.is_dir(cfg))
	raw, _ := os.read_entire_file(g_profile_test_store_path, context.temp_allocator)
	text := string(raw)
	// Trusted host: only the secret value is sealed; the rest is plain.
	testing.expect(t, !strings.contains(text, "s3cret-value"))
	for plain in ([]string{"API_KEY", "PLAIN", "--chrome", "cfg-work"}) {
		testing.expectf(t, strings.contains(text, plain), "store should keep %q in clear", plain)
	}
	info, _ := os.stat(g_profile_test_store_path, context.temp_allocator)
	testing.expect(t, info.mode & os.Permissions{.Read_Group, .Read_Other, .Write_Group, .Write_Other} == {})

	// Update with the sensitive value redacted: keep retains it.
	upd := Provider_Profile{profile_id = "claude_w", provider = "claude", enabled = true, secret = Provider_Profile_Secret{
		config_dir = cfg, env = []Provider_Profile_Env{{name = "API_KEY", value = "", sensitive = true}},
	}}
	testing.expect_value(t, profile_upsert(&upd, []string{"API_KEY"}, 2000), Profile_Error.None)
	got, err := profile_lookup("claude", "claude_w")
	testing.expect_value(t, err, Profile_Error.None)
	testing.expect_value(t, len(got.secret.env), 1)
	if len(got.secret.env) == 1 do testing.expect_value(t, got.secret.env[0].value, "s3cret-value")
	testing.expect_value(t, got.created_at, i64(1000))
	testing.expect_value(t, got.updated_at, i64(2000))

	// Provider is fixed for an id; unknown ids never fall back to the default.
	_, merr := profile_lookup("codex", "claude_w")
	testing.expect_value(t, merr, Profile_Error.Provider_Mismatch)
	_, uerr := profile_lookup("claude", "claude_gone")
	testing.expect_value(t, uerr, Profile_Error.Unknown)
	def, derr := profile_lookup("claude", "")
	testing.expect_value(t, derr, Profile_Error.None)
	testing.expect_value(t, def.profile_id, "claude")

	// Another account's keyring cannot open the store; a locked bridge reports Locked.
	other := test_keyring_from_hex(PROFILE_OP_KEY2, 1)
	defer vault.keyring_wipe(&other)
	g_profile_test_keyring = &other
	_, kerr := profile_list()
	testing.expect_value(t, kerr, Profile_Error.Store_Unavailable)
	g_profile_test_keyring = nil
	_, lerr := profile_lookup("claude", "claude_w")
	testing.expect_value(t, lerr, Profile_Error.Locked)
	_, derr2 := profile_lookup("claude", "")
	testing.expect_value(t, derr2, Profile_Error.None) // defaults launch while locked
	testing.expect(t, strings.contains(profile_report_json(context.temp_allocator), `"env_count":1`))
	g_profile_test_keyring = &g_profile_test_kr_storage

	// Disabled and removed.
	upd.enabled = false
	testing.expect_value(t, profile_upsert(&upd, []string{"API_KEY"}, 3000), Profile_Error.None)
	_, dis := profile_lookup("claude", "claude_w")
	testing.expect_value(t, dis, Profile_Error.Disabled)
	testing.expect_value(t, profile_remove("claude"), Profile_Error.Default_Not_Removable)
	testing.expect_value(t, profile_remove("claude_w"), Profile_Error.None)
	testing.expect_value(t, profile_remove("claude_w"), Profile_Error.Not_Found)
}

@(test)
test_profile_dirs_leaf_only_and_report_metadata_only :: proc(t: ^testing.T) {
	dir := profile_test_setup(t)
	defer profile_test_teardown(dir)
	deep := Provider_Profile{profile_id = "codex_d", provider = "codex", enabled = true, secret = Provider_Profile_Secret{
		config_dir = strings.concatenate({dir, "/missing-parent/leaf"}, context.temp_allocator),
	}}
	testing.expect_value(t, profile_upsert(&deep, nil, 1), Profile_Error.Path_Invalid)
	p := Provider_Profile{profile_id = "pi_x", provider = "pi", enabled = true, accent = "#112233", label_enc = "", secret = Provider_Profile_Secret{
		home_dir = strings.concatenate({dir, "/pi-home"}, context.temp_allocator),
		env = []Provider_Profile_Env{{name = "SECRET_NAME", value = "secret-val", sensitive = true}},
		args = []string{"--a", "--b"},
	}}
	testing.expect_value(t, profile_upsert(&p, nil, 5), Profile_Error.None)
	report := profile_report_json(context.temp_allocator)
	for leak in ([]string{"secret-val", "SECRET_NAME", "pi-home", "--a"}) {
		testing.expectf(t, !strings.contains(report, leak), "report leaks %q", leak)
	}
	wire: Provider_Profiles_Report_Wire
	testing.expect(t, json.unmarshal_string(report, &wire, json.Specification.JSON, context.temp_allocator) == nil)
	testing.expect_value(t, len(wire.profiles), 1)
	if len(wire.profiles) == 1 {
		e := wire.profiles[0]
		testing.expect(t, e.has_home_dir && !e.has_config_dir && !e.has_binary)
		testing.expect_value(t, e.env_count, 1)
		testing.expect_value(t, e.args_count, 2)
		testing.expect_value(t, e.state, "ok")
	}
}

// ── Sealed ops (amendment 5) ────────────────────────────────────────────────

PROFILE_OP_KEY1 :: "1111111111111111111111111111111111111111111111111111111111111111"
@(private = "file")
PROFILE_OP_KEY2 :: "2222222222222222222222222222222222222222222222222222222222222222"

@(private = "file")
profile_op_seal :: proc(kr: ^vault.Vault_Keyring, op: Provider_Profile_Op_Wire) -> string {
	data, _ := json.marshal(op, allocator = context.temp_allocator)
	tok, _ := vault.seal_string(string(data), kr, context.temp_allocator)
	return tok
}

@(test)
test_profile_op_open_checks :: proc(t: ^testing.T) {
	now := profile_now_ms()
	kr := test_keyring_two_epochs(PROFILE_OP_KEY1, PROFILE_OP_KEY2)
	defer vault.keyring_wipe(&kr)
	old := test_keyring_from_hex(PROFILE_OP_KEY1, 1)
	defer vault.keyring_wipe(&old)
	base := Provider_Profile_Op_Wire{op = "get", profile_id = "claude", bridge_id = "brg_a", boot_id = "boot1", ts = now}

	ok_op := base
	ok_op.nonce = "nonce-ok-0000000001"
	op, err := profile_op_open(profile_op_seal(&kr, ok_op), &kr, "brg_a", "boot1", now)
	testing.expect_value(t, err, "")
	testing.expect_value(t, op.op, "get")

	// Replayed nonce.
	_, rerr := profile_op_open(profile_op_seal(&kr, ok_op), &kr, "brg_a", "boot1", now)
	testing.expect_value(t, rerr, "profile_replay")

	// Older epoch: a revoked device only holds pre-rotation keys.
	stale := base
	stale.nonce = "nonce-stale-00000001"
	_, serr := profile_op_open(profile_op_seal(&old, stale), &kr, "brg_a", "boot1", now)
	testing.expect_value(t, serr, "profile_stale_epoch")

	wrong := base
	wrong.nonce = "nonce-wrong-00000001"
	wrong.bridge_id = "brg_b"
	_, werr := profile_op_open(profile_op_seal(&kr, wrong), &kr, "brg_a", "boot1", now)
	testing.expect_value(t, werr, "profile_wrong_bridge")

	boot := base
	boot.nonce = "nonce-boot-000000001"
	boot.boot_id = "boot0"
	_, berr := profile_op_open(profile_op_seal(&kr, boot), &kr, "brg_a", "boot1", now)
	testing.expect_value(t, berr, "profile_stale_boot")

	expired := base
	expired.nonce = "nonce-expired-000001"
	expired.ts = now - 10 * 60_000
	_, eerr := profile_op_open(profile_op_seal(&kr, expired), &kr, "brg_a", "boot1", now)
	testing.expect_value(t, eerr, "profile_expired")

	_, perr := profile_op_open("not a token", &kr, "brg_a", "boot1", now)
	testing.expect_value(t, perr, "profile_bad_seal")
	_, lerr := profile_op_open(profile_op_seal(&kr, ok_op), nil, "brg_a", "boot1", now)
	testing.expect_value(t, lerr, "profile_locked")
}

@(test)
test_profile_op_apply_upsert_get_redacts :: proc(t: ^testing.T) {
	dir := profile_test_setup(t)
	defer profile_test_teardown(dir)
	up := Provider_Profile_Op_Wire{op = "upsert", profile_id = "claude_w", nonce = "n1", body = Provider_Profile_Body_Wire{
		provider = "claude", enabled = true, accent = "#00aa00", env = []Provider_Profile_Env_Wire{{name = "TOKEN", value = "tok-secret", sensitive = true}, {name = "MODE", value = "fast"}},
		args = []string{"--verbose"},
	}}
	testing.expect_value(t, profile_op_apply(&up, 10).error, "")
	get := Provider_Profile_Op_Wire{op = "get", profile_id = "claude_w", nonce = "n2"}
	out := profile_op_apply(&get, 11)
	testing.expect_value(t, out.error, "")
	testing.expect(t, !strings.contains(out.response, "tok-secret"))
	testing.expect(t, strings.contains(out.response, `"value_redacted":true`) && strings.contains(out.response, "fast") && strings.contains(out.response, "--verbose"))
	// Keep the redacted secret on the next edit.
	up2 := up
	up2.nonce = "n3"
	up2.body.env = []Provider_Profile_Env_Wire{{name = "TOKEN", value = "", sensitive = true, keep = true}}
	testing.expect_value(t, profile_op_apply(&up2, 12).error, "")
	p, _ := profile_lookup("claude", "claude_w")
	testing.expect(t, len(p.secret.env) == 1 && p.secret.env[0].value == "tok-secret")
	// Unedited default profile is readable; unknown ids are not.
	def := Provider_Profile_Op_Wire{op = "get", profile_id = "codex", nonce = "n4"}
	testing.expect_value(t, profile_op_apply(&def, 13).error, "")
	missing := Provider_Profile_Op_Wire{op = "get", profile_id = "codex_x", nonce = "n5"}
	testing.expect_value(t, profile_op_apply(&missing, 14).error, "profile_not_found")
	bad := Provider_Profile_Op_Wire{op = "drop", profile_id = "claude_w"}
	testing.expect_value(t, profile_op_apply(&bad, 15).error, "profile_bad_op")
	// Reset is for default profiles only; remove takes the provider from the record.
	rst := Provider_Profile_Op_Wire{op = "reset", profile_id = "claude_w"}
	testing.expect_value(t, profile_op_apply(&rst, 16).error, "profile_invalid_id")
	rm_default := Provider_Profile_Op_Wire{op = "remove", profile_id = "codex"}
	testing.expect_value(t, profile_op_apply(&rm_default, 17).error, "profile_default_not_removable")
	rm := Provider_Profile_Op_Wire{op = "remove", profile_id = "claude_w"}
	testing.expect_value(t, profile_op_apply(&rm, 18).error, "")
}

@(test)
test_profile_launch_argv_and_env :: proc(t: ^testing.T) {
	prof := Bridge_Provider_Profile{name = "claude", command = []string{"/bin/claude"}, base_args = []string{"--b"}, yolo_flags = []string{"--y"}, model_flag = "--model", extra_args = []string{"--chrome", "--x=1"}, prompt_delivery = "none"}
	argv := bridge_runtime_agent_argv_for_profile(prof, "opus", "tok", "inst")
	defer delete(argv)
	joined := strings.join(argv, " ", context.temp_allocator)
	testing.expect_value(t, joined, "/bin/claude --b --y --model opus --chrome --x=1")
}

@(test)
test_profile_reset_keeps_enabled_and_clears_overrides :: proc(t: ^testing.T) {
	dir := profile_test_setup(t)
	defer profile_test_teardown(dir)
	off := Provider_Profile_Op_Wire{op = "upsert", profile_id = "claude", body = Provider_Profile_Body_Wire{
		provider = "claude", enabled = false, accent = "#123456", args = []string{"--x"},
	}}
	testing.expect_value(t, profile_op_apply(&off, 1).error, "")
	rst := Provider_Profile_Op_Wire{op = "reset", profile_id = "claude"}
	testing.expect_value(t, profile_op_apply(&rst, 2).error, "")
	_, err := profile_lookup("claude", "")
	testing.expect_value(t, err, Profile_Error.Disabled)
	profiles, _ := profile_list()
	testing.expect_value(t, len(profiles), 1)
	if len(profiles) == 1 do testing.expect(t, profiles[0].accent == "" && len(profiles[0].secret.args) == 0)
	// An enabled default with overrides resets to the implicit default.
	on := Provider_Profile_Op_Wire{op = "upsert", profile_id = "codex", body = Provider_Profile_Body_Wire{provider = "codex", enabled = true, args = []string{"--y"}}}
	testing.expect_value(t, profile_op_apply(&on, 3).error, "")
	rst2 := Provider_Profile_Op_Wire{op = "reset", profile_id = "codex"}
	testing.expect_value(t, profile_op_apply(&rst2, 4).error, "")
	def, derr := profile_lookup("codex", "codex")
	testing.expect_value(t, derr, Profile_Error.None)
	testing.expect_value(t, len(def.secret.args), 0)
}

@(test)
test_profile_paths_normalized_and_empty_args_dropped :: proc(t: ^testing.T) {
	dir := profile_test_setup(t)
	defer profile_test_teardown(dir)
	p := Provider_Profile{profile_id = "claude_n", provider = "claude", enabled = true, secret = Provider_Profile_Secret{
		config_dir = strings.concatenate({dir, "/./a/../cfg-n/"}, context.temp_allocator), args = []string{"", "--keep", ""},
	}}
	testing.expect_value(t, profile_upsert(&p, nil, 1), Profile_Error.None)
	got, _ := profile_lookup("claude", "claude_n")
	testing.expect_value(t, got.secret.config_dir, strings.concatenate({dir, "/cfg-n"}, context.temp_allocator))
	testing.expect_value(t, len(got.secret.args), 1)
	tilde := profile_normalize_path("~/x/../y")
	testing.expect(t, filepath_is_abs_test(tilde) && strings.has_suffix(tilde, "/y") && !strings.contains(tilde, "~"))
	testing.expect_value(t, profile_normalize_path("rel/p"), "rel/p")
}

@(private = "file")
filepath_is_abs_test :: proc(p: string) -> bool {
	return len(p) > 0 && p[0] == '/'
}

@(test)
test_profile_slug_clash_is_reported :: proc(t: ^testing.T) {
	dir := profile_test_setup(t)
	defer profile_test_teardown(dir)
	// "newprov" is not in the catalog yet: a claude profile may use the id.
	p := Provider_Profile{profile_id = "newprov", provider = "claude", enabled = true}
	testing.expect_value(t, profile_upsert(&p, nil, 1), Profile_Error.None)
	// A later catalog adds the slug.
	prev := g_profile_test_catalog
	clash_catalog := [?]string{"claude", "codex", "pi", "copilot", "newprov"}
	g_profile_test_catalog = clash_catalog[:]
	defer g_profile_test_catalog = prev
	_, err := profile_lookup("newprov", "")
	testing.expect_value(t, err, Profile_Error.Slug_Clash)
	report := profile_report_json(context.temp_allocator)
	testing.expect(t, strings.contains(report, `"state":"slug_clash"`))
	// The custom profile itself keeps working.
	_, cerr := profile_lookup("claude", "newprov")
	testing.expect_value(t, cerr, Profile_Error.None)
}

// Golden vector shared with the UI encoder (P3): a fixed key, vault id, epoch and
// nonce over the canonical envelope bytes give this exact token.
PROFILE_GOLDEN_PLAIN :: `{"op":"upsert","profile_id":"claude_k3fq","body":{"provider":"claude","label_enc":"","accent":"#a1b2c3","enabled":true,"binary":"","config_dir":"/home/dev/.claude-work","home_dir":"","env":[{"name":"ANTHROPIC_API_KEY","value":"sk-golden","sensitive":true,"value_redacted":false,"keep":false}],"args":["--chrome"]},"bridge_id":"brg_golden","boot_id":"boot_golden","ts":1793350000000,"nonce":"golden-nonce-000001"}`
PROFILE_GOLDEN_NONCE :: "000102030405060708090a0b"

@(test)
test_profile_op_golden_vector :: proc(t: ^testing.T) {
	kr := test_keyring_from_hex(PROFILE_OP_KEY1, 1)
	defer vault.keyring_wipe(&kr)
	key, _ := vault.keyring_key_for_epoch(&kr, 1)
	nonce: [vault.NONCE_BYTES]byte
	_ = vault.hex_decode_into(nonce[:], PROFILE_GOLDEN_NONCE)
	tok, ok := vault.seal_with_nonce(transmute([]byte)string(PROFILE_GOLDEN_PLAIN), key, kr.vault_id, 1, nonce[:], context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, tok, PROFILE_GOLDEN_TOKEN)
	op, err := profile_op_open(PROFILE_GOLDEN_TOKEN, &kr, "brg_golden", "boot_golden", 1793350000000)
	testing.expect_value(t, err, "")
	testing.expect_value(t, op.op, "upsert")
	testing.expect_value(t, op.profile_id, "claude_k3fq")
	testing.expect_value(t, op.body.provider, "claude")
	testing.expect_value(t, op.body.config_dir, "/home/dev/.claude-work")
	testing.expect(t, len(op.body.env) == 1 && op.body.env[0].name == "ANTHROPIC_API_KEY" && op.body.env[0].sensitive)
	testing.expect(t, len(op.body.args) == 1 && op.body.args[0] == "--chrome")
	testing.expect_value(t, op.nonce, "golden-nonce-000001")
}

PROFILE_GOLDEN_TOKEN :: "vault:v2:c8f193e678e762f9:e1:AAECAwQFBgcICQoLi2nHThjS0rcGWWappqMgpWjB2WNZmReBZMu27bCN2wS5028OfBk3cMCEnUXfIw9PAtYs6yc2EKZUozSZ6yd3gEWqWgTL6XiCF49+9U1uUjeiRQnwZp0F0JL/UYahpN6Y0m22UlMtJ0EN/Ghjz0Y0kNrFSUyPAnZeyvaiVdkgxt87D1Yh5RfckkDdswxvGbs9V5FoB3Ozq4eTE2RnwOdTjuiBVPnSQEAxhAJ+2gu0NmxlpdQfZbnKciCy+afzu70ZvRIiSw9heX+apVft7crUPBTcZfQlcePmE2GoQXytKQlzMuXcympR1Qf/FsN7TT/BY0dkmuARC/dMgLI2wvD+zEuHhDR45K/DF3dEv7gSiijBG6AiNzDbaXMtBr8UkVjqS/n0dJFTa6DvlV19gxWCYuqkWdSdxjCDAji+XCR0Uyhci1DY3ebMXt2Aui7rwOSqy2sFslIuqf1DIX3EOkclfsAYhB5kjKwvwsSzyLlhUoAdzk9BVVKHEQj9lRkUosfhBVFH2eREuRAwSJQ/bO9LLXpLcc6QEy7KUN7kOfNNx16I62Wvkd0Gr8Avjjg="

@(test)
test_profile_record_bound_to_profile_id :: proc(t: ^testing.T) {
	dir := profile_test_setup(t)
	defer profile_test_teardown(dir)
	p := Provider_Profile{profile_id = "claude_a", provider = "claude", enabled = true, secret = Provider_Profile_Secret{env = []Provider_Profile_Env{{name = "K", value = "v-secret", sensitive = true}}}}
	testing.expect_value(t, profile_upsert(&p, nil, 1), Profile_Error.None)
	// Move the sealed blob to another profile id: the embedded binding refuses it.
	raw, _ := os.read_entire_file(g_profile_test_store_path, context.temp_allocator)
	moved, _ := strings.replace_all(string(raw), `"profile_id":"claude_a"`, `"profile_id":"claude_b"`, context.temp_allocator)
	_ = os.write_entire_file(g_profile_test_store_path, transmute([]byte)moved)
	_, err := profile_lookup("claude", "claude_b")
	testing.expect_value(t, err, Profile_Error.Store_Unavailable)
}

@(test)
test_profile_without_secrets_launches_while_locked :: proc(t: ^testing.T) {
	dir := profile_test_setup(t)
	defer profile_test_teardown(dir)
	p := Provider_Profile{profile_id = "codex_p", provider = "codex", enabled = true, secret = Provider_Profile_Secret{
		args = []string{"--x"}, env = []Provider_Profile_Env{{name = "MODE", value = "fast"}},
	}}
	g_profile_test_keyring = nil // no keyring needed without sensitive values
	testing.expect_value(t, profile_upsert(&p, nil, 1), Profile_Error.None)
	got, err := profile_lookup("codex", "codex_p")
	testing.expect_value(t, err, Profile_Error.None)
	testing.expect(t, len(got.secret.args) == 1 && got.secret.env[0].value == "fast")
	s := Provider_Profile{profile_id = "codex_s", provider = "codex", enabled = true, secret = Provider_Profile_Secret{
		env = []Provider_Profile_Env{{name = "TOKEN", value = "t", sensitive = true}},
	}}
	testing.expect_value(t, profile_upsert(&s, nil, 2), Profile_Error.Locked)
	g_profile_test_keyring = &g_profile_test_kr_storage
}
