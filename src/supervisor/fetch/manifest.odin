package fetch

// Release manifest verification, spec §14 steps 1-4, with the rules of
// docs/release-signing.md (the same checks as
// scripts/release/release-manifest.py verify, which is the reference):
//
//   1. size caps (1 MiB each) are enforced by the caller's download;
//   2. the signature's key id is pinned in this build (key_unpinned);
//   3. minisign verify: Ed25519 over BLAKE2b-512(manifest) ("ED", prehashed;
//      the legacy non-prehashed "Ed" form is refused), then the global
//      signature over signature || trusted comment (signature_invalid);
//   4. the manifest is canonical JSON (sorted keys, no whitespace, ASCII
//      escapes, trailing LF), schema 1, its key_id is the signing key, the
//      trusted comment names its tag, and `expires` has not passed when the
//      caller checks expiry (new candidates only; installed trees are never
//      re-checked, so rollback works offline and late).
//
// Plus §13.1 (manifest_mismatch against the GitHub release) and §13.4
// (manifest_incomplete when min_engine >= 1 lacks an engine field).

import "core:crypto/blake2b"
import "core:crypto/ed25519"
import "core:encoding/base64"
import "core:encoding/json"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

// Pinned public keys, embedded from the files the release workflow signs with
// (scripts/release/minisign/*.pub). Rotation (docs/release-signing.md) changes
// these #load lines in the same commit that changes the .pub files;
// test_embedded_pins_match_the_key_directory fails until it does.
PINNED_KEY_FILES := [?]string {
	#load("../../../scripts/release/minisign/heimdall-release-1.pub", string),
	#load("../../../scripts/release/minisign/heimdall-release-2.pub", string),
}

MANIFEST_KIND :: "heimdall-release-manifest"
MANIFEST_SCHEMA :: 1

Public_Key :: struct {
	key_id: string, // 16 upper-case hex, as minisign prints it
	key:    [ed25519.PUBLIC_KEY_SIZE]byte,
}

Signature :: struct {
	key_id:          string,
	sig:             [ed25519.SIGNATURE_SIZE]byte,
	trusted_comment: string,
	global_sig:      [ed25519.SIGNATURE_SIZE]byte,
}

// Manifest is a verified manifest reduced to what the engine needs, plus the
// signed bytes (written byte-for-byte as release.json / release.json.minisig).
Manifest :: struct {
	tag:              string,
	version:          string,
	commit:           string,
	key_id:           string,
	min_engine:       i64,
	journal_schema:   i64,
	// §11.2 / §13.4 engine fields; -1 when absent.
	state_schema:     i64,
	state_compat_min: i64,
	min_launcher_abi: i64,
	// The entry for the requested target.
	target:           string,
	asset:            string,
	size:             i64,
	sha256:           string, // 64 lower-case hex
	// Trusted comment.
	seq:              i64,
	expires:          i64,
	raw:              []byte,
	signature:        []byte,
}

Verify_Options :: struct {
	target:         string, // "" = TARGET
	expected_tag:   string, // tag of the GitHub release the resolver picked; "" = unchecked
	expected_asset: string, // bundle asset name found in that release; "" = unchecked
	now:            i64, // unix seconds
	check_expiry:   bool, // true for a new candidate (§14 step 4)
	pins:           []Public_Key, // nil = the embedded PINNED_KEY_FILES
}

manifest_destroy :: proc(m: ^Manifest, allocator := context.allocator) {
	context.allocator = allocator
	delete(m.tag)
	delete(m.version)
	delete(m.commit)
	delete(m.key_id)
	delete(m.target)
	delete(m.asset)
	delete(m.sha256)
	delete(m.raw)
	delete(m.signature)
	m^ = {}
}

// pinned_keys parses the embedded key files (temp-allocated).
pinned_keys :: proc() -> (keys: []Public_Key, err: Error) {
	out := make([dynamic]Public_Key, 0, len(PINNED_KEY_FILES), context.temp_allocator)
	for text in PINNED_KEY_FILES {
		k := parse_public_key(text) or_return
		for other in out {
			if other.key_id == k.key_id do return nil, fail(.Key_Unpinned, "duplicate pinned key id %s", k.key_id)
		}
		append(&out, k)
	}
	if len(out) == 0 do return nil, fail(.Key_Unpinned, "no pinned keys")
	return out[:], {}
}

@(private)
split_lines :: proc(text: string) -> []string {
	lines := strings.split(text, "\n", context.temp_allocator)
	for &l in lines do l = strings.trim_suffix(l, "\r")
	return lines
}

@(private)
key_id_hex :: proc(le: []byte) -> string {
	// minisign prints the 8-byte key number as a little-endian u64 in hex.
	HEX := "0123456789ABCDEF"
	b := make([]byte, 16, context.temp_allocator)
	for i in 0 ..< 8 {
		v := le[7 - i]
		b[2 * i] = HEX[v >> 4]
		b[2 * i + 1] = HEX[v & 15]
	}
	return string(b)
}

@(private)
b64 :: proc(line: string) -> ([]byte, bool) {
	s := strings.trim_space(line)
	if len(s) == 0 || len(s) % 4 != 0 do return nil, false
	for c in transmute([]byte)s {
		switch c {
		case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '+', '/', '=':
		case:
			return nil, false
		}
	}
	out, err := base64.decode(s, allocator = context.temp_allocator)
	if err != nil do return nil, false
	return out, true
}

parse_public_key :: proc(text: string) -> (k: Public_Key, err: Error) {
	lines := split_lines(text)
	if len(lines) < 2 || !strings.has_prefix(lines[0], "untrusted comment:") {
		return k, fail(.Key_Unpinned, "not a minisign public key")
	}
	blob, b64_ok := b64(lines[1])
	if !b64_ok || len(blob) != 42 || blob[0] != 'E' || blob[1] != 'd' {
		return k, fail(.Key_Unpinned, "unsupported or malformed public key")
	}
	k.key_id = key_id_hex(blob[2:10])
	copy(k.key[:], blob[10:42])
	return k, nil
}

parse_signature :: proc(text: string) -> (s: Signature, err: Error) {
	lines := split_lines(text)
	if len(lines) < 4 ||
	   !strings.has_prefix(lines[0], "untrusted comment:") ||
	   !strings.has_prefix(lines[2], "trusted comment: ") {
		return s, fail(.Signature_Invalid, "not a minisign signature")
	}
	blob, ok1 := b64(lines[1])
	if !ok1 || len(blob) != 74 do return s, fail(.Signature_Invalid, "malformed signature line")
	if blob[0] != 'E' || blob[1] != 'D' {
		// "Ed" = legacy, not prehashed. T5 signs prehashed only; refuse the rest.
		return s, fail(.Signature_Invalid, "signature algorithm %q is not prehashed Ed25519", string(blob[:2]))
	}
	s.key_id = key_id_hex(blob[2:10])
	copy(s.sig[:], blob[10:74])
	s.trusted_comment = lines[2][len("trusted comment: "):]
	gblob, ok2 := b64(lines[3])
	if !ok2 || len(gblob) != 64 do return s, fail(.Signature_Invalid, "malformed global signature")
	copy(s.global_sig[:], gblob)
	return s, nil
}

// minisign_verify checks both signatures of a prehashed minisign signature.
minisign_verify :: proc(key: Public_Key, message: []byte, s: Signature) -> bool {
	key, s := key, s
	if key.key_id != s.key_id do return false
	pk: ed25519.Public_Key
	if !ed25519.public_key_set_bytes(&pk, key.key[:]) do return false
	digest: [blake2b.DIGEST_SIZE]byte
	ctx: blake2b.Context
	blake2b.init(&ctx)
	blake2b.update(&ctx, message)
	blake2b.final(&ctx, digest[:])
	if !ed25519.verify(&pk, digest[:], s.sig[:]) do return false
	global := make([]byte, len(s.sig) + len(s.trusted_comment), context.temp_allocator)
	copy(global, s.sig[:])
	copy(global[len(s.sig):], s.trusted_comment)
	return ed25519.verify(&pk, global, s.global_sig[:])
}

// verify_manifest runs §14 steps 2-4 (and §13.1/§13.4) on downloaded bytes.
// The returned Manifest owns copies of its strings and of both inputs,
// allocated with `allocator`; free with manifest_destroy.
verify_manifest :: proc(
	manifest_bytes, signature_bytes: []byte,
	opts: Verify_Options,
	allocator := context.allocator,
) -> (
	m: Manifest,
	err: Error,
) {
	if len(manifest_bytes) > MAX_MANIFEST_BYTES do return m, fail(.Manifest_Invalid, "manifest larger than %d bytes", MAX_MANIFEST_BYTES)
	if len(signature_bytes) > MAX_SIGNATURE_BYTES do return m, fail(.Signature_Invalid, "signature larger than %d bytes", MAX_SIGNATURE_BYTES)
	if !utf8.valid_string(string(signature_bytes)) do return m, fail(.Signature_Invalid, "signature is not UTF-8")

	sig := parse_signature(string(signature_bytes)) or_return

	// Step 2: pinned key.
	pins := opts.pins
	if pins == nil do pins = pinned_keys() or_return
	key: Public_Key
	found := false
	for p in pins {
		if p.key_id == sig.key_id {
			key = p
			found = true
			break
		}
	}
	if !found do return m, fail(.Key_Unpinned, "signature key id %s is not pinned", sig.key_id)

	// Step 3: signatures.
	if !minisign_verify(key, manifest_bytes, sig) {
		return m, fail(.Signature_Invalid, "minisign signature does not verify with key %s", key.key_id)
	}

	// Step 4: canonical form and content.
	value, perr := json.parse(manifest_bytes, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	if perr != nil do return m, fail(.Manifest_Invalid, "manifest is not JSON (%v)", perr)
	canon, canon_ok := canonical_json(value)
	if !canon_ok || canon != string(manifest_bytes) do return m, fail(.Manifest_Invalid, "manifest is not in canonical form")

	tmp: Manifest
	check_manifest_shape(value, &tmp) or_return
	if tmp.key_id != sig.key_id {
		return m, fail(.Manifest_Invalid, "manifest key_id %s differs from signing key %s", tmp.key_id, sig.key_id)
	}
	parse_trusted_comment(sig.trusted_comment, tmp.tag, &tmp) or_return
	if opts.check_expiry && tmp.expires <= opts.now {
		return m, fail(.Manifest_Expired, "manifest %s expired at %d (now %d)", tmp.tag, tmp.expires, opts.now)
	}

	// §13.1: agreement with the release the resolver found.
	if opts.expected_tag != "" && tmp.tag != opts.expected_tag {
		return m, fail(.Manifest_Mismatch, "manifest tag %s, release tag %s", tmp.tag, opts.expected_tag)
	}
	target := opts.target if opts.target != "" else TARGET
	obj := value.(json.Object)
	entry, has := obj["targets"].(json.Object)[target]
	if !has do return m, fail(.Manifest_Mismatch, "manifest %s has no %s bundle", tmp.tag, target)
	e := entry.(json.Object)
	tmp.target = target
	tmp.asset = e["asset"].(json.String)
	tmp.size = i64(e["size"].(json.Integer))
	tmp.sha256 = e["sha256"].(json.String)
	if opts.expected_asset != "" && tmp.asset != opts.expected_asset {
		return m, fail(.Manifest_Mismatch, "manifest names asset %s, release has %s", tmp.asset, opts.expected_asset)
	}

	// §13.4: engine fields are required once a release claims an engine.
	if tmp.min_engine >= 1 && (tmp.state_schema < 0 || tmp.state_compat_min < 0 || tmp.min_launcher_abi < 0) {
		return m, fail(.Manifest_Incomplete, "min_engine %d without state_schema, state_compat_min and min_launcher_abi", tmp.min_engine)
	}

	context.allocator = allocator
	m = tmp
	m.tag = strings.clone(tmp.tag)
	m.version = strings.clone(tmp.version)
	m.commit = strings.clone(tmp.commit)
	m.key_id = strings.clone(tmp.key_id)
	m.target = strings.clone(tmp.target)
	m.asset = strings.clone(tmp.asset)
	m.sha256 = strings.clone(tmp.sha256)
	m.raw = slice.clone(manifest_bytes)
	m.signature = slice.clone(signature_bytes)
	return m, nil
}

@(private)
is_hex :: proc(s: string, n: int, upper: bool) -> bool {
	if len(s) != n do return false
	for c in transmute([]byte)s {
		switch c {
		case '0' ..= '9':
		case 'a' ..= 'f':
			if upper do return false
		case 'A' ..= 'F':
			if !upper do return false
		case:
			return false
		}
	}
	return true
}

@(private)
is_decimal_part :: proc(s: string) -> bool {
	// 0|[1-9][0-9]*
	if len(s) == 0 do return false
	if s[0] == '0' do return len(s) == 1
	for c in transmute([]byte)s do if c < '0' || c > '9' do return false
	return true
}

// valid_tag: ^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(-[0-9A-Za-z.-]+)?$
// (TAG_RE in release-manifest.py).
valid_tag :: proc(tag: string) -> bool {
	if len(tag) < 6 || len(tag) > 128 || tag[0] != 'v' do return false
	rest := tag[1:]
	core_part := rest
	if i := strings.index_byte(rest, '-'); i >= 0 {
		core_part = rest[:i]
		pre := rest[i + 1:]
		if len(pre) == 0 do return false
		for c in transmute([]byte)pre {
			switch c {
			case '0' ..= '9', 'A' ..= 'Z', 'a' ..= 'z', '.', '-':
			case:
				return false
			}
		}
	}
	parts := strings.split(core_part, ".", context.temp_allocator)
	if len(parts) != 3 do return false
	for p in parts do if !is_decimal_part(p) do return false
	return true
}

@(private)
valid_target_name :: proc(s: string) -> bool {
	// ^[a-z0-9]+-[a-z0-9]+$
	i := strings.index_byte(s, '-')
	if i <= 0 || i == len(s) - 1 do return false
	for c, j in transmute([]byte)s {
		if j == i do continue
		if !((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) do return false
	}
	return true
}

@(private)
valid_asset_name :: proc(s: string) -> bool {
	if s == "" || s == "." || s == ".." do return false
	for c in transmute([]byte)s do if c == '/' || c == '\\' || c == 0 do return false
	return true
}

@(private)
get_int :: proc(obj: json.Object, key: string) -> (v: i64, present: bool, is_int: bool) {
	raw, has := obj[key]
	if !has do return 0, false, false
	i, ok := raw.(json.Integer)
	return i64(i), true, ok
}

@(private)
check_manifest_shape :: proc(value: json.Value, m: ^Manifest) -> Error {
	obj, is_obj := value.(json.Object)
	if !is_obj do return fail(.Manifest_Invalid, "manifest: not an object")
	need_str :: proc(obj: json.Object, key: string) -> (string, bool) {
		s, ok := obj[key].(json.String)
		return s, ok
	}
	kind, _ := need_str(obj, "kind")
	if kind != MANIFEST_KIND do return fail(.Manifest_Invalid, "manifest: wrong kind")
	schema, _, schema_int := get_int(obj, "schema")
	if !schema_int || schema != MANIFEST_SCHEMA do return fail(.Manifest_Invalid, "manifest: unsupported schema")
	tag, tag_ok := need_str(obj, "tag")
	if !tag_ok || !valid_tag(tag) do return fail(.Manifest_Invalid, "manifest: invalid tag")
	version, _ := need_str(obj, "version")
	if version != tag[1:] do return fail(.Manifest_Invalid, "manifest: version does not match tag")
	commit, _ := need_str(obj, "commit")
	if !is_hex(commit, 40, false) do return fail(.Manifest_Invalid, "manifest: invalid commit")
	key_id, _ := need_str(obj, "key_id")
	if !is_hex(key_id, 16, true) do return fail(.Manifest_Invalid, "manifest: invalid key_id")
	m.tag, m.version, m.commit, m.key_id = tag, version, commit, key_id

	for field in ([]string{"min_engine", "journal_schema"}) {
		v, _, is_int := get_int(obj, field)
		if !is_int || v < 0 do return fail(.Manifest_Invalid, "manifest: invalid %s", field)
		if field == "min_engine" do m.min_engine = v
		else do m.journal_schema = v
	}
	// Optional engine fields (§11.2, §13.4): absent = -1, present must be ints.
	optional := [3]string{"state_schema", "state_compat_min", "min_launcher_abi"}
	minimum := [3]i64{1, 0, 0}
	values: [3]i64
	for field, i in optional {
		v, present, is_int := get_int(obj, field)
		values[i] = -1
		if !present do continue
		if !is_int || v < minimum[i] do return fail(.Manifest_Invalid, "manifest: invalid %s", field)
		values[i] = v
	}
	m.state_schema, m.state_compat_min, m.min_launcher_abi = values[0], values[1], values[2]

	targets, targets_ok := obj["targets"].(json.Object)
	if !targets_ok || len(targets) == 0 do return fail(.Manifest_Invalid, "manifest: no targets")
	for name, entry in targets {
		if !valid_target_name(name) do return fail(.Manifest_Invalid, "manifest: invalid target %q", name)
		e, e_ok := entry.(json.Object)
		if !e_ok do return fail(.Manifest_Invalid, "manifest: %s: not an object", name)
		asset, _ := need_str(e, "asset")
		if !valid_asset_name(asset) do return fail(.Manifest_Invalid, "manifest: %s: invalid asset name", name)
		size, _, size_int := get_int(e, "size")
		if !size_int || size < 0 do return fail(.Manifest_Invalid, "manifest: %s: invalid size", name)
		digest, _ := need_str(e, "sha256")
		if !is_hex(digest, 64, false) do return fail(.Manifest_Invalid, "manifest: %s: invalid sha256", name)
	}
	return nil
}

@(private)
parse_trusted_comment :: proc(comment, tag: string, m: ^Manifest) -> Error {
	value, perr := json.parse_string(comment, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	if perr != nil do return fail(.Manifest_Invalid, "trusted comment: invalid JSON")
	obj, is_obj := value.(json.Object)
	if !is_obj do return fail(.Manifest_Invalid, "trusted comment: not an object")
	version, _ := obj["version"].(json.String)
	if version != tag do return fail(.Manifest_Invalid, "trusted comment version %q does not match manifest tag %s", version, tag)
	seq, _, seq_int := get_int(obj, "seq")
	if !seq_int do return fail(.Manifest_Invalid, "trusted comment: invalid seq")
	expires, _, exp_int := get_int(obj, "expires")
	if !exp_int do return fail(.Manifest_Invalid, "trusted comment: invalid expires")
	m.seq, m.expires = seq, expires
	return nil
}

// canonical_json renders a value exactly like Python's
// json.dumps(v, sort_keys=True, separators=(",", ":"), ensure_ascii=True) + "\n".
// Floats are refused (the manifest has none), as is invalid UTF-8.
canonical_json :: proc(v: json.Value) -> (string, bool) {
	b := strings.builder_make(context.temp_allocator)
	if !write_canonical(&b, v) do return "", false
	strings.write_byte(&b, '\n')
	return strings.to_string(b), true
}

@(private)
write_canonical :: proc(b: ^strings.Builder, v: json.Value) -> bool {
	switch x in v {
	case json.Null:
		strings.write_string(b, "null")
	case json.Boolean:
		strings.write_string(b, "true" if x else "false")
	case json.Integer:
		buf: [32]byte
		strings.write_string(b, strconv.write_int(buf[:], i64(x), 10))
	case json.Float:
		return false
	case json.String:
		return write_canonical_string(b, x)
	case json.Array:
		strings.write_byte(b, '[')
		for item, i in x {
			if i > 0 do strings.write_byte(b, ',')
			if !write_canonical(b, item) do return false
		}
		strings.write_byte(b, ']')
	case json.Object:
		keys := make([]string, len(x), context.temp_allocator)
		i := 0
		for k in x {
			keys[i] = k
			i += 1
		}
		// Byte order of UTF-8 equals code point order, which is Python's sort.
		slice.sort(keys)
		strings.write_byte(b, '{')
		for k, j in keys {
			if j > 0 do strings.write_byte(b, ',')
			if !write_canonical_string(b, k) do return false
			strings.write_byte(b, ':')
			if !write_canonical(b, x[k]) do return false
		}
		strings.write_byte(b, '}')
	}
	return true
}

@(private)
write_canonical_string :: proc(b: ^strings.Builder, s: string) -> bool {
	write_u :: proc(b: ^strings.Builder, u: u32) {
		HEX := "0123456789abcdef"
		strings.write_string(b, "\\u")
		for shift := 12; shift >= 0; shift -= 4 do strings.write_byte(b, HEX[(u >> uint(shift)) & 15])
	}
	if !utf8.valid_string(s) do return false
	strings.write_byte(b, '"')
	for r in s {
		switch r {
		case '"':
			strings.write_string(b, "\\\"")
		case '\\':
			strings.write_string(b, "\\\\")
		case '\n':
			strings.write_string(b, "\\n")
		case '\r':
			strings.write_string(b, "\\r")
		case '\t':
			strings.write_string(b, "\\t")
		case '\b':
			strings.write_string(b, "\\b")
		case '\f':
			strings.write_string(b, "\\f")
		case:
			switch {
			case r < 0x20 || r == 0x7f: // Python escapes everything outside ' '..'~'
				write_u(b, u32(r))
			case r < 0x7f:
				strings.write_byte(b, byte(r))
			case r <= 0xFFFF:
				write_u(b, u32(r))
			case:
				c := u32(r) - 0x10000
				write_u(b, 0xD800 + (c >> 10))
				write_u(b, 0xDC00 + (c & 0x3FF))
			}
		}
	}
	strings.write_byte(b, '"')
	return true
}
