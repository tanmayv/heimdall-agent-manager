// Package testkit builds signed test releases for the supervisor's service tests and the
// cross-OS e2e suite (T13b): release bundles (tar.gz / zip, stored DEFLATE), an ephemeral
// minisign key, prehashed ("ED") signatures and canonical manifests exactly as
// scripts/release/release-manifest.py writes them. Test code only; never imported by a
// shipped binary.
package testkit

import "core:crypto"
import "core:crypto/blake2b"
import "core:crypto/ed25519"
import "core:crypto/sha2"
import "core:encoding/base64"
import "core:encoding/hex"
import "core:fmt"
import "core:hash"
import "core:strings"
import "../fetch"
import "../resolver"

// ---------------------------------------------------------------------------
// Archives

deflate_stored :: proc(data: []byte, allocator := context.allocator) -> []byte {
	out := make([dynamic]byte, allocator)
	rest := data
	for {
		n := min(len(rest), 65535)
		final := n == len(rest)
		append(&out, 1 if final else 0)
		append(&out, byte(n), byte(n >> 8), byte(~u16(n)), byte(~u16(n) >> 8))
		append(&out, ..rest[:n])
		rest = rest[n:]
		if final do break
	}
	return out[:]
}

Bundle_File :: struct {
	path: string, // e.g. "bin/ham-bridge"
	data: []byte,
	exec: bool,
}

make_tar_gz :: proc(files: []Bundle_File, allocator := context.allocator) -> []byte {
	tar := make([dynamic]byte, context.temp_allocator)
	for f in files {
		h: [512]byte
		copy(h[0:100], f.path)
		copy(h[100:108], fmt.tprintf("%07o\x00", 0o755 if f.exec else 0o644))
		copy(h[108:116], "0000000\x00")
		copy(h[116:124], "0000000\x00")
		copy(h[124:136], fmt.tprintf("%011o\x00", len(f.data)))
		copy(h[136:148], "00000000000\x00")
		h[156] = '0'
		copy(h[257:263], "ustar\x00")
		copy(h[263:265], "00")
		for i in 148 ..< 156 do h[i] = ' '
		sum := 0
		for b in h do sum += int(b)
		copy(h[148:156], fmt.tprintf("%06o\x00 ", sum))
		append(&tar, ..h[:])
		append(&tar, ..f.data)
		for _ in 0 ..< (512 - len(f.data) % 512) % 512 do append(&tar, 0)
	}
	for _ in 0 ..< 1024 do append(&tar, 0)
	out := make([dynamic]byte, allocator)
	append(&out, 0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xff)
	append(&out, ..deflate_stored(tar[:], context.temp_allocator))
	crc := hash.crc32(tar[:])
	size := u32(len(tar))
	append(&out, byte(crc), byte(crc >> 8), byte(crc >> 16), byte(crc >> 24))
	append(&out, byte(size), byte(size >> 8), byte(size >> 16), byte(size >> 24))
	return out[:]
}

make_zip :: proc(files: []Bundle_File, allocator := context.allocator) -> []byte {
	out := make([dynamic]byte, allocator)
	cd := make([dynamic]byte, context.temp_allocator)
	put16 :: proc(b: ^[dynamic]byte, v: u32) {append(b, byte(v), byte(v >> 8))}
	put32 :: proc(b: ^[dynamic]byte, v: u32) {append(b, byte(v), byte(v >> 8), byte(v >> 16), byte(v >> 24))}
	for f in files {
		crc := hash.crc32(f.data)
		off := u32(len(out))
		put32(&out, 0x04034b50)
		put16(&out, 20)
		put16(&out, 0)
		put16(&out, 0)
		put32(&out, 0)
		put32(&out, crc)
		put32(&out, u32(len(f.data)))
		put32(&out, u32(len(f.data)))
		put16(&out, u32(len(f.path)))
		put16(&out, 0)
		append(&out, f.path)
		append(&out, ..f.data)
		put32(&cd, 0x02014b50)
		put16(&cd, 20)
		put16(&cd, 20)
		put16(&cd, 0)
		put16(&cd, 0)
		put32(&cd, 0)
		put32(&cd, crc)
		put32(&cd, u32(len(f.data)))
		put32(&cd, u32(len(f.data)))
		put16(&cd, u32(len(f.path)))
		put16(&cd, 0)
		put16(&cd, 0)
		put16(&cd, 0)
		put16(&cd, 0)
		put32(&cd, 0)
		put32(&cd, off)
		append(&cd, f.path)
	}
	cd_off := u32(len(out))
	append(&out, ..cd[:])
	put32(&out, 0x06054b50)
	put16(&out, 0)
	put16(&out, 0)
	put16(&out, u32(len(files)))
	put16(&out, u32(len(files)))
	put32(&out, u32(len(cd)))
	put32(&out, cd_off)
	put16(&out, 0)
	return out[:]
}

// ---------------------------------------------------------------------------
// minisign

Key :: struct {
	priv:    ed25519.Private_Key,
	id_le:   [8]byte,
	pub:     fetch.Public_Key,
	pub_txt: string, // minisign .pub text (heap)
}

make_key :: proc() -> Key {
	k: Key
	ok := ed25519.private_key_generate(&k.priv)
	assert(ok)
	crypto.rand_bytes(k.id_le[:])
	return key_finish(k)
}

// E2E_SEED: the fixed, TEST-ONLY signing key of the e2e suite. Its public key is
// src/supervisor/testdata/e2e-test-key.pub, which only test builds of ham-supervisor trust
// (-define:HEIMDALL_SUPERVISOR_TEST=true -define:HEIMDALL_TEST_PINNED_KEY=<its key line>).
// Release builds never set either define, so this key signs nothing that ships.
E2E_SEED :: "heimdall-e2e-test-key-not-secret"
E2E_KEY_ID_LE :: [8]byte{0x13, 0xb0, 0x5e, 0xed, 0x7e, 0x57, 0x0e, 0x2e}

e2e_key :: proc() -> Key {
	k: Key
	seed := E2E_SEED
	ok := ed25519.private_key_set_bytes(&k.priv, transmute([]byte)seed)
	assert(ok)
	k.id_le = E2E_KEY_ID_LE
	return key_finish(k)
}

// key_line: the base64 line of the minisign public key (the -define value).
key_line :: proc(k: ^Key) -> string {
	lines := strings.split_lines(k.pub_txt, context.temp_allocator)
	return lines[1] if len(lines) > 1 else ""
}

@(private)
key_finish :: proc(key: Key) -> Key {
	k := key
	pub: [32]byte
	ed25519.private_key_public_bytes(&k.priv, pub[:])
	blob: [42]byte
	blob[0], blob[1] = 'E', 'd'
	copy(blob[2:10], k.id_le[:])
	copy(blob[10:], pub[:])
	k.pub_txt = fmt.aprintf("untrusted comment: minisign public key\n%s\n", base64.encode(blob[:], allocator = context.temp_allocator))
	parsed, err := fetch.parse_public_key(k.pub_txt)
	assert(err == nil)
	k.pub = parsed
	return k
}

key_destroy :: proc(k: ^Key) {
	delete(k.pub_txt)
}

// sign builds a prehashed ("ED") .minisig text.
sign :: proc(k: ^Key, message: []byte, trusted_comment: string, allocator := context.allocator) -> string {
	digest: [blake2b.DIGEST_SIZE]byte
	ctx: blake2b.Context
	blake2b.init(&ctx)
	blake2b.update(&ctx, message)
	blake2b.final(&ctx, digest[:])
	sig: [64]byte
	ed25519.sign(&k.priv, digest[:], sig[:])
	blob: [74]byte
	blob[0], blob[1] = 'E', 'D'
	copy(blob[2:10], k.id_le[:])
	copy(blob[10:], sig[:])
	global_msg := make([]byte, 64 + len(trusted_comment), context.temp_allocator)
	copy(global_msg, sig[:])
	copy(global_msg[64:], trusted_comment)
	gsig: [64]byte
	ed25519.sign(&k.priv, global_msg, gsig[:])
	return fmt.aprintf(
		"untrusted comment: signature from minisign secret key\n%s\ntrusted comment: %s\n%s\n",
		base64.encode(blob[:], allocator = context.temp_allocator),
		trusted_comment,
		base64.encode(gsig[:], allocator = context.temp_allocator),
		allocator = allocator,
	)
}

sha256_hex :: proc(data: []byte, allocator := context.temp_allocator) -> string {
	d: [32]byte
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, data)
	sha2.final(&ctx, d[:])
	return string(hex.encode(d[:], allocator))
}

// ---------------------------------------------------------------------------
// Releases

Release_Spec :: struct {
	tag:        string, // "v0.6.0"
	target:     string, // "" = this build's target
	files:      []Bundle_File,
	min_engine: int, // 0 -> 1
	expires:    i64, // trusted-comment expiry, unix
	seq:        i64,
}

Release :: struct {
	tag:       string,
	version:   string,
	asset:     string, // bundle asset name
	bundle:    []byte,
	manifest:  string, // canonical JSON + LF, as signed
	signature: string,
	sha256:    string,
	tree:      string, // <ver>-<d12>
}

// make_release builds and signs a release (heap-allocated; free with release_destroy).
make_release :: proc(k: ^Key, s: Release_Spec) -> Release {
	target := s.target if s.target != "" else fetch.TARGET
	r: Release
	r.tag = strings.clone(s.tag)
	r.version = strings.clone(s.tag[1:])
	r.asset = resolver.bundle_asset_name(target, s.tag)
	r.bundle = make_zip(s.files) if strings.has_prefix(target, "windows-") else make_tar_gz(s.files)
	r.sha256 = sha256_hex(r.bundle, context.allocator)
	r.tree = strings.concatenate({r.version, "-", r.sha256[:12]})
	min_engine := s.min_engine if s.min_engine > 0 else 1

	b := strings.builder_make(context.temp_allocator)
	w :: strings.write_string
	w(&b, `{"commit":"`)
	w(&b, strings.repeat("ab", 20, context.temp_allocator))
	w(&b, `","journal_schema":1,"key_id":"`)
	w(&b, k.pub.key_id)
	w(&b, `","kind":"heimdall-release-manifest","min_engine":`)
	strings.write_int(&b, min_engine)
	w(&b, `,"min_launcher_abi":1,"schema":1,"state_compat_min":1,"state_schema":1,"tag":"`)
	w(&b, s.tag)
	w(&b, `","targets":{"`)
	w(&b, target)
	w(&b, `":{"asset":"`)
	w(&b, r.asset)
	w(&b, `","sha256":"`)
	w(&b, r.sha256)
	w(&b, `","size":`)
	strings.write_int(&b, len(r.bundle))
	w(&b, `}},"version":"`)
	w(&b, r.version)
	w(&b, "\"}\n")
	r.manifest = strings.clone(strings.to_string(b))
	seq := s.seq if s.seq > 0 else 1
	expires := s.expires if s.expires > 0 else 4_000_000_000
	tc := strings.concatenate({`{"expires":`, fmt.tprint(expires), `,"seq":`, fmt.tprint(seq), `,"version":"`, s.tag, `"}`}, context.temp_allocator)
	r.signature = sign(k, transmute([]byte)r.manifest, tc)
	return r
}

release_destroy :: proc(r: ^Release) {
	delete(r.tag)
	delete(r.version)
	delete(r.asset)
	delete(r.bundle)
	delete(r.manifest)
	delete(r.signature)
	delete(r.sha256)
	delete(r.tree)
}

// release_api_json: one GitHub API release object for the resolver (heap-allocated).
release_api_json :: proc(r: Release, prerelease := false) -> string {
	b := strings.builder_make(context.temp_allocator)
	w :: strings.write_string
	w(&b, `{"tag_name":"`)
	w(&b, r.tag)
	w(&b, `","draft":false,"prerelease":`)
	w(&b, "true" if prerelease else "false")
	w(&b, `,"assets":[`)
	asset :: proc(b: ^strings.Builder, name: string, size: int, tag: string) {
		strings.write_string(b, `{"name":"`)
		strings.write_string(b, name)
		strings.write_string(b, `","size":`)
		strings.write_int(b, size)
		strings.write_string(b, `,"browser_download_url":"https://github.com/`)
		strings.write_string(b, fetch.REPO)
		strings.write_string(b, `/releases/download/`)
		strings.write_string(b, tag)
		strings.write_string(b, `/`)
		strings.write_string(b, name)
		strings.write_string(b, `"}`)
	}
	asset(&b, r.asset, len(r.bundle), r.tag)
	w(&b, ",")
	asset(&b, fetch.MANIFEST_ASSET, len(r.manifest), r.tag)
	w(&b, ",")
	asset(&b, fetch.SIGNATURE_ASSET, len(r.signature), r.tag)
	w(&b, "]}")
	return strings.clone(strings.to_string(b))
}
