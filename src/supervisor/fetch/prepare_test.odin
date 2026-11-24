package fetch

// End-to-end tests of prepare_release against a fake instance with an
// installed release: the acceptance cases of T12 (tampered manifest, tampered
// bundle, oversized archive, path-traversal archive) each fail closed and
// leave the installed tree, the `current` pointer and everything outside the
// operation's own scratch space exactly as they were.

import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

INSTALLED_TREE :: "0.5.74-0123456789ab"
NEW_TAG :: "v9.9.9"
NEW_VERSION :: "9.9.9"

// ---------------------------------------------------------------------------
// Fake GitHub

Fake_Asset :: struct {
	url:    string,
	body:   []byte,
	status: int,
}

Fake_GitHub :: struct {
	assets:   [dynamic]Fake_Asset,
	requests: [dynamic]string,
	served:   i64, // bundle bytes accepted by sinks
}

fake_get :: proc(user: rawptr, url: string, sink: Sink) -> int {
	g := (^Fake_GitHub)(user)
	append(&g.requests, strings.clone(url, context.temp_allocator))
	for a in g.assets {
		if a.url != url do continue
		if a.status != 200 do return a.status
		// Deliver in 4 KiB chunks so an aborting sink stops early.
		rest := a.body
		for len(rest) > 0 {
			n := min(len(rest), 4096)
			if !sink.write(sink.user, rest[:n]) do return 0
			g.served += i64(n)
			rest = rest[n:]
		}
		return 200
	}
	return 404
}

fake_put :: proc(g: ^Fake_GitHub, asset: string, body: []byte, status := 200) {
	url, _ := asset_url(NEW_TAG, asset)
	for &a in g.assets {
		if a.url == url {
			a.body, a.status = body, status
			return
		}
	}
	append(&g.assets, Fake_Asset{url = url, body = body, status = status})
}

requested :: proc(g: ^Fake_GitHub, asset: string) -> bool {
	url, _ := asset_url(NEW_TAG, asset)
	return slice.contains(g.requests[:], url)
}

// ---------------------------------------------------------------------------
// Fake instance

Instance :: struct {
	root:     string,
	releases: string,
	snapshot: map[string]string, // relative path -> sha256 (or "dir"/"link:<target>")
	pointer:  string,
}

// snapshot_tree records every file under dir (relative paths).
snapshot_tree :: proc(out: ^map[string]string, base, rel: string) {
	dir := pj(base, rel) if rel != "" else base
	entries, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
	for e in entries {
		r := strings.concatenate({rel, "/", e.name} if rel != "" else {e.name}, context.temp_allocator)
		if e.type == .Directory {
			out[r] = "dir"
			snapshot_tree(out, base, r)
		} else {
			data, _ := read_file(e.fullpath)
			out[r] = sha256_hex(data)
		}
	}
}

read_pointer :: proc(root: string) -> string {
	when ODIN_OS == .Windows {
		data, _ := read_file(pj(root, "current.json"))
		return string(data)
	} else {
		target, err := os.read_link(pj(root, "current"), context.temp_allocator)
		return target if err == nil else ""
	}
}

make_instance :: proc(t: ^testing.T) -> ^Instance {
	inst := new(Instance, context.temp_allocator)
	inst.root = make_test_dir(t)
	inst.releases = pj(inst.root, "releases")
	tree := pj(inst.releases, INSTALLED_TREE)
	testing.expect(t, os.make_directory_all(pj(tree, "bin")) == nil, "mkdir installed")
	write_file(pj(tree, "bin", exe_name("ham-bridge")), transmute([]byte)string("installed runtime"))
	write_file(pj(tree, RELEASE_JSON), transmute([]byte)string(`{"version":"0.5.74"}`))
	write_file(pj(tree, COMPLETE_FILE), transmute([]byte)string("op_installed\n"))
	when ODIN_OS == .Windows {
		write_file(pj(inst.root, "current.json"), transmute([]byte)string(`{"tree":"` + INSTALLED_TREE + `","op_id":"op_installed","seq":1,"crc32":"00000000"}`))
	} else {
		testing.expect(t, os.symlink("releases/" + INSTALLED_TREE, pj(inst.root, "current")) == nil, "symlink current")
	}
	inst.snapshot = make(map[string]string, 16, context.temp_allocator)
	snapshot_tree(&inst.snapshot, inst.releases, INSTALLED_TREE)
	inst.pointer = read_pointer(inst.root)
	testing.expect(t, inst.pointer != "", "pointer readable")
	return inst
}

// expect_installed_untouched: the installed tree and pointer are unchanged,
// and releases/ holds nothing but the installed tree (no staging, no
// half-made tree, no trash).
expect_installed_untouched :: proc(t: ^testing.T, inst: ^Instance, loc := #caller_location) {
	now := make(map[string]string, 16, context.temp_allocator)
	snapshot_tree(&now, inst.releases, INSTALLED_TREE)
	testing.expectf(t, len(now) == len(inst.snapshot), "installed tree entries %d -> %d", len(inst.snapshot), len(now), loc = loc)
	for k, v in inst.snapshot {
		testing.expectf(t, now[k] == v, "installed %s changed", k, loc = loc)
	}
	testing.expectf(t, read_pointer(inst.root) == inst.pointer, "current pointer changed", loc = loc)
	entries, _ := os.read_all_directory_by_path(inst.releases, context.temp_allocator)
	for e in entries {
		testing.expectf(t, e.name == INSTALLED_TREE, "unexpected releases/%s", e.name, loc = loc)
	}
}

// ---------------------------------------------------------------------------
// Signed test releases

fakever_bytes :: proc() -> (data: []byte, ok: bool) {
	if path := os.get_env("HEIMDALL_FETCH_FAKEVER", context.temp_allocator); path != "" {
		return read_file(path)
	}
	when ODIN_OS == .Windows {
		return nil, false
	} else {
		script := `#!/bin/sh
d=$(dirname "$0")
v=$(cat "$d/fakever.txt")
case "$v" in hang) exec sleep 120 ;; fail) exit 3 ;; esac
echo "$(basename "$0") $v"
`
		return transmute([]byte)script, true
	}
}

Release_Opts :: struct {
	version_txt: string, // fakever.txt content; "" = NEW_VERSION
	extra:       []Tar_File, // appended entries
	no_supervisor: bool,
}

BUNDLE_ASSET :: "heimdall-local-" + TARGET + "-" + NEW_TAG + (".zip" when ODIN_OS == .Windows else ".tar.gz")

// make_bundle builds this OS's bundle format: bin/ham-bridge, bin/ham-supervisor
// (the fakever helper), bin/fakever.txt, share/heimdall/extensions/x.json, README.md.
make_bundle :: proc(t: ^testing.T, o: Release_Opts) -> []byte {
	exe, ok := fakever_bytes()
	if !ok {
		exe = transmute([]byte)string("no helper")
	}
	v := o.version_txt if o.version_txt != "" else NEW_VERSION
	files := make([dynamic]Tar_File, context.temp_allocator)
	append(&files, Tar_File{name = "bin/", o = {typeflag = '5', mode = 0o755}})
	append(&files, Tar_File{name = exe_name("bin/ham-bridge"), data = string(exe), o = {mode = 0o755, size = -1}})
	if !o.no_supervisor do append(&files, Tar_File{name = exe_name("bin/ham-supervisor"), data = string(exe), o = {mode = 0o755, size = -1}})
	append(&files, Tar_File{name = "bin/fakever.txt", data = v})
	append(&files, Tar_File{name = "share/heimdall/extensions/x.json", data = "{}"})
	append(&files, Tar_File{name = "README.md", data = "# bundle"})
	for e in o.extra do append(&files, e)
	when ODIN_OS == .Windows {
		zf := make([dynamic]Zip_File, context.temp_allocator)
		for f in files {
			if f.o.typeflag == '5' {
				append(&zf, Zip_File{name = f.name, host = 0, ext_attr = 0x10})
			} else if f.o.typeflag == 0 || f.o.typeflag == '0' {
				append(&zf, Zip_File{name = f.name, data = f.data, deflate = true})
			} else {
				append(&zf, Zip_File{name = f.name, data = f.data, host = 3, ext_attr = 0o120777 << 16}) // links
			}
		}
		return make_zip(zf[:])
	} else {
		return make_tar_gz(files[:])
	}
}

Release :: struct {
	key:       Test_Key,
	bundle:    []byte,
	manifest:  string,
	signature: string,
}

// sign_release signs a manifest naming `bundle` (size, digest) and serves all
// three assets from g.
sign_release :: proc(g: ^Fake_GitHub, bundle: []byte, min_engine := 1) -> ^Release {
	r := new(Release, context.temp_allocator)
	r.key = make_test_key()
	r.bundle = bundle
	r.manifest = manifest_json({tag = NEW_TAG, key_id = r.key.pub.key_id, target = TARGET, asset = BUNDLE_ASSET, size = i64(len(bundle)), sha256 = sha256_hex(bundle), min_engine = min_engine, engine_fields = min_engine >= 1})
	r.signature = minisign_sign(&r.key, transmute([]byte)r.manifest, trusted_comment_for(NEW_TAG, 1000, 2_000_000_000))
	fake_put(g, MANIFEST_ASSET, transmute([]byte)r.manifest)
	fake_put(g, SIGNATURE_ASSET, transmute([]byte)r.signature)
	fake_put(g, BUNDLE_ASSET, bundle)
	return r
}

input_for :: proc(inst: ^Instance, g: ^Fake_GitHub, r: ^Release, op_id := "op_t12") -> Prepare_Input {
	in_ := default_prepare_input()
	in_.instance_root = inst.root
	in_.op_id = op_id
	in_.tag = NEW_TAG
	in_.expected_asset = BUNDLE_ASSET
	in_.downloader = Downloader{get = fake_get, user = g}
	// Slices must outlive this frame: a []T{...} literal would be stack memory.
	pins := make([]Public_Key, 1, context.temp_allocator)
	pins[0] = r.key.pub
	live := make([]string, 1, context.temp_allocator)
	live[0] = INSTALLED_TREE
	in_.verify = Verify_Options{now = 1001, check_expiry = true, pins = pins}
	in_.live = live
	in_.os_policy = Os_Signature_Policy{} // test bundles are unsigned
	in_.preflight_timeout_ms = 5000
	in_.retry = Retry_Policy{budget_ms = 200, first_ms = 1, max_ms = 10, sleep = proc(ms: int) {}}
	return in_
}

new_fake :: proc() -> ^Fake_GitHub {
	g := new(Fake_GitHub, context.temp_allocator)
	g.assets = make([dynamic]Fake_Asset, context.temp_allocator)
	g.requests = make([dynamic]string, context.temp_allocator)
	return g
}

have_helper :: proc(t: ^testing.T) -> bool {
	_, ok := fakever_bytes()
	if !ok do log.warnf( "HEIMDALL_FETCH_FAKEVER not set: preflight success paths skipped on this OS")
	return ok
}

// ---------------------------------------------------------------------------
// Tests

@(test)
test_prepare_installs_a_valid_tree :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	if !have_helper(t) do return
	inst := make_instance(t)
	defer os.remove_all(inst.root)
	g := new_fake()
	r := sign_release(g, make_bundle(t, {}))

	p, err := prepare_release(input_for(inst, g, r), context.temp_allocator)
	testing.expectf(t, err == nil, "prepare: %v", err)
	want_tree := strings.concatenate({NEW_VERSION, "-", sha256_hex(r.bundle)[:12]}, context.temp_allocator)
	testing.expect_value(t, p.tree, want_tree)
	testing.expect(t, !p.reused, "fresh install")
	tree := pj(inst.releases, p.tree)
	testing.expect(t, os.exists(pj(tree, COMPLETE_FILE)), ".complete")
	rel, _ := read_file(pj(tree, RELEASE_JSON))
	testing.expect(t, string(rel) == r.manifest, "release.json is the signed manifest, byte for byte")
	sig, _ := read_file(pj(tree, RELEASE_SIG))
	testing.expect(t, string(sig) == r.signature, "release.json.minisig")
	testing.expect(t, tree_check_sizes(tree) == nil, "tree.json matches")
	testing.expect(t, tree_intact(tree, &p.manifest), "tree intact")
	entries, ok := read_tree_json(tree)
	testing.expect(t, ok && len(entries) == 7, "tree.json lists 5 bundle files + release.json + signature")
	testing.expect(t, os.exists(pj(tree, "bin", exe_name("ham-bridge"))), "bin/ham-bridge")
	testing.expect(t, os.exists(pj(tree, "share", "heimdall", "extensions", "x.json")), "extensions")
	testing.expect(t, !os.exists(pj(inst.releases, ".staging-op_t12")), "staging renamed away")
	testing.expect(t, os.exists(pj(inst.root, "supervisor", "downloads", "op_t12", BUNDLE_ASSET)), "bundle kept for J6")
	testing.expect(t, !os.exists(pj(inst.root, "supervisor", "downloads", "op_t12", BUNDLE_ASSET + ".part")), "no .part")
	// The installed release is untouched (the new tree is the only addition).
	now := make(map[string]string, 16, context.temp_allocator)
	snapshot_tree(&now, inst.releases, INSTALLED_TREE)
	for k, v in inst.snapshot do testing.expectf(t, now[k] == v, "installed %s changed", k)
	testing.expect(t, read_pointer(inst.root) == inst.pointer, "pointer untouched")

	// J5: the same release again is reused without downloading the bundle.
	clear(&g.requests)
	p2, err2 := prepare_release(input_for(inst, g, r, "op_t12_again"), context.temp_allocator)
	testing.expectf(t, err2 == nil, "again: %v", err2)
	testing.expect(t, p2.reused && p2.tree == p.tree, "reused")
	testing.expect(t, !requested(g, BUNDLE_ASSET), "bundle not downloaded again")
}

@(test)
test_tampered_manifest_leaves_installed_running :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	inst := make_instance(t)
	defer os.remove_all(inst.root)
	g := new_fake()
	r := sign_release(g, make_bundle(t, {}))
	// Change the bundle digest in the served manifest (an attacker pointing
	// at other bytes); the signature no longer verifies.
	other := sha256_hex(transmute([]byte)string("evil"))
	tampered, _ := strings.replace(r.manifest, sha256_hex(r.bundle), other, 1, context.temp_allocator)
	fake_put(g, MANIFEST_ASSET, transmute([]byte)tampered)
	_, err := prepare_release(input_for(inst, g, r), context.temp_allocator)
	expect_code(t, err, .Signature_Invalid)
	testing.expect(t, !requested(g, BUNDLE_ASSET), "bundle never downloaded")
	expect_installed_untouched(t, inst)

	// Tampered trusted comment, unpinned key, missing signature.
	fake_put(g, MANIFEST_ASSET, transmute([]byte)r.manifest)
	sig2, _ := strings.replace(r.signature, "2000000000", "2100000000", 1, context.temp_allocator)
	fake_put(g, SIGNATURE_ASSET, transmute([]byte)sig2)
	_, err = prepare_release(input_for(inst, g, r), context.temp_allocator)
	expect_code(t, err, .Signature_Invalid)
	expect_installed_untouched(t, inst)

	fake_put(g, SIGNATURE_ASSET, transmute([]byte)r.signature)
	in_ := input_for(inst, g, r)
	in_.verify.pins = nil // the embedded release keys
	_, err = prepare_release(in_, context.temp_allocator)
	expect_code(t, err, .Key_Unpinned)
	expect_installed_untouched(t, inst)

	fake_put(g, SIGNATURE_ASSET, nil, 404)
	_, err = prepare_release(input_for(inst, g, r), context.temp_allocator)
	expect_code(t, err, .Download_Failed)
	expect_installed_untouched(t, inst)

	// An oversized manifest is cut off at 1 MiB.
	fake_put(g, SIGNATURE_ASSET, transmute([]byte)r.signature)
	fake_put(g, MANIFEST_ASSET, make([]byte, MAX_MANIFEST_BYTES + 10, context.temp_allocator))
	_, err = prepare_release(input_for(inst, g, r), context.temp_allocator)
	expect_code(t, err, .Download_Failed)
	expect_installed_untouched(t, inst)
}

@(test)
test_tampered_bundle_leaves_installed_running :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	inst := make_instance(t)
	defer os.remove_all(inst.root)
	g := new_fake()
	r := sign_release(g, make_bundle(t, {}))
	part := pj(inst.root, "supervisor", "downloads", "op_t12", BUNDLE_ASSET + ".part")

	// Same size, one byte different.
	evil := slice.clone(r.bundle, context.temp_allocator)
	evil[len(evil) / 2] ~= 0xff
	fake_put(g, BUNDLE_ASSET, evil)
	_, err := prepare_release(input_for(inst, g, r), context.temp_allocator)
	expect_code(t, err, .Bundle_Mismatch)
	testing.expect(t, !os.exists(part), ".part deleted")
	expect_installed_untouched(t, inst)

	// Truncated.
	fake_put(g, BUNDLE_ASSET, r.bundle[:len(r.bundle) - 1])
	_, err = prepare_release(input_for(inst, g, r), context.temp_allocator)
	expect_code(t, err, .Bundle_Mismatch)
	expect_installed_untouched(t, inst)

	// Larger than the manifest says: the download stops right at the limit.
	big := make([]byte, len(r.bundle) + 1 << 20, context.temp_allocator)
	copy(big, r.bundle)
	fake_put(g, BUNDLE_ASSET, big)
	g.served = 0
	_, err = prepare_release(input_for(inst, g, r), context.temp_allocator)
	expect_code(t, err, .Bundle_Mismatch)
	testing.expectf(t, g.served <= i64(len(r.bundle)), "accepted %d bytes of a %d-byte bundle", g.served, len(r.bundle))
	testing.expect(t, !os.exists(part), ".part deleted")
	expect_installed_untouched(t, inst)

	// HTTP error.
	fake_put(g, BUNDLE_ASSET, nil, 503)
	_, err = prepare_release(input_for(inst, g, r), context.temp_allocator)
	expect_code(t, err, .Download_Failed)
	expect_installed_untouched(t, inst)
}

@(test)
test_oversized_archive_leaves_installed_running :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	inst := make_instance(t)
	defer os.remove_all(inst.root)
	g := new_fake()
	// A validly signed bundle that inflates past the limit (the limit is
	// lowered so the test stays fast; the 512 MiB default is exercised in
	// test_oversized_archives_are_refused).
	big := strings.repeat("A", 300 * 1024, context.temp_allocator)
	r := sign_release(g, make_bundle(t, {extra = []Tar_File{{name = "share/big.bin", data = big}}}))
	in_ := input_for(inst, g, r)
	in_.limits = Limits{max_bytes = 256 * 1024, max_entries = 100}
	_, err := prepare_release(in_, context.temp_allocator)
	expect_code(t, err, .Archive_Unsafe)
	expect_installed_untouched(t, inst)

	// Too many entries.
	many := make([dynamic]Tar_File, context.temp_allocator)
	for i in 0 ..< 20 do append(&many, Tar_File{name = fmt.tprintf("share/f%d", i), data = "x"})
	r2 := sign_release(g, make_bundle(t, {extra = many[:]}))
	in2 := input_for(inst, g, r2)
	in2.limits = Limits{max_bytes = 1 << 30, max_entries = 10}
	_, err = prepare_release(in2, context.temp_allocator)
	expect_code(t, err, .Archive_Unsafe)
	expect_installed_untouched(t, inst)
}

@(test)
test_path_traversal_archive_leaves_installed_running :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	inst := make_instance(t)
	defer os.remove_all(inst.root)
	g := new_fake()
	cases := [][]Tar_File {
		{{name = "../" + INSTALLED_TREE + "/bin/ham-bridge", data = "overwrite the installed runtime"}},
		{{name = "../../current", data = "repoint"}},
		{{name = "bin/../../escape", data = "x"}},
		{{name = "share/link", o = {typeflag = '2', size = -1}}},
		{{name = ".complete", data = "pretend valid"}},
	}
	for extra in cases {
		r := sign_release(g, make_bundle(t, {extra = extra}))
		_, err := prepare_release(input_for(inst, g, r), context.temp_allocator)
		expect_code(t, err, .Archive_Unsafe)
		expect_installed_untouched(t, inst)
		testing.expect(t, !os.exists(pj(inst.root, "escape")), "nothing escaped")
	}
}

@(test)
test_eligibility_runs_before_download :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	inst := make_instance(t)
	defer os.remove_all(inst.root)
	g := new_fake()
	r := sign_release(g, make_bundle(t, {}))
	in_ := input_for(inst, g, r)
	in_.eligible = proc(user: rawptr, m: ^Manifest) -> Error {
		return fail(.Manifest_Incomplete, "engine says no (%s)", m.version)
	}
	_, err := prepare_release(in_, context.temp_allocator)
	expect_code(t, err, .Manifest_Incomplete)
	testing.expect(t, !requested(g, BUNDLE_ASSET), "bundle not downloaded")
	expect_installed_untouched(t, inst)
	// §13.4 inside the manifest itself: min_engine 1 without engine fields.
	g2 := new_fake()
	r2 := sign_release(g2, make_bundle(t, {}), 1)
	incomplete := manifest_json({tag = NEW_TAG, key_id = r2.key.pub.key_id, target = TARGET, asset = BUNDLE_ASSET, size = i64(len(r2.bundle)), sha256 = sha256_hex(r2.bundle), min_engine = 1})
	fake_put(g2, MANIFEST_ASSET, transmute([]byte)incomplete)
	fake_put(g2, SIGNATURE_ASSET, transmute([]byte)minisign_sign(&r2.key, transmute([]byte)incomplete, trusted_comment_for(NEW_TAG, 1000, 2_000_000_000)))
	_, err = prepare_release(input_for(inst, g2, r2), context.temp_allocator)
	expect_code(t, err, .Manifest_Incomplete)
	expect_installed_untouched(t, inst)
}

@(test)
test_preflight_failures_remove_the_new_tree :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	if !have_helper(t) do return
	inst := make_instance(t)
	defer os.remove_all(inst.root)
	g := new_fake()
	cases := []struct {
		o:       Release_Opts,
		timeout: int,
	}{{{version_txt = "1.0.0"}, 5000}, {{version_txt = "9.9.90"}, 5000}, {{version_txt = "fail"}, 5000}, {{no_supervisor = true}, 5000}, {{version_txt = "hang"}, 1500}}
	for c in cases {
		r := sign_release(g, make_bundle(t, c.o))
		in_ := input_for(inst, g, r)
		in_.preflight_timeout_ms = c.timeout
		_, err := prepare_release(in_, context.temp_allocator)
		expect_code(t, err, .Preflight_Failed)
		// The tree without .complete was deleted again: on Windows this also
		// proves the killed process no longer held its executable open.
		expect_installed_untouched(t, inst)
	}
}

@(test)
test_tree_name_choice :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	if !have_helper(t) do return
	inst := make_instance(t)
	defer os.remove_all(inst.root)
	g := new_fake()
	r := sign_release(g, make_bundle(t, {}))
	base := strings.concatenate({NEW_VERSION, "-", sha256_hex(r.bundle)[:12]}, context.temp_allocator)

	// A damaged, non-live tree with the base name is replaced.
	testing.expect(t, os.make_directory_all(pj(inst.releases, base, "bin")) == nil, "mkdir")
	write_file(pj(inst.releases, base, "junk"), transmute([]byte)string("half a tree"))
	p, err := prepare_release(input_for(inst, g, r, "op_a"), context.temp_allocator)
	testing.expectf(t, err == nil && p.tree == base && !p.reused, "replace damaged: %v %s", err, p.tree)
	testing.expect(t, !os.exists(pj(inst.releases, base, "junk")), "damaged content gone")

	// Damage it (truncate a file) while it is live: repair goes to -r1, then -r2.
	write_file(pj(inst.releases, base, "README.md"), transmute([]byte)string("#"))
	testing.expect(t, error_code(tree_check_sizes(pj(inst.releases, base))) == .Tree_Damaged, "damage detected")
	in_ := input_for(inst, g, r, "op_b")
	in_.live = []string{INSTALLED_TREE, base}
	p2, err2 := prepare_release(in_, context.temp_allocator)
	testing.expectf(t, err2 == nil && p2.tree == strings.concatenate({base, "-r1"}, context.temp_allocator), "repair r1: %v %s", err2, p2.tree)
	testing.expect(t, os.exists(pj(inst.releases, base, "README.md")), "live damaged tree left alone (W1)")
	in_.op_id = "op_c"
	p3, err3 := prepare_release(in_, context.temp_allocator)
	testing.expectf(t, err3 == nil && p3.tree == strings.concatenate({base, "-r2"}, context.temp_allocator), "repair r2: %v %s", err3, p3.tree)
}

@(test)
test_staging_rename_retries_sharing_violations :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	@(static) failures_left: int
	busy :: proc() -> os.Error {
		when ODIN_OS == .Windows {
			return os.Platform_Error(32) // ERROR_SHARING_VIOLATION
		} else {
			return os.Platform_Error(16) // EBUSY
		}
	}
	flaky :: proc(a, b: string) -> os.Error {
		if failures_left > 0 {
			failures_left -= 1
			return busy()
		}
		return os.rename(a, b)
	}
	dir := make_test_dir(t)
	defer os.remove_all(dir)
	write_file(pj(dir, "a"), transmute([]byte)string("x"))
	slept := 0
	@(static) slept_ptr: ^int
	slept_ptr = &slept
	policy := Retry_Policy{budget_ms = 60_000, first_ms = 100, max_ms = 2000, rename = flaky, sleep = proc(ms: int) {slept_ptr^ += ms}}
	failures_left = 5
	testing.expect(t, rename_with_retry(pj(dir, "a"), pj(dir, "b"), policy) == nil, "renamed after 5 busy errors")
	testing.expect_value(t, slept, 100 + 200 + 400 + 800 + 1600)
	// Exhausted: fs_busy after the 60 s budget, source left in place.
	failures_left = 1 << 30
	slept = 0
	err := rename_with_retry(pj(dir, "b"), pj(dir, "c"), policy)
	expect_code(t, err, .Fs_Busy)
	testing.expect_value(t, slept, 60_000)
	testing.expect(t, os.exists(pj(dir, "b")), "source kept")
	// Other errors are not retried.
	err = rename_with_retry(pj(dir, "missing"), pj(dir, "d"), DEFAULT_RETRY)
	expect_code(t, err, .Fs_Error)
}

@(test)
test_repair_from_local_files :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	if !have_helper(t) do return
	inst := make_instance(t)
	defer os.remove_all(inst.root)
	g := new_fake()
	r := sign_release(g, make_bundle(t, {}))
	dir := make_test_dir(t)
	defer os.remove_all(dir)
	write_file(pj(dir, "m.json"), transmute([]byte)r.manifest)
	write_file(pj(dir, "m.minisig"), transmute([]byte)r.signature)
	write_file(pj(dir, BUNDLE_ASSET), r.bundle)
	in_ := input_for(inst, g, r)
	in_.downloader = {}
	in_.local = Local_Release{pj(dir, "m.json"), pj(dir, "m.minisig"), pj(dir, BUNDLE_ASSET)}
	in_.verify.check_expiry = false
	p, err := prepare_release(in_, context.temp_allocator)
	testing.expectf(t, err == nil && !p.reused, "local: %v", err)
	testing.expect(t, len(g.requests) == 0, "no network")
	// A tampered local bundle is refused like a downloaded one.
	evil := slice.clone(r.bundle, context.temp_allocator)
	evil[10] ~= 1
	write_file(pj(dir, BUNDLE_ASSET), evil)
	testing.expect(t, p.tree != "", "tree name")
	if p.tree != "" do os.remove_all(pj(inst.releases, p.tree))
	in_.op_id = "op_t12_evil"
	_, err = prepare_release(in_, context.temp_allocator)
	expect_code(t, err, .Bundle_Mismatch)
	expect_installed_untouched(t, inst)
}

@(test)
test_contains_version :: proc(t: ^testing.T) {
	testing.expect(t, contains_version("ham-bridge 9.9.9\n", "9.9.9"), "plain")
	testing.expect(t, contains_version("ham-bridge v9.9.9 (abc)", "9.9.9"), "v prefix")
	testing.expect(t, contains_version("version 9.9.9.", "9.9.9"), "sentence end")
	testing.expect(t, !contains_version("ham-bridge 9.9.90", "9.9.9"), "longer patch")
	testing.expect(t, !contains_version("ham-bridge 19.9.9", "9.9.9"), "longer major")
	testing.expect(t, !contains_version("ham-bridge 9.9.9-rc.1", "9.9.9"), "prerelease of it")
	testing.expect(t, contains_version("x 9.9.9-rc.1", "9.9.9-rc.1"), "prerelease")
}
