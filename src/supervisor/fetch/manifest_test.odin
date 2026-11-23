package fetch

import "core:encoding/json"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

// Fixture made with the real tools (scripts/release/release-manifest.py
// generate + trusted-comment --now 1795000000, then `minisign -S` with an
// ephemeral key whose secret was destroyed). It names testdata/gnu.tar.gz as
// linux-amd64 and testdata/py.zip as windows-amd64.
FIXTURE_MANIFEST :: #load("testdata/minisign-manifest.json")
FIXTURE_SIGNATURE :: #load("testdata/minisign-manifest.json.minisig")
FIXTURE_PUB :: #load("testdata/minisign-test.pub", string)
FIXTURE_SEQ :: 1795000000
FIXTURE_EXPIRES :: 1826536000

fixture_pins :: proc() -> []Public_Key {
	k, err := parse_public_key(FIXTURE_PUB)
	assert(err == nil)
	out := make([]Public_Key, 1, context.temp_allocator)
	out[0] = k
	return out
}

@(test)
test_real_minisign_signature_verifies :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	m, err := verify_manifest(FIXTURE_MANIFEST, FIXTURE_SIGNATURE, {target = "linux-amd64", now = FIXTURE_SEQ + 1, check_expiry = true, pins = fixture_pins(), expected_tag = "v9.8.7", expected_asset = "heimdall-local-linux-amd64-v9.8.7.tar.gz"}, context.temp_allocator)
	testing.expectf(t, err == nil, "verify: %v", err)
	testing.expect_value(t, m.tag, "v9.8.7")
	testing.expect_value(t, m.version, "9.8.7")
	testing.expect_value(t, m.key_id, "0391DF15D7F94F47")
	testing.expect_value(t, m.size, 42610)
	testing.expect_value(t, m.sha256, "486b24468f472248fc8e14d4b0b0098ecab83cd7a292fb1ab67d7e226e154e82")
	testing.expect_value(t, m.seq, FIXTURE_SEQ)
	testing.expect_value(t, m.expires, FIXTURE_EXPIRES)
	testing.expect_value(t, m.min_engine, 0)
	testing.expect_value(t, m.state_schema, -1)
	testing.expect(t, slice.equal(m.raw, FIXTURE_MANIFEST), "raw bytes kept")
	testing.expect(t, slice.equal(m.signature, FIXTURE_SIGNATURE), "signature bytes kept")

	w, werr := verify_manifest(FIXTURE_MANIFEST, FIXTURE_SIGNATURE, {target = "windows-amd64", now = FIXTURE_SEQ, check_expiry = true, pins = fixture_pins()}, context.temp_allocator)
	testing.expectf(t, werr == nil, "windows target: %v", werr)
	testing.expect_value(t, w.asset, "heimdall-local-windows-amd64-v9.8.7.zip")
}

expect_code :: proc(t: ^testing.T, err: Error, want: Code, loc := #caller_location) {
	testing.expectf(t, error_code(err) == want, "want %v, got %v (%s)", want, error_code(err), error_detail(err), loc = loc)
}

@(test)
test_expiry_applies_to_new_candidates_only :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	_, err := verify_manifest(FIXTURE_MANIFEST, FIXTURE_SIGNATURE, {target = "linux-amd64", now = FIXTURE_EXPIRES, check_expiry = true, pins = fixture_pins()}, context.temp_allocator)
	expect_code(t, err, .Manifest_Expired)
	_, err2 := verify_manifest(FIXTURE_MANIFEST, FIXTURE_SIGNATURE, {target = "linux-amd64", now = FIXTURE_EXPIRES + 1000, check_expiry = false, pins = fixture_pins()}, context.temp_allocator)
	testing.expectf(t, err2 == nil, "installed tree, no expiry check: %v", err2)
}

@(test)
test_unpinned_key_is_refused :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	// Default pins = the embedded release keys; the fixture key is not one.
	_, err := verify_manifest(FIXTURE_MANIFEST, FIXTURE_SIGNATURE, {target = "linux-amd64", now = FIXTURE_SEQ}, context.temp_allocator)
	expect_code(t, err, .Key_Unpinned)
	other := make_test_key()
	_, err2 := verify_manifest(FIXTURE_MANIFEST, FIXTURE_SIGNATURE, {target = "linux-amd64", now = FIXTURE_SEQ, pins = []Public_Key{other.pub}}, context.temp_allocator)
	expect_code(t, err2, .Key_Unpinned)
}

@(test)
test_tampered_manifest_and_signature_are_refused :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	pins := fixture_pins()
	opts := Verify_Options{target = "linux-amd64", now = FIXTURE_SEQ, pins = pins}

	// One byte of the manifest: the bundle size.
	m := strings.clone(string(FIXTURE_MANIFEST), context.temp_allocator)
	tampered, n := strings.replace(m, `"size":42610`, `"size":42611`, 1, context.temp_allocator)
	testing.expect(t, n, "size replaced")
	_, err := verify_manifest(transmute([]byte)tampered, FIXTURE_SIGNATURE, opts, context.temp_allocator)
	expect_code(t, err, .Signature_Invalid)

	// A different digest.
	tampered2, _ := strings.replace(m, "486b2446", "486b2447", 1, context.temp_allocator)
	_, err = verify_manifest(transmute([]byte)tampered2, FIXTURE_SIGNATURE, opts, context.temp_allocator)
	expect_code(t, err, .Signature_Invalid)

	// Truncated manifest.
	short := FIXTURE_MANIFEST
	_, err = verify_manifest(short[:len(short) - 1], FIXTURE_SIGNATURE, opts, context.temp_allocator)
	expect_code(t, err, .Signature_Invalid)

	// Trusted comment pushed out (freeze attack): global signature fails.
	sig := string(FIXTURE_SIGNATURE)
	sig2, n2 := strings.replace(sig, "1826536000", "1926536000", 1, context.temp_allocator)
	testing.expect(t, n2, "expires replaced")
	_, err = verify_manifest(FIXTURE_MANIFEST, transmute([]byte)sig2, opts, context.temp_allocator)
	expect_code(t, err, .Signature_Invalid)

	// Garbage and empty signatures.
	_, err = verify_manifest(FIXTURE_MANIFEST, transmute([]byte)string("nope\n"), opts, context.temp_allocator)
	expect_code(t, err, .Signature_Invalid)
	_, err = verify_manifest(FIXTURE_MANIFEST, nil, opts, context.temp_allocator)
	expect_code(t, err, .Signature_Invalid)

	// Oversized inputs are refused before parsing.
	big := make([]byte, MAX_MANIFEST_BYTES + 1, context.temp_allocator)
	_, err = verify_manifest(big, FIXTURE_SIGNATURE, opts, context.temp_allocator)
	expect_code(t, err, .Manifest_Invalid)
}

@(test)
test_legacy_non_prehashed_signature_is_refused :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	k := make_test_key()
	man := manifest_json({tag = "v1.2.3", key_id = k.pub.key_id, target = "linux-amd64", asset = "b.tar.gz", size = 1, sha256 = strings.repeat("a", 64, context.temp_allocator)})
	sig := minisign_sign(&k, transmute([]byte)man, trusted_comment_for("v1.2.3", 1, 100))
	// Flip "ED" to "Ed": base64 of 0x45 0x44 starts "RU", of 0x45 0x64 "RW";
	// the third character depends only on the next byte, so it is kept.
	lines := strings.split(sig, "\n", context.temp_allocator)
	testing.expect(t, strings.has_prefix(lines[1], "RU"), "prehashed prefix")
	_, err := verify_manifest(transmute([]byte)man, transmute([]byte)sig, {target = "linux-amd64", now = 2, pins = []Public_Key{k.pub}}, context.temp_allocator)
	testing.expectf(t, err == nil, "own signature verifies: %v", err)
	lines[1] = strings.concatenate({"RW", lines[1][2:]}, context.temp_allocator) // "Ed"
	legacy := strings.join(lines, "\n", context.temp_allocator)
	_, err = verify_manifest(transmute([]byte)man, transmute([]byte)legacy, {target = "linux-amd64", now = 2, pins = []Public_Key{k.pub}}, context.temp_allocator)
	expect_code(t, err, .Signature_Invalid)
}

sign_and_verify :: proc(k: ^Test_Key, man, comment: string, opts: Verify_Options) -> (Manifest, Error) {
	sig := minisign_sign(k, transmute([]byte)man, comment)
	o := opts
	o.pins = []Public_Key{k.pub}
	if o.target == "" do o.target = "linux-amd64"
	return verify_manifest(transmute([]byte)man, transmute([]byte)sig, o, context.temp_allocator)
}

@(test)
test_validly_signed_but_bad_manifests_are_refused :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	k := make_test_key()
	digest := strings.repeat("c", 64, context.temp_allocator)
	spec := Manifest_Spec{tag = "v1.2.3", key_id = k.pub.key_id, target = "linux-amd64", asset = "b.tar.gz", size = 10, sha256 = digest}
	good := manifest_json(spec)
	tc := trusted_comment_for("v1.2.3", 5, 1000)

	_, err := sign_and_verify(&k, good, tc, {now = 6, check_expiry = true})
	testing.expectf(t, err == nil, "good: %v", err)

	// Not canonical: whitespace, missing LF, key order.
	spaced, _ := strings.replace(good, `"schema":1`, `"schema": 1`, 1, context.temp_allocator)
	_, err = sign_and_verify(&k, spaced, tc, {now = 6})
	expect_code(t, err, .Manifest_Invalid)
	_, err = sign_and_verify(&k, strings.trim_suffix(good, "\n"), tc, {now = 6})
	expect_code(t, err, .Manifest_Invalid)
	reordered := strings.concatenate({`{"journal_schema":0,"commit":"`, strings.repeat("ab", 20, context.temp_allocator), `",`, good[len(`{"commit":"`) + 40 + 2 + len(`"journal_schema":0,`):]}, context.temp_allocator)
	_, err = sign_and_verify(&k, reordered, tc, {now = 6})
	expect_code(t, err, .Manifest_Invalid)

	// key_id is not the signing key.
	other := make_test_key()
	wrong_key := manifest_json({tag = "v1.2.3", key_id = other.pub.key_id, target = "linux-amd64", asset = "b.tar.gz", size = 10, sha256 = digest})
	_, err = sign_and_verify(&k, wrong_key, tc, {now = 6})
	expect_code(t, err, .Manifest_Invalid)

	// Trusted comment names another tag, or lacks seq/expires.
	_, err = sign_and_verify(&k, good, trusted_comment_for("v1.2.4", 5, 1000), {now = 6})
	expect_code(t, err, .Manifest_Invalid)
	_, err = sign_and_verify(&k, good, `{"version":"v1.2.3","seq":5}`, {now = 6})
	expect_code(t, err, .Manifest_Invalid)
	_, err = sign_and_verify(&k, good, `{"expires":1000.5,"seq":5,"version":"v1.2.3"}`, {now = 6})
	expect_code(t, err, .Manifest_Invalid)
	_, err = sign_and_verify(&k, good, `not json`, {now = 6})
	expect_code(t, err, .Manifest_Invalid)

	// Shape: bad tag, version, digest, asset path.
	bad_specs := []Manifest_Spec {
		{tag = "v1.2", key_id = k.pub.key_id, target = "linux-amd64", asset = "b.tar.gz", size = 10, sha256 = digest},
		{tag = "v01.2.3", key_id = k.pub.key_id, target = "linux-amd64", asset = "b.tar.gz", size = 10, sha256 = digest},
		{tag = "v1.2.3", key_id = k.pub.key_id, target = "linux-amd64", asset = "../b.tar.gz", size = 10, sha256 = digest},
		{tag = "v1.2.3", key_id = k.pub.key_id, target = "linux-amd64", asset = "b.tar.gz", size = -1, sha256 = digest},
		{tag = "v1.2.3", key_id = k.pub.key_id, target = "linux-amd64", asset = "b.tar.gz", size = 10, sha256 = strings.repeat("C", 64, context.temp_allocator)},
		{tag = "v1.2.3", key_id = k.pub.key_id, target = "Linux_amd64", asset = "b.tar.gz", size = 10, sha256 = digest},
	}
	for s in bad_specs {
		_, err = sign_and_verify(&k, manifest_json(s), trusted_comment_for(s.tag, 5, 1000), {now = 6})
		expect_code(t, err, .Manifest_Invalid)
	}
}

@(test)
test_manifest_must_match_the_release :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	k := make_test_key()
	digest := strings.repeat("c", 64, context.temp_allocator)
	man := manifest_json({tag = "v1.2.3", key_id = k.pub.key_id, target = "linux-amd64", asset = "b.tar.gz", size = 10, sha256 = digest})
	tc := trusted_comment_for("v1.2.3", 5, 1000)
	_, err := sign_and_verify(&k, man, tc, {now = 6, expected_tag = "v1.2.4"})
	expect_code(t, err, .Manifest_Mismatch)
	_, err = sign_and_verify(&k, man, tc, {now = 6, expected_asset = "c.tar.gz"})
	expect_code(t, err, .Manifest_Mismatch)
	_, err = sign_and_verify(&k, man, tc, {now = 6, target = "darwin-arm64"})
	expect_code(t, err, .Manifest_Mismatch)
}

@(test)
test_engine_fields_required_once_min_engine_is_set :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	k := make_test_key()
	digest := strings.repeat("c", 64, context.temp_allocator)
	tc := trusted_comment_for("v1.2.3", 5, 1000)
	incomplete := manifest_json({tag = "v1.2.3", key_id = k.pub.key_id, target = "linux-amd64", asset = "b.tar.gz", size = 10, sha256 = digest, min_engine = 1})
	_, err := sign_and_verify(&k, incomplete, tc, {now = 6})
	expect_code(t, err, .Manifest_Incomplete)
	complete := manifest_json({tag = "v1.2.3", key_id = k.pub.key_id, target = "linux-amd64", asset = "b.tar.gz", size = 10, sha256 = digest, min_engine = 1, engine_fields = true})
	m, err2 := sign_and_verify(&k, complete, tc, {now = 6})
	testing.expectf(t, err2 == nil, "complete: %v", err2)
	testing.expect_value(t, m.min_engine, 1)
	testing.expect_value(t, m.journal_schema, 1)
	testing.expect_value(t, m.state_schema, 1)
	testing.expect_value(t, m.state_compat_min, 1)
	testing.expect_value(t, m.min_launcher_abi, 1)
}

@(test)
test_canonical_json_matches_python :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	// python3 -c 'import json; print(json.dumps({"k":"é☃😀\x01\"\\/\x7f","a":[1,True,None,-5],"B":{}},
	//   sort_keys=True, separators=(",",":"), ensure_ascii=True))'
	want := `{"B":{},"a":[1,true,null,-5],"k":"\u00e9\u2603\ud83d\ude00\u0001\"\\/\u007f"}` + "\n"
	v, err := json.parse_string(want, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	testing.expect(t, err == nil, "parse")
	got, ok := canonical_json(v)
	testing.expect(t, ok, "canonical")
	testing.expect_value(t, got, want)
	// The real fixture is canonical as published.
	v2, _ := json.parse(FIXTURE_MANIFEST, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	got2, _ := canonical_json(v2)
	testing.expect_value(t, got2, string(FIXTURE_MANIFEST))
	// Floats never are.
	v3, _ := json.parse_string(`{"a":1.0}`, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	_, ok3 := canonical_json(v3)
	testing.expect(t, !ok3, "float refused")
}

@(test)
test_embedded_pins_match_the_key_directory :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	dir := pj(#directory, "..", "..", "..", "scripts", "release", "minisign")
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	testing.expectf(t, err == nil, "read %s: %v", dir, err)
	on_disk := make([dynamic]string, context.temp_allocator)
	for e in entries {
		if !strings.has_suffix(e.name, ".pub") do continue
		data, ok := read_file(e.fullpath)
		testing.expect(t, ok, "read pub")
		k, perr := parse_public_key(string(data))
		testing.expectf(t, perr == nil, "%s: %v", e.name, perr)
		append(&on_disk, k.key_id)
	}
	pins, perr := pinned_keys()
	testing.expect(t, perr == nil, "pinned_keys")
	embedded := make([dynamic]string, context.temp_allocator)
	for p in pins do append(&embedded, p.key_id)
	slice.sort(on_disk[:])
	slice.sort(embedded[:])
	testing.expectf(t, slice.equal(on_disk[:], embedded[:]), "embedded pins %v, key directory %v", embedded, on_disk)
	// docs/release-signing.md slot table.
	testing.expect(t, slice.contains(embedded[:], "F0C12EB5F62E8C66"), "current key pinned")
	testing.expect(t, slice.contains(embedded[:], "7D1CD02AE0E7D223"), "next key pinned")
}

@(test)
test_valid_tag :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	for good in ([]string{"v0.0.0", "v1.2.3", "v10.20.30", "v1.2.3-rc.1", "v1.2.3-a-b.c"}) {
		testing.expectf(t, valid_tag(good), "%s valid", good)
	}
	for bad in ([]string{"1.2.3", "v1.2", "v1.2.3.4", "v01.2.3", "v1.02.3", "v1.2.3-", "v1.2.3+b", "v1.2.3-r_c", "v-1.2.3", "v1..3"}) {
		testing.expectf(t, !valid_tag(bad), "%s invalid", bad)
	}
}
