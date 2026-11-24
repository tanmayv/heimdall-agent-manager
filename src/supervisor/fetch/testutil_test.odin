package fetch

// Test helpers: archive and deflate builders, a minisign signer with ephemeral
// keys, temporary directories. Everything is temp-allocated; tests free_all
// the temp allocator at the end (the runner gives each test its own).

import "core:bytes"
import "core:crypto"
import "core:crypto/blake2b"
import "core:crypto/ed25519"
import "core:crypto/sha2"
import "core:encoding/base64"
import "core:encoding/hex"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:strings"
import "core:testing"

// ---------------------------------------------------------------------------
// Directories and files

make_test_dir :: proc(t: ^testing.T) -> string {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, err := os.make_directory_temp(base, "t12-*", context.temp_allocator)
	testing.expect(t, err == nil, "make_directory_temp")
	return dir
}

pj :: proc(parts: ..string) -> string {
	sep := "\\" if ODIN_OS == .Windows else "/"
	return strings.join(parts, sep, context.temp_allocator)
}

write_file :: proc(path: string, data: []byte) -> bool {
	return os.write_entire_file(path, data) == nil
}

read_file :: proc(path: string) -> ([]byte, bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	return data, err == nil
}

sha256_hex :: proc(data: []byte) -> string {
	d: [32]byte
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, data)
	sha2.final(&ctx, d[:])
	return string(hex.encode(d[:], context.temp_allocator))
}

// ---------------------------------------------------------------------------
// DEFLATE / gzip

// deflate_stored encodes data as stored (uncompressed) DEFLATE blocks.
deflate_stored :: proc(data: []byte) -> []byte {
	out := make([dynamic]byte, context.temp_allocator)
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

Bit_Writer :: struct {
	out:    [dynamic]byte,
	bitbuf: u64,
	bitcnt: uint,
}

bw_bits :: proc(w: ^Bit_Writer, v: u32, n: uint) {
	w.bitbuf |= u64(v) << w.bitcnt
	w.bitcnt += n
	for w.bitcnt >= 8 {
		append(&w.out, byte(w.bitbuf))
		w.bitbuf >>= 8
		w.bitcnt -= 8
	}
}

// Huffman codes go MSB-first.
bw_code :: proc(w: ^Bit_Writer, code: u32, n: uint) {
	r: u32
	for i in 0 ..< n do if code & (1 << i) != 0 do r |= 1 << (n - 1 - i)
	bw_bits(w, r, n)
}

bw_finish :: proc(w: ^Bit_Writer) -> []byte {
	if w.bitcnt > 0 do append(&w.out, byte(w.bitbuf))
	w.bitbuf, w.bitcnt = 0, 0
	return w.out[:]
}

// deflate_zeros returns a fixed-Huffman stream that inflates to 1 + 258*runs
// zero bytes: a literal 0, then `runs` copies of <length 258, distance 1>.
// About 13 bits per 258 bytes, so a 600 MiB bomb is ~4 MB.
deflate_zeros :: proc(runs: int) -> []byte {
	w := Bit_Writer{out = make([dynamic]byte, 0, runs * 13 / 8 + 16, context.temp_allocator)}
	bw_bits(&w, 1, 1) // BFINAL
	bw_bits(&w, 1, 2) // fixed Huffman
	bw_code(&w, 0x30, 8) // literal 0
	for _ in 0 ..< runs {
		bw_code(&w, 0xC5, 8) // symbol 285 = length 258
		bw_code(&w, 0, 5) // distance code 0 = 1
	}
	bw_code(&w, 0, 7) // end of block
	return bw_finish(&w)
}

gzip_wrap :: proc(deflated: []byte, crc: u32, size: u32) -> []byte {
	out := make([dynamic]byte, context.temp_allocator)
	append(&out, 0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xff)
	append(&out, ..deflated)
	append(&out, byte(crc), byte(crc >> 8), byte(crc >> 16), byte(crc >> 24))
	append(&out, byte(size), byte(size >> 8), byte(size >> 16), byte(size >> 24))
	return out[:]
}

gzip_stored :: proc(data: []byte) -> []byte {
	return gzip_wrap(deflate_stored(data), hash.crc32(data), u32(len(data)))
}

// ---------------------------------------------------------------------------
// tar

Tar_Opts :: struct {
	typeflag: byte,
	mode:     int,
	prefix:   string,
	gnu:      bool, // GNU magic instead of POSIX ustar
	size:     i64, // -1 = len(data)
	bad_sum:  bool,
}

build_tar_header :: proc(name: string, size: i64, o: Tar_Opts) -> [512]byte {
	h: [512]byte
	copy(h[0:100], name)
	mode := o.mode if o.mode != 0 else 0o644
	copy(h[100:108], fmt.tprintf("%07o\x00", mode))
	copy(h[108:116], "0000000\x00")
	copy(h[116:124], "0000000\x00")
	copy(h[124:136], fmt.tprintf("%011o\x00", size))
	copy(h[136:148], "00000000000\x00")
	h[156] = o.typeflag if o.typeflag != 0 else '0'
	if o.gnu {
		copy(h[257:265], "ustar  \x00")
	} else {
		copy(h[257:263], "ustar\x00")
		copy(h[263:265], "00")
		copy(h[345:500], o.prefix)
	}
	for i in 148 ..< 156 do h[i] = ' '
	sum := 0
	for b in h do sum += int(b)
	if o.bad_sum do sum += 1
	copy(h[148:156], fmt.tprintf("%06o\x00 ", sum))
	return h
}

tar_append :: proc(out: ^[dynamic]byte, name: string, data: []byte, o := Tar_Opts{size = -1}) {
	size := o.size if o.size >= 0 else i64(len(data))
	h := build_tar_header(name, size, o)
	append(out, ..h[:])
	append(out, ..data)
	pad := (512 - len(data) % 512) % 512
	for _ in 0 ..< pad do append(out, 0)
}

tar_end :: proc(out: ^[dynamic]byte) {
	for _ in 0 ..< 1024 do append(out, 0)
}

pax_record :: proc(key, value: string) -> string {
	// "<len> key=value\n" where len counts itself.
	body := fmt.tprintf(" %s=%s\n", key, value)
	n := len(body) + 1
	for len(fmt.tprintf("%d", n)) + len(body) != n do n += 1
	return fmt.tprintf("%d%s", n, body)
}

Tar_File :: struct {
	name: string,
	data: string,
	o:    Tar_Opts,
}

make_tar_gz :: proc(files: []Tar_File) -> []byte {
	out := make([dynamic]byte, context.temp_allocator)
	for f in files {
		o := f.o
		if o.size == 0 && o.typeflag != '5' do o.size = -1
		tar_append(&out, f.name, transmute([]byte)f.data, o)
	}
	tar_end(&out)
	return gzip_stored(out[:])
}

// ---------------------------------------------------------------------------
// zip

Zip_File :: struct {
	name:       string,
	data:       string,
	deflate:    bool,
	host:       u8, // 0 = MS-DOS, 3 = Unix
	ext_attr:   u32,
	flags:      u16,
	method:     u16, // overrides when non-zero
	usize:      i64, // overrides the declared size when > 0
	bad_crc:    bool,
	local_name: string, // overrides the local header name when non-empty
}

make_zip :: proc(files: []Zip_File) -> []byte {
	out := make([dynamic]byte, context.temp_allocator)
	cd := make([dynamic]byte, context.temp_allocator)
	put16 :: proc(b: ^[dynamic]byte, v: u32) {append(b, byte(v), byte(v >> 8))}
	put32 :: proc(b: ^[dynamic]byte, v: u32) {append(b, byte(v), byte(v >> 8), byte(v >> 16), byte(v >> 24))}
	for f in files {
		data := transmute([]byte)f.data
		payload := deflate_stored(data) if f.deflate else data
		method := u32(8 if f.deflate else 0)
		if f.method != 0 do method = u32(f.method)
		crc := hash.crc32(data)
		if f.bad_crc do crc ~= 1
		usize := u32(len(data))
		if f.usize > 0 do usize = u32(f.usize)
		off := u32(len(out))
		lname := f.local_name if f.local_name != "" else f.name
		put32(&out, 0x04034b50)
		put16(&out, 20)
		put16(&out, u32(f.flags))
		put16(&out, method)
		put32(&out, 0)
		put32(&out, crc)
		put32(&out, u32(len(payload)))
		put32(&out, usize)
		put16(&out, u32(len(lname)))
		put16(&out, 0)
		append(&out, lname)
		append(&out, ..payload)

		put32(&cd, 0x02014b50)
		put16(&cd, u32(f.host) << 8 | 20)
		put16(&cd, 20)
		put16(&cd, u32(f.flags))
		put16(&cd, method)
		put32(&cd, 0)
		put32(&cd, crc)
		put32(&cd, u32(len(payload)))
		put32(&cd, usize)
		put16(&cd, u32(len(f.name)))
		put16(&cd, 0)
		put16(&cd, 0)
		put16(&cd, 0)
		put16(&cd, 0)
		put32(&cd, f.ext_attr)
		put32(&cd, off)
		append(&cd, f.name)
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

Test_Key :: struct {
	priv:   ed25519.Private_Key,
	id_le:  [8]byte,
	pub:    Public_Key,
	pub_txt: string,
}

make_test_key :: proc() -> Test_Key {
	k: Test_Key
	ok := ed25519.private_key_generate(&k.priv)
	assert(ok)
	crypto.rand_bytes(k.id_le[:])
	pub: [32]byte
	ed25519.private_key_public_bytes(&k.priv, pub[:])
	blob := make([]byte, 42, context.temp_allocator)
	blob[0], blob[1] = 'E', 'd'
	copy(blob[2:10], k.id_le[:])
	copy(blob[10:], pub[:])
	k.pub_txt = fmt.tprintf("untrusted comment: minisign public key\n%s\n", base64.encode(blob, allocator = context.temp_allocator))
	parsed, err := parse_public_key(k.pub_txt)
	assert(err == nil)
	k.pub = parsed
	return k
}

// minisign_sign builds a prehashed ("ED") .minisig text.
minisign_sign :: proc(k: ^Test_Key, message: []byte, trusted_comment: string) -> string {
	digest: [blake2b.DIGEST_SIZE]byte
	ctx: blake2b.Context
	blake2b.init(&ctx)
	blake2b.update(&ctx, message)
	blake2b.final(&ctx, digest[:])
	sig: [64]byte
	ed25519.sign(&k.priv, digest[:], sig[:])
	blob := make([]byte, 74, context.temp_allocator)
	blob[0], blob[1] = 'E', 'D'
	copy(blob[2:10], k.id_le[:])
	copy(blob[10:], sig[:])
	global_msg := make([]byte, 64 + len(trusted_comment), context.temp_allocator)
	copy(global_msg, sig[:])
	copy(global_msg[64:], trusted_comment)
	gsig: [64]byte
	ed25519.sign(&k.priv, global_msg, gsig[:])
	return fmt.tprintf(
		"untrusted comment: signature from minisign secret key\n%s\ntrusted comment: %s\n%s\n",
		base64.encode(blob, allocator = context.temp_allocator),
		trusted_comment,
		base64.encode(gsig[:], allocator = context.temp_allocator),
	)
}

Manifest_Spec :: struct {
	tag:          string,
	key_id:       string,
	target:       string,
	asset:        string,
	size:         i64,
	sha256:       string,
	min_engine:   int,
	engine_fields: bool,
}

// manifest_json renders a canonical manifest by hand (keys already sorted).
manifest_json :: proc(s: Manifest_Spec) -> string {
	// fmt treats { } as directives, so build with plain writes.
	b := strings.builder_make(context.temp_allocator)
	w :: strings.write_string
	w(&b, `{"commit":"`)
	w(&b, strings.repeat("ab", 20, context.temp_allocator))
	w(&b, `","journal_schema":`)
	strings.write_int(&b, 1 if s.engine_fields else 0)
	w(&b, `,"key_id":"`)
	w(&b, s.key_id)
	w(&b, `","kind":"heimdall-release-manifest","min_engine":`)
	strings.write_int(&b, s.min_engine)
	w(&b, ",")
	if s.engine_fields do w(&b, `"min_launcher_abi":1,`)
	w(&b, `"schema":1,`)
	if s.engine_fields do w(&b, `"state_compat_min":1,"state_schema":1,`)
	w(&b, `"tag":"`)
	w(&b, s.tag)
	w(&b, `","targets":{"`)
	w(&b, s.target)
	w(&b, `":{"asset":"`)
	w(&b, s.asset)
	w(&b, `","sha256":"`)
	w(&b, s.sha256)
	w(&b, `","size":`)
	strings.write_i64(&b, s.size)
	w(&b, `}},"version":"`)
	w(&b, s.tag[1:] if len(s.tag) > 0 else "")
	w(&b, "\"}\n")
	return strings.to_string(b)
}

trusted_comment_for :: proc(tag: string, seq, expires: i64) -> string {
	return strings.concatenate({`{"expires":`, fmt.tprint(expires), `,"seq":`, fmt.tprint(seq), `,"version":"`, tag, `"}`}, context.temp_allocator)
}

// bytes_reader adapts a byte slice to io.Reader for the inflater.
Bytes_Source :: struct {
	r: bytes.Reader,
}
