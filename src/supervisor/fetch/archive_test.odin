package fetch

import "core:bytes"
import "core:compress/gzip"
import "core:log"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

// Real-tool fixtures of the same tree: GNU tar (--format=gnu, 'L' long names,
// gzip -9), GNU tar --format=pax ('x' path records, gzip -1) and Python
// zipfile (ZIP_DEFLATED, Unix modes).
FIXTURE_GNU_TGZ :: #load("testdata/gnu.tar.gz")
FIXTURE_PAX_TGZ :: #load("testdata/pax.tar.gz")
FIXTURE_ZIP :: #load("testdata/py.zip")

LONG_PATH :: "share/heimdall/extensions/a-very-long-directory-name-to-push-past-the-ustar-limit/another-long-segment-here/file-with-long-name.json"

Expected_File :: struct {
	path:   string,
	size:   i64,
	sha256: string,
}

FIXTURE_FILES := [?]Expected_File {
	{"README.md", 450, "51566366f7915951c590b3c146dd5ed4c8e9f0ee9f6133444f428fa076d22283"},
	{"empty.txt", 0, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"},
	{"bin/ham-bridge", 274117, "8c281670b668441586886cb2a6c3a9f44fc2e8f97dd8af89d84093182e0e9079"},
	{LONG_PATH, 3, "ca3d163bab055381827226140568f3bef7eaac187cebd76878e0b63e9e442356"},
	{"share/heimdall/extensions/claude-code/.claude-plugin/plugin.json", 13, "a1c5e150230b343ed793a951c4e0c11e2ba4872496cce306b50bde9a6c62a252"},
}

// extract_bytes writes `archive` into a fresh test dir and extracts it into
// <dir>/staging. Returns the dir so callers can inspect what was written.
extract_bytes :: proc(t: ^testing.T, archive: []byte, kind: Archive_Kind, limits := DEFAULT_LIMITS) -> (dir: string, out: Extracted, err: Error) {
	dir = make_test_dir(t)
	path := pj(dir, "bundle.zip" if kind == .Zip else "bundle.tar.gz")
	testing.expect(t, write_file(path, archive), "write archive")
	staging := pj(dir, "staging")
	testing.expect(t, os.make_directory(staging) == nil, "mkdir staging")
	out, err = extract_archive(path, staging, kind, limits)
	return
}

// expect_contained checks that nothing but the archive and staging/ exists in
// the test dir (no path escaped the staging root).
expect_contained :: proc(t: ^testing.T, dir: string, loc := #caller_location) {
	entries, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
	for e in entries {
		ok := e.name == "staging" || strings.has_prefix(e.name, "bundle.")
		testing.expectf(t, ok, "unexpected %s outside staging", e.name, loc = loc)
	}
}

expect_unsafe :: proc(t: ^testing.T, archive: []byte, kind: Archive_Kind, limits := DEFAULT_LIMITS, loc := #caller_location) {
	dir, _, err := extract_bytes(t, archive, kind, limits)
	testing.expectf(t, error_code(err) == .Archive_Unsafe, "want archive_unsafe, got %v (%s)", error_code(err), error_detail(err), loc = loc)
	expect_contained(t, dir, loc)
	os.remove_all(dir)
}

check_fixture_tree :: proc(t: ^testing.T, dir: string, out: Extracted, exec_bits: bool, loc := #caller_location) {
	testing.expect_value(t, len(out.files), len(FIXTURE_FILES), loc = loc)
	for want in FIXTURE_FILES {
		found := false
		for f in out.files {
			if f.path != want.path do continue
			found = true
			testing.expectf(t, f.size == want.size && f.sha256 == want.sha256, "%s: %d %s", f.path, f.size, f.sha256, loc = loc)
			data, ok := read_file(pj(dir, "staging", want.path))
			testing.expectf(t, ok && sha256_hex(data) == want.sha256, "%s on disk", want.path, loc = loc)
			testing.expectf(t, f.exec == (exec_bits && want.path == "bin/ham-bridge"), "%s exec=%v", f.path, f.exec, loc = loc)
		}
		testing.expectf(t, found, "%s extracted", want.path, loc = loc)
	}
	when ODIN_OS != .Windows {
		if exec_bits {
			fi, err := os.stat(pj(dir, "staging", "bin", "ham-bridge"), context.temp_allocator)
			testing.expect(t, err == nil && .Execute_User in fi.mode, "exec bit on disk", loc = loc)
		}
	}
}

@(test)
test_real_gnu_tar_gz_extracts :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	dir, out, err := extract_bytes(t, FIXTURE_GNU_TGZ, .Tar_Gz)
	defer os.remove_all(dir)
	testing.expectf(t, err == nil, "extract: %v", err)
	check_fixture_tree(t, dir, out, true)
}

@(test)
test_real_pax_tar_gz_extracts :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	dir, out, err := extract_bytes(t, FIXTURE_PAX_TGZ, .Tar_Gz)
	defer os.remove_all(dir)
	testing.expectf(t, err == nil, "extract: %v", err)
	check_fixture_tree(t, dir, out, true)
}

@(test)
test_real_zip_extracts :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	dir, out, err := extract_bytes(t, FIXTURE_ZIP, .Zip)
	defer os.remove_all(dir)
	testing.expectf(t, err == nil, "extract: %v", err)
	check_fixture_tree(t, dir, out, true)
}

Collect :: struct {
	buf: [dynamic]byte,
}

collect_write :: proc(user: rawptr, data: []byte) -> bool {
	c := (^Collect)(user)
	append(&c.buf, ..data)
	return true
}

inflate_bytes :: proc(data: []byte, max_out: i64) -> ([]byte, Inflate_Result) {
	r: bytes.Reader
	bytes.reader_init(&r, data)
	buf := make([]byte, READ_CHUNK, context.temp_allocator)
	br: Bit_Reader
	bit_reader_init(&br, bytes.reader_to_stream(&r), buf)
	c := Collect{buf = make([dynamic]byte, context.temp_allocator)}
	_, res := inflate(&br, Sink{write = collect_write, user = &c}, max_out)
	return c.buf[:], res
}

@(test)
test_inflate_matches_core_zlib :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	// core:compress/gzip is the oracle on real gzip -9 / -1 streams (dynamic
	// Huffman blocks, long distances).
	for fixture in ([][]byte{FIXTURE_GNU_TGZ, FIXTURE_PAX_TGZ}) {
		want: bytes.Buffer
		testing.expect(t, gzip.load_from_bytes(fixture, &want, allocator = context.temp_allocator) == nil, "core gzip")
		hdr := 10 // no optional gzip fields in these fixtures (gzip -n)
		got, res := inflate_bytes(fixture[hdr:len(fixture) - 8], 1 << 30)
		testing.expect_value(t, res, Inflate_Result.Ok)
		testing.expect(t, slice.equal(got, bytes.buffer_to_bytes(&want)), "same bytes as core zlib")
	}
	// Stored blocks, empty input, a stream spanning several 64 KiB blocks.
	data := make([]byte, 200_000, context.temp_allocator)
	for &b, i in data do b = byte(i * 7 + i / 300)
	got, res := inflate_bytes(deflate_stored(data), 1 << 30)
	testing.expect_value(t, res, Inflate_Result.Ok)
	testing.expect(t, slice.equal(got, data), "stored round trip")
	empty, res2 := inflate_bytes(deflate_stored(nil), 10)
	testing.expect(t, res2 == .Ok && len(empty) == 0, "empty")
	// Fixed-Huffman back-references across the window wrap.
	zeros, res3 := inflate_bytes(deflate_zeros(1000), 1 << 20)
	testing.expect(t, res3 == .Ok && len(zeros) == 1 + 258 * 1000, "zeros")
}

@(test)
test_inflate_rejects_bad_streams :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	// Output cap: stops at the cap, never past it.
	got, res := inflate_bytes(deflate_zeros(4000), 100_000)
	testing.expect_value(t, res, Inflate_Result.Too_Large)
	testing.expectf(t, len(got) <= 100_000, "stopped at the cap (%d)", len(got))
	_, res = inflate_bytes(deflate_stored(make([]byte, 5000, context.temp_allocator)), 4999)
	testing.expect_value(t, res, Inflate_Result.Too_Large)
	// Reserved block type 3.
	_, res = inflate_bytes([]byte{0x07, 0, 0}, 100)
	testing.expect_value(t, res, Inflate_Result.Corrupt)
	// Stored length / complement mismatch.
	_, res = inflate_bytes([]byte{0x01, 5, 0, 0, 0, 'a', 'b', 'c', 'd', 'e'}, 100)
	testing.expect_value(t, res, Inflate_Result.Corrupt)
	// Truncated streams.
	z := deflate_zeros(100)
	_, res = inflate_bytes(z[:len(z) / 2], 1 << 20)
	testing.expect_value(t, res, Inflate_Result.Truncated)
	_, res = inflate_bytes(nil, 100)
	testing.expect_value(t, res, Inflate_Result.Truncated)
	// Distance before the start of the output: fixed block, <258, dist 1> first.
	w := Bit_Writer{out = make([dynamic]byte, context.temp_allocator)}
	bw_bits(&w, 1, 1)
	bw_bits(&w, 1, 2)
	bw_code(&w, 0xC5, 8)
	bw_code(&w, 0, 5)
	bw_code(&w, 0, 7)
	_, res = inflate_bytes(bw_finish(&w), 1000)
	testing.expect_value(t, res, Inflate_Result.Corrupt)
	// Corrupting a real stream never crashes and is never silently accepted
	// as the original.
	want: bytes.Buffer
	_ = gzip.load_from_bytes(FIXTURE_GNU_TGZ, &want, allocator = context.temp_allocator)
	gnu := FIXTURE_GNU_TGZ
	body := slice.clone(gnu[10:len(gnu) - 8], context.temp_allocator)
	for i := 3; i < len(body); i += 997 {
		body[i] ~= 0x5a
		out, r := inflate_bytes(body, 1 << 22)
		testing.expectf(t, r != .Ok || !slice.equal(out, bytes.buffer_to_bytes(&want)), "flip at %d undetected", i)
		body[i] ~= 0x5a
	}
}

@(test)
test_path_traversal_is_refused :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	bad_names := []string {
		"../evil",
		"a/../../evil",
		"./../evil",
		"/etc/evil",
		"C:/evil",
		"C:evil",
		"a\\..\\..\\evil",
		"\\evil",
		"a//b",
		"a/./b",
		"a/b/..",
		"NUL",
		"bin/com1.txt",
		"lpt9",
		"a./b",
		"a /b",
		"tree.json",
		".complete",
		"RELEASE.JSON",
		"release.json.minisig",
		"a\x01b",
		"caf\xc3\xa9",
		"a<b",
		"a?b",
		"file.txt:stream",
		strings.repeat("a/", MAX_PATH_DEPTH + 1, context.temp_allocator),
		strings.repeat("x", MAX_PATH_BYTES + 1, context.temp_allocator),
	}
	for name in bad_names {
		_, _, _, reason := clean_entry_path(name)
		testing.expectf(t, reason != "", "%q accepted", name)
	}
	// End to end, in both formats, the classics.
	for name in ([]string{"../evil", "a/../../evil", "/tmp/evil-t12", "..\\evil"}) {
		if len(name) <= 100 {
			expect_unsafe(t, make_tar_gz({{name = "ok.txt", data = "fine"}, {name = name, data = "pwned"}}), .Tar_Gz)
		}
		expect_unsafe(t, make_zip({{name = "ok.txt", data = "fine"}, {name = name, data = "pwned"}}), .Zip)
	}
	// Traversal hidden in a ustar prefix, a GNU long name and a pax path.
	expect_unsafe(t, make_tar_gz({{name = "evil", data = "x", o = {prefix = "..", size = -1}}}), .Tar_Gz)
	expect_unsafe(t, make_tar_gz({{name = "././@LongLink", data = "../evil\x00", o = {typeflag = 'L', gnu = true, size = -1}}, {name = "harmless", data = "x", o = {gnu = true, size = -1}}}), .Tar_Gz)
	expect_unsafe(t, make_tar_gz({{name = "PaxHeaders/x", data = pax_record("path", "../../evil"), o = {typeflag = 'x', size = -1}}, {name = "harmless", data = "x"}}), .Tar_Gz)
	// Accepted: leading "./" and a "./" root entry, as GNU tar writes them.
	dir, out, err := extract_bytes(t, make_tar_gz({{name = "./", o = {typeflag = '5', mode = 0o755}}, {name = "./bin/", o = {typeflag = '5', mode = 0o755}}, {name = "./bin/x", data = "x", o = {mode = 0o755, size = -1}}}), .Tar_Gz)
	testing.expectf(t, err == nil, "./ prefix: %v", err)
	testing.expect(t, len(out.files) == 1 && out.files[0].path == "bin/x" && out.files[0].exec, "bin/x")
	os.remove_all(dir)
}

@(test)
test_links_and_special_files_are_refused :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	for typeflag in ([]byte{'1', '2', '3', '4', '6', '7', 'S', 'K', 'g', 'V', 'D'}) {
		expect_unsafe(t, make_tar_gz({{name = "ok.txt", data = "fine"}, {name = "link", data = "", o = {typeflag = typeflag, size = -1}}}), .Tar_Gz)
	}
	// A symlink to an absolute path, then a file "through" it.
	expect_unsafe(t, make_tar_gz({{name = "dir", o = {typeflag = '2', size = -1}}, {name = "dir/evil", data = "x"}}), .Tar_Gz)
	// Sparse file declared through pax.
	expect_unsafe(t, make_tar_gz({{name = "PaxHeaders/x", data = pax_record("GNU.sparse.size", "100"), o = {typeflag = 'x', size = -1}}, {name = "f", data = "x"}}), .Tar_Gz)
	// zip: Unix symlink and FIFO modes.
	expect_unsafe(t, make_zip({{name = "link", data = "/etc/passwd", host = 3, ext_attr = 0o120777 << 16}}), .Zip)
	expect_unsafe(t, make_zip({{name = "fifo", data = "", host = 3, ext_attr = 0o010644 << 16}}), .Zip)
	// zip: encrypted, unknown method, local name differs, bad CRC.
	expect_unsafe(t, make_zip({{name = "a", data = "x", flags = 1}}), .Zip)
	expect_unsafe(t, make_zip({{name = "a", data = "x", method = 12}}), .Zip)
	expect_unsafe(t, make_zip({{name = "a", data = "x", local_name = "../a"}}), .Zip)
	expect_unsafe(t, make_zip({{name = "a", data = "xyz", bad_crc = true}}), .Zip)
	expect_unsafe(t, make_zip({{name = "a", data = "xyz", deflate = true, bad_crc = true}}), .Zip)
	// Accepted: MS-DOS host (PowerShell ZipArchive), Unix regular file 0755.
	dir, out, err := extract_bytes(t, make_zip({{name = "bin/ham-bridge.exe", data = "MZ", deflate = true}, {name = "bin/tool", data = "#!", host = 3, ext_attr = 0o100755 << 16}, {name = "share/", host = 0, ext_attr = 0x10}}), .Zip)
	testing.expectf(t, err == nil, "zip: %v", err)
	testing.expect_value(t, len(out.files), 2)
	testing.expect(t, os.is_dir(pj(dir, "staging", "share")), "share/ dir")
	os.remove_all(dir)
}

@(test)
test_duplicates_and_type_conflicts_are_refused :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	expect_unsafe(t, make_tar_gz({{name = "bin/a", data = "1"}, {name = "bin/a", data = "2"}}), .Tar_Gz)
	expect_unsafe(t, make_tar_gz({{name = "bin/ham-bridge", data = "1"}, {name = "BIN/Ham-Bridge", data = "2"}}), .Tar_Gz)
	expect_unsafe(t, make_tar_gz({{name = "a", data = "file"}, {name = "a/b", data = "below a file"}}), .Tar_Gz)
	expect_unsafe(t, make_tar_gz({{name = "a", data = "file"}, {name = "a/", o = {typeflag = '5'}}}), .Tar_Gz)
	expect_unsafe(t, make_tar_gz({{name = "d/", o = {typeflag = '5'}}, {name = "D", data = "x"}}), .Tar_Gz)
	expect_unsafe(t, make_zip({{name = "x", data = "1"}, {name = "X", data = "2"}}), .Zip)
	// A directory listed twice is fine.
	dir, _, err := extract_bytes(t, make_tar_gz({{name = "d/", o = {typeflag = '5'}}, {name = "d/", o = {typeflag = '5'}}, {name = "d/f", data = "x"}}), .Tar_Gz)
	testing.expectf(t, err == nil, "dir twice: %v", err)
	os.remove_all(dir)
}

@(test)
test_oversized_archives_are_refused :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	// Declared size beyond the 512 MiB limit: refused at the header, nothing written.
	{
		hdr := build_tar_header("bin/huge", MAX_UNPACKED_BYTES + 1, {})
		tar_stream := make([dynamic]byte, context.temp_allocator)
		append(&tar_stream, ..hdr[:])
		dir, out, err := extract_bytes(t, gzip_stored(tar_stream[:]), .Tar_Gz)
		testing.expectf(t, error_code(err) == .Archive_Unsafe, "declared oversize: %v", err)
		testing.expect_value(t, out.bytes, 0)
		expect_contained(t, dir)
		os.remove_all(dir)
	}
	// Decompression bomb with the default 512 MiB limit: a small file, then
	// ~600 MiB of zeros after the end-of-archive marker. Stops at the cap.
	{
		tar_stream := make([dynamic]byte, context.temp_allocator)
		tar_append(&tar_stream, "small.txt", transmute([]byte)string("hello"))
		// Raw stream: stored (non-final) block with the tar header + data,
		// then a fixed-Huffman block of zeros (the end marker and the bomb).
		raw := make([dynamic]byte, context.temp_allocator)
		append(&raw, 0x00, byte(len(tar_stream)), byte(len(tar_stream) >> 8), byte(~u16(len(tar_stream))), byte(~u16(len(tar_stream)) >> 8))
		append(&raw, ..tar_stream[:])
		append(&raw, ..deflate_zeros(600 * 1024 * 1024 / 258))
		bomb := gzip_wrap(raw[:], 0, 0)
		testing.expectf(t, len(bomb) < 8 << 20, "bomb is small (%d bytes)", len(bomb))
		dir, _, err := extract_bytes(t, bomb, .Tar_Gz)
		testing.expectf(t, error_code(err) == .Archive_Unsafe && strings.contains(error_detail(err), "exceeds"), "bomb: %v", err)
		expect_contained(t, dir)
		os.remove_all(dir)
	}
	// The same shape against a small limit, inside one file's data.
	{
		limits := Limits{max_bytes = 64 * 1024, max_entries = 100}
		expect_unsafe(t, make_tar_gz({{name = "a", data = strings.repeat("z", 70 * 1024, context.temp_allocator)}}), .Tar_Gz, limits)
		expect_unsafe(t, make_tar_gz({{name = "a", data = strings.repeat("z", 40 * 1024, context.temp_allocator)}, {name = "b", data = strings.repeat("z", 40 * 1024, context.temp_allocator)}}), .Tar_Gz, limits)
		expect_unsafe(t, make_zip({{name = "a", data = strings.repeat("z", 70 * 1024, context.temp_allocator), deflate = true}}), .Zip, limits)
	}
	// zip entry inflating to more than its declared size (and the declared
	// total over the limit).
	expect_unsafe(t, make_zip({{name = "a", data = strings.repeat("z", 5000, context.temp_allocator), deflate = true, usize = 100}}), .Zip)
	expect_unsafe(t, make_zip({{name = "a", data = "z", usize = 0xfffffffe, deflate = true}}), .Zip)
	// Entry count.
	many := make([dynamic]Tar_File, context.temp_allocator)
	for i in 0 ..< 6 do append(&many, Tar_File{name = strings.concatenate({"f", strings.repeat("x", i + 1, context.temp_allocator)}, context.temp_allocator), data = "1"})
	expect_unsafe(t, make_tar_gz(many[:]), .Tar_Gz, Limits{max_bytes = 1 << 20, max_entries = 5})
	zmany := make([dynamic]Zip_File, context.temp_allocator)
	for f in many do append(&zmany, Zip_File{name = f.name, data = f.data})
	expect_unsafe(t, make_zip(zmany[:]), .Zip, Limits{max_bytes = 1 << 20, max_entries = 5})
}

@(test)
test_corrupt_containers_are_refused :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	// Flipped byte in a real archive: CRC, size or deflate error.
	for fixture in ([][]byte{FIXTURE_GNU_TGZ, FIXTURE_ZIP}) {
		kind := Archive_Kind.Zip if len(fixture) == len(FIXTURE_ZIP) && fixture[0] == 'P' else Archive_Kind.Tar_Gz
		for at in ([]int{len(fixture) / 3, len(fixture) / 2, len(fixture) - 12}) {
			b := slice.clone(fixture, context.temp_allocator)
			b[at] ~= 0x01
			expect_unsafe(t, b, kind)
		}
		expect_unsafe(t, fixture[:len(fixture) - 9], kind) // truncated
	}
	expect_unsafe(t, transmute([]byte)string("not an archive at all"), .Tar_Gz)
	expect_unsafe(t, transmute([]byte)string("not an archive at all, not even a zip one"), .Zip)
	// tar-level problems inside a valid gzip.
	expect_unsafe(t, make_tar_gz({{name = "a", data = "x", o = {bad_sum = true, size = -1}}}), .Tar_Gz)
	{
		tar_stream := make([dynamic]byte, context.temp_allocator)
		tar_append(&tar_stream, "a", transmute([]byte)string("x"))
		expect_unsafe(t, gzip_stored(tar_stream[:]), .Tar_Gz) // no end marker
		tar_end(&tar_stream)
		append(&tar_stream, 'j', 'u', 'n', 'k')
		expect_unsafe(t, gzip_stored(tar_stream[:]), .Tar_Gz) // data after the end marker
	}
	{
		tar_stream := make([dynamic]byte, context.temp_allocator)
		tar_append(&tar_stream, "a", transmute([]byte)string("x"))
		tar_end(&tar_stream)
		gz := gzip_stored(tar_stream[:])
		extra := slice.concatenate([][]byte{gz, gz}, context.temp_allocator)
		expect_unsafe(t, extra, .Tar_Gz) // a second gzip member
	}
	// zip with overlapping entries (two central records, one local entry).
	{
		z := make_zip({{name = "a", data = "xxxx"}, {name = "b", data = "yyyy"}})
		// Point b's central record at a's local header: names then differ.
		cd := bytes.index(z, []byte{0x50, 0x4b, 0x01, 0x02})
		second := cd + 1 + bytes.index(z[cd + 1:], []byte{0x50, 0x4b, 0x01, 0x02})
		b := slice.clone(z, context.temp_allocator)
		b[second + 42], b[second + 43], b[second + 44], b[second + 45] = 0, 0, 0, 0
		expect_unsafe(t, b, .Zip)
	}
}

// Optional: extract real published bundles. Set HEIMDALL_FETCH_REAL_BUNDLES to
// a directory holding heimdall-local-*.tar.gz / *.zip (e.g. from
// `gh release download v0.5.74 -p 'heimdall-local-*'`); each must extract
// cleanly and match what `tar -t` lists. Skipped when unset.
@(test)
test_real_release_bundles_extract :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	src := os.get_env("HEIMDALL_FETCH_REAL_BUNDLES", context.temp_allocator)
	if src == "" do return
	entries, err := os.read_all_directory_by_path(src, context.temp_allocator)
	testing.expectf(t, err == nil, "read %s", src)
	checked := 0
	for e in entries {
		kind, ok := archive_kind_for_asset(e.name)
		if !ok || !strings.has_prefix(e.name, "heimdall-local-") do continue
		dir := make_test_dir(t)
		staging := pj(dir, "staging")
		os.make_directory(staging)
		out, xerr := extract_archive(e.fullpath, staging, kind)
		testing.expectf(t, xerr == nil, "%s: %v", e.name, xerr)
		bin := "bin/ham-bridge.exe" if kind == .Zip else "bin/ham-bridge"
		found := false
		for f in out.files do if f.path == bin do found = true
		testing.expectf(t, found, "%s: %s extracted", e.name, bin)
		log.infof("%s: %d files, %d dirs, %d bytes, %d entries", e.name, len(out.files), len(out.dirs), out.bytes, out.entries)
		os.remove_all(dir)
		checked += 1
	}
	testing.expect(t, checked > 0, "no bundles found")
}
