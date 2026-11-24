package fetch

// Safe extraction of a release bundle into a staging directory, spec §14
// step 7. Fails closed with archive_unsafe on anything that is not plainly a
// tree of regular files and directories inside the staging root:
//
//   - formats: .tar.gz (ustar, GNU long names 'L', pax 'x' path/size) and .zip
//     (stored or deflate, one disk, no zip64, no encryption);
//   - entry types: regular files and directories only; symlinks, hard links,
//     devices, FIFOs, sparse files, pax global headers, GNU long link names
//     and anything unknown are refused;
//   - paths: relative, '/'-separated, printable ASCII without
//     < > : " | ? * \ ; no empty, '.' or '..' component, no component ending
//     in '.' or ' ' and no Windows device name (CON, NUL, COM1, ...), at most
//     MAX_PATH_BYTES bytes and MAX_PATH_DEPTH components; no two entries may
//     map to the same path when compared case-insensitively (macOS and Windows
//     file systems), and no file may sit where a directory is (or below a
//     file). The names the engine writes itself (tree.json, .complete,
//     release.json, release.json.minisig) are refused at the root;
//   - limits: at most MAX_ENTRIES archive entries and MAX_UNPACKED_BYTES of
//     decompressed output, enforced while decompressing (the tar stream as a
//     whole, every zip entry against its declared size), so a compression
//     bomb stops at the cap;
//   - integrity: tar header checksums, gzip CRC-32 + ISIZE, zip CRC-32 and
//     sizes, zip local headers must match the central directory and entries
//     must not overlap.
//
// Files are created with O_CREAT|O_EXCL below a staging directory the caller
// created fresh, so nothing that already exists is ever followed or
// overwritten. Every file is fsynced when it is closed. Modes are 0755 when
// the archive marks any execute bit, else 0644 (subject to the umask).

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:hash"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

Archive_Kind :: enum {
	Tar_Gz,
	Zip,
}

Limits :: struct {
	max_bytes:   i64,
	max_entries: int,
}

DEFAULT_LIMITS :: Limits {
	max_bytes   = MAX_UNPACKED_BYTES,
	max_entries = MAX_ENTRIES,
}

Extracted_File :: struct {
	path:   string, // relative, '/'-separated
	size:   i64,
	sha256: string, // 64 lower-case hex
	exec:   bool,
}

// Extracted lists what was written (temp-allocated).
Extracted :: struct {
	files:   [dynamic]Extracted_File,
	dirs:    [dynamic]string,
	bytes:   i64,
	entries: int,
}

// Names the engine writes at the tree root (spec §3); an archive may not.
RESERVED_ROOT_NAMES := [?]string{"tree.json", ".complete", "release.json", "release.json.minisig"}

archive_kind_for_asset :: proc(name: string) -> (Archive_Kind, bool) {
	lower := strings.to_lower(name, context.temp_allocator)
	if strings.has_suffix(lower, ".tar.gz") || strings.has_suffix(lower, ".tgz") do return .Tar_Gz, true
	if strings.has_suffix(lower, ".zip") do return .Zip, true
	return .Tar_Gz, false
}

// extract_archive unpacks archive_path into staging_dir, which must exist and
// be empty. On error the staging directory holds a partial tree; the caller
// deletes it (it is never renamed).
extract_archive :: proc(archive_path, staging_dir: string, kind: Archive_Kind, limits := DEFAULT_LIMITS) -> (out: Extracted, err: Error) {
	x := new(Extractor, context.temp_allocator)
	x.root = staging_dir
	x.limits = limits
	x.seen = make(map[string]Seen, 256, context.temp_allocator)
	x.out.files = make([dynamic]Extracted_File, context.temp_allocator)
	x.out.dirs = make([dynamic]string, context.temp_allocator)
	defer close_current(x, false)

	f, oerr := os.open(archive_path)
	if oerr != nil do return out, fail(.Fs_Error, "open %s: %v", archive_path, oerr)
	defer os.close(f)

	switch kind {
	case .Tar_Gz:
		extract_tar_gz(x, f) or_return
	case .Zip:
		extract_zip(x, f) or_return
	}
	return x.out, nil
}

// ---------------------------------------------------------------------------
// Entry paths

@(private)
WINDOWS_DEVICE_NAMES := [?]string{"con", "prn", "aux", "nul", "conin$", "conout$"}

@(private)
is_windows_device :: proc(component: string) -> bool {
	base := component
	if i := strings.index_byte(base, '.'); i >= 0 do base = base[:i]
	lower := strings.to_lower(base, context.temp_allocator)
	for d in WINDOWS_DEVICE_NAMES do if lower == d do return true
	if len(lower) == 4 && (strings.has_prefix(lower, "com") || strings.has_prefix(lower, "lpt")) {
		c := lower[3]
		if c >= '0' && c <= '9' do return true
	}
	return false
}

// clean_entry_path validates an archive member name. `root` is true for the
// archive's own root entry ("./"), which is skipped.
clean_entry_path :: proc(name: string) -> (path: string, is_dir: bool, root: bool, reason: string) {
	p := name
	for strings.has_prefix(p, "./") do p = p[2:]
	if p == "" || p == "." do return "", true, true, ""
	if strings.has_suffix(p, "/") {
		is_dir = true
		p = p[:len(p) - 1]
	}
	if p == "" do return "", false, false, "empty path"
	if len(p) > MAX_PATH_BYTES do return "", false, false, "path too long"
	if p[0] == '/' do return "", false, false, "absolute path"
	for c in transmute([]byte)p {
		switch c {
		case 0 ..< 0x20, 0x7f ..= 0xff:
			return "", false, false, "non-printable or non-ASCII byte in path"
		case '\\':
			return "", false, false, "backslash in path"
		case ':':
			return "", false, false, "colon in path (drive letter or stream)"
		case '<', '>', '"', '|', '?', '*':
			return "", false, false, "character not allowed on Windows"
		}
	}
	depth := 0
	rest := p
	for component in strings.split_iterator(&rest, "/") {
		depth += 1
		switch component {
		case "":
			return "", false, false, "empty path component"
		case ".", "..":
			return "", false, false, "'.' or '..' path component"
		}
		last := component[len(component) - 1]
		if last == '.' || last == ' ' do return "", false, false, "path component ends in '.' or ' '"
		if is_windows_device(component) do return "", false, false, "Windows device name in path"
	}
	if depth > MAX_PATH_DEPTH do return "", false, false, "path too deep"
	if depth == 1 {
		for r in RESERVED_ROOT_NAMES {
			if strings.equal_fold(p, r) do return "", false, false, "reserved name at the tree root"
		}
	}
	return p, is_dir, false, ""
}

// ---------------------------------------------------------------------------
// Writing entries

@(private)
Seen :: enum u8 {
	File,
	Dir,
}

@(private)
Extractor :: struct {
	root:         string,
	limits:       Limits,
	seen:         map[string]Seen, // ASCII-lower-cased path -> kind
	out:          Extracted,
	// Current file being written.
	cur:          ^os.File,
	cur_path:     string,
	cur_exec:     bool,
	cur_written:  i64,
	cur_sha:      sha2.Context_256,
	cur_crc:      u32,
	write_failed: Error,
}

@(private)
fold :: proc(p: string) -> string {
	return strings.to_lower(p, context.temp_allocator)
}

@(private)
native_join :: proc(root, rel: string) -> string {
	when ODIN_OS == .Windows {
		r, _ := strings.replace_all(rel, "/", "\\", context.temp_allocator)
		return strings.concatenate({root, "\\", r}, context.temp_allocator)
	} else {
		return strings.concatenate({root, "/", rel}, context.temp_allocator)
	}
}

@(private)
DIR_PERMS :: os.Permissions{.Read_User, .Write_User, .Execute_User, .Read_Group, .Execute_Group, .Read_Other, .Execute_Other}
@(private)
EXEC_PERMS :: DIR_PERMS
@(private)
FILE_PERMS :: os.Permissions{.Read_User, .Write_User, .Read_Group, .Read_Other}

@(private)
count_entry :: proc(x: ^Extractor) -> Error {
	x.out.entries += 1
	if x.out.entries > x.limits.max_entries do return fail(.Archive_Unsafe, "more than %d entries", x.limits.max_entries)
	return nil
}

// ensure_dir records and creates directory `rel` and its parents.
@(private)
ensure_dir :: proc(x: ^Extractor, rel: string) -> Error {
	key := fold(rel)
	if kind, has := x.seen[key]; has {
		if kind == .File do return fail(.Archive_Unsafe, "%s: directory where a file is", rel)
		return nil
	}
	if i := strings.last_index_byte(rel, '/'); i > 0 do ensure_dir(x, rel[:i]) or_return
	x.seen[strings.clone(key, context.temp_allocator)] = .Dir
	if e := os.make_directory(native_join(x.root, rel), DIR_PERMS); e != nil {
		return fail(.Fs_Error, "mkdir %s: %v", rel, e)
	}
	append(&x.out.dirs, strings.clone(rel, context.temp_allocator))
	return nil
}

@(private)
begin_file :: proc(x: ^Extractor, rel: string, size: i64, exec: bool) -> Error {
	key := fold(rel)
	if _, has := x.seen[key]; has do return fail(.Archive_Unsafe, "%s: duplicate entry (case-insensitive)", rel)
	if size < 0 do return fail(.Archive_Unsafe, "%s: negative size", rel)
	if x.out.bytes + size > x.limits.max_bytes {
		return fail(.Archive_Unsafe, "uncompressed size exceeds %d bytes", x.limits.max_bytes)
	}
	if i := strings.last_index_byte(rel, '/'); i > 0 do ensure_dir(x, rel[:i]) or_return
	x.seen[strings.clone(key, context.temp_allocator)] = .File
	f, e := os.open(native_join(x.root, rel), {.Write, .Create, .Excl}, EXEC_PERMS if exec else FILE_PERMS)
	if e != nil {
		if e == os.General_Error.Exist do return fail(.Archive_Unsafe, "%s: already exists", rel)
		return fail(.Fs_Error, "create %s: %v", rel, e)
	}
	x.cur = f
	x.cur_path = strings.clone(rel, context.temp_allocator)
	x.cur_exec = exec
	x.cur_written = 0
	x.cur_crc = 0
	sha2.init_256(&x.cur_sha)
	return nil
}

@(private)
write_current :: proc(x: ^Extractor, data: []byte) -> Error {
	if x.out.bytes + i64(len(data)) > x.limits.max_bytes {
		return fail(.Archive_Unsafe, "uncompressed size exceeds %d bytes", x.limits.max_bytes)
	}
	n, e := os.write(x.cur, data)
	if e != nil || n != len(data) do return fail(.Fs_Error, "write %s: %v", x.cur_path, e)
	sha2.update(&x.cur_sha, data)
	x.cur_crc = hash.crc32(data, x.cur_crc)
	x.cur_written += i64(len(data))
	x.out.bytes += i64(len(data))
	return nil
}

// close_current fsyncs and closes the current file; `record` adds it to the
// result.
@(private)
close_current :: proc(x: ^Extractor, record: bool) -> Error {
	if x.cur == nil do return nil
	f := x.cur
	x.cur = nil
	if !record {
		os.close(f)
		return nil
	}
	if e := os.sync(f); e != nil {
		os.close(f)
		return fail(.Fs_Error, "fsync %s: %v", x.cur_path, e)
	}
	if e := os.close(f); e != nil do return fail(.Fs_Error, "close %s: %v", x.cur_path, e)
	digest: [sha2.DIGEST_SIZE_256]byte
	sha2.final(&x.cur_sha, digest[:])
	append(&x.out.files, Extracted_File{path = x.cur_path, size = x.cur_written, sha256 = string(hex.encode(digest[:], context.temp_allocator)), exec = x.cur_exec})
	return nil
}

// ---------------------------------------------------------------------------
// tar.gz

@(private)
Tar_State :: enum {
	Header,
	File_Data,
	Meta_Data, // pax 'x' or GNU 'L' payload
	Padding,
	End,
}

@(private)
MAX_META_BYTES :: 64 * 1024

@(private)
Tar :: struct {
	x:           ^Extractor,
	state:       Tar_State,
	hdr:         [512]byte,
	hdr_fill:    int,
	remaining:   i64,
	padding:     int,
	zero_blocks: int,
	meta_kind:   byte,
	meta:        [dynamic]byte,
	// Overrides for the next entry from pax / GNU headers.
	next_path:   string,
	next_size:   i64, // -1 = none
	err:         Error,
}

@(private)
tar_sink :: proc(user: rawptr, data: []byte) -> bool {
	t := (^Tar)(user)
	if t.err != nil do return false
	t.err = tar_feed(t, data)
	return t.err == nil
}

@(private)
extract_tar_gz :: proc(x: ^Extractor, f: ^os.File) -> Error {
	buf := make([]byte, READ_CHUNK, context.temp_allocator)
	br: Bit_Reader
	bit_reader_init(&br, os.to_reader(f), buf)
	read_gzip_header(&br) or_return

	t := new(Tar, context.temp_allocator)
	t.x = x
	t.next_size = -1
	t.meta = make([dynamic]byte, context.temp_allocator)
	crc_sink := Gzip_Crc{inner = Sink{write = tar_sink, user = t}}
	total, res := inflate(&br, Sink{write = gzip_crc_write, user = &crc_sink}, x.limits.max_bytes)
	if t.err != nil do return t.err
	switch res {
	case .Ok:
	case .Too_Large:
		return fail(.Archive_Unsafe, "uncompressed size exceeds %d bytes", x.limits.max_bytes)
	case .Corrupt, .Truncated, .Sink_Failed:
		return fail(.Archive_Unsafe, "gzip stream is corrupt or truncated (%v)", res)
	case .Read_Error:
		return fail(.Fs_Error, "read error while decompressing")
	}
	trailer: [8]byte
	if !read_full(&br, trailer[:]) do return fail(.Archive_Unsafe, "gzip trailer missing")
	crc := u32(trailer[0]) | u32(trailer[1]) << 8 | u32(trailer[2]) << 16 | u32(trailer[3]) << 24
	isize := u32(trailer[4]) | u32(trailer[5]) << 8 | u32(trailer[6]) << 16 | u32(trailer[7]) << 24
	if crc != crc_sink.crc do return fail(.Archive_Unsafe, "gzip CRC-32 mismatch")
	if isize != u32(total) do return fail(.Archive_Unsafe, "gzip size mismatch")
	if _, more := read_byte(&br); more do return fail(.Archive_Unsafe, "data after the gzip member")
	if t.state != .End do return fail(.Archive_Unsafe, "tar archive is truncated (no end-of-archive marker)")
	return nil
}

@(private)
Gzip_Crc :: struct {
	inner: Sink,
	crc:   u32,
}

@(private)
gzip_crc_write :: proc(user: rawptr, data: []byte) -> bool {
	g := (^Gzip_Crc)(user)
	g.crc = hash.crc32(data, g.crc)
	return g.inner.write(g.inner.user, data)
}

@(private)
read_gzip_header :: proc(br: ^Bit_Reader) -> Error {
	h: [10]byte
	if !read_full(br, h[:]) do return fail(.Archive_Unsafe, "not a gzip file")
	if h[0] != 0x1f || h[1] != 0x8b || h[2] != 8 do return fail(.Archive_Unsafe, "not a gzip/deflate file")
	flg := h[3]
	if flg & 0xe0 != 0 do return fail(.Archive_Unsafe, "gzip reserved flags set")
	if flg & 0x04 != 0 { 	// FEXTRA
		l: [2]byte
		if !read_full(br, l[:]) do return fail(.Archive_Unsafe, "gzip header truncated")
		for _ in 0 ..< int(l[0]) | int(l[1]) << 8 {
			if _, ok := read_byte(br); !ok do return fail(.Archive_Unsafe, "gzip header truncated")
		}
	}
	for bit in ([]byte{0x08, 0x10}) { 	// FNAME, FCOMMENT: zero-terminated
		if flg & bit == 0 do continue
		for n := 0;; n += 1 {
			b, ok := read_byte(br)
			if !ok || n > 4096 do return fail(.Archive_Unsafe, "gzip header truncated")
			if b == 0 do break
		}
	}
	if flg & 0x02 != 0 { 	// FHCRC
		c: [2]byte
		if !read_full(br, c[:]) do return fail(.Archive_Unsafe, "gzip header truncated")
	}
	return nil
}

@(private)
octal_field :: proc(field: []byte) -> (v: i64, ok: bool) {
	if len(field) > 0 && field[0] & 0x80 != 0 do return 0, false // base-256: far beyond any limit
	s := string(field)
	if i := strings.index_byte(s, 0); i >= 0 do s = s[:i]
	s = strings.trim(s, " ")
	if s == "" do return 0, true
	for c in transmute([]byte)s do if c < '0' || c > '7' do return 0, false
	u, parsed := strconv.parse_u64_of_base(s, 8)
	if !parsed || u > u64(max(i64)) do return 0, false
	return i64(u), true
}

@(private)
cstring_field :: proc(field: []byte) -> string {
	s := string(field)
	if i := strings.index_byte(s, 0); i >= 0 do s = s[:i]
	return s
}

@(private)
tar_feed :: proc(t: ^Tar, data: []byte) -> Error {
	d := data
	for len(d) > 0 {
		switch t.state {
		case .Header:
			n := min(512 - t.hdr_fill, len(d))
			copy(t.hdr[t.hdr_fill:], d[:n])
			t.hdr_fill += n
			d = d[n:]
			if t.hdr_fill == 512 {
				t.hdr_fill = 0
				tar_header(t) or_return
			}
		case .File_Data:
			n := int(min(t.remaining, i64(len(d))))
			write_current(t.x, d[:n]) or_return
			t.remaining -= i64(n)
			d = d[n:]
			if t.remaining == 0 {
				close_current(t.x, true) or_return
				t.state = .Padding if t.padding > 0 else .Header
			}
		case .Meta_Data:
			n := int(min(t.remaining, i64(len(d))))
			append(&t.meta, ..d[:n])
			t.remaining -= i64(n)
			d = d[n:]
			if t.remaining == 0 {
				tar_meta(t) or_return
				t.state = .Padding if t.padding > 0 else .Header
			}
		case .Padding:
			n := min(t.padding, len(d))
			t.padding -= n
			d = d[n:]
			if t.padding == 0 do t.state = .Header
		case .End:
			// Everything after the end-of-archive marker must be zero padding.
			for b in d do if b != 0 do return fail(.Archive_Unsafe, "data after the tar end-of-archive marker")
			d = nil
		}
	}
	return nil
}

@(private)
tar_header :: proc(t: ^Tar) -> Error {
	h := t.hdr[:]
	all_zero := true
	for b in h do if b != 0 {
		all_zero = false
		break
	}
	if all_zero {
		t.zero_blocks += 1
		if t.zero_blocks == 2 {
			if t.next_path != "" || t.next_size >= 0 do return fail(.Archive_Unsafe, "pax/GNU header without an entry")
			t.state = .End
		}
		return nil
	}
	if t.zero_blocks != 0 do return fail(.Archive_Unsafe, "entry after a zero block")
	count_entry(t.x) or_return

	// Checksum: bytes 148..156 count as spaces. Accept the unsigned sum (POSIX)
	// or the signed one (historic tars).
	want, ok := octal_field(h[148:156])
	if !ok do return fail(.Archive_Unsafe, "bad tar header checksum field")
	usum, ssum: i64
	for b, i in h {
		v := b if i < 148 || i >= 156 else ' '
		usum += i64(v)
		ssum += i64(i8(v))
	}
	if want != usum && want != ssum do return fail(.Archive_Unsafe, "tar header checksum mismatch")

	typeflag := h[156]
	size, size_ok := octal_field(h[124:136])
	if !size_ok do return fail(.Archive_Unsafe, "bad tar size field")
	mode, mode_ok := octal_field(h[100:108])
	if !mode_ok do return fail(.Archive_Unsafe, "bad tar mode field")

	name := cstring_field(h[0:100])
	if string(h[257:263]) == "ustar\x00" { 	// POSIX ustar: prefix field
		prefix := cstring_field(h[345:500])
		if prefix != "" do name = strings.concatenate({prefix, "/", name}, context.temp_allocator)
	}

	switch typeflag {
	case 'x', 'L':
		if size > MAX_META_BYTES do return fail(.Archive_Unsafe, "pax/GNU header too large")
		t.meta_kind = typeflag
		clear(&t.meta)
		t.remaining = size
		t.padding = int((512 - size % 512) % 512)
		t.state = .Meta_Data
		if size == 0 {
			tar_meta(t) or_return
			t.state = .Padding if t.padding > 0 else .Header
		}
		return nil
	case '0', 0, '5':
	case '1':
		return fail(.Archive_Unsafe, "%s: hard link", name)
	case '2':
		return fail(.Archive_Unsafe, "%s: symbolic link", name)
	case '3', '4':
		return fail(.Archive_Unsafe, "%s: device file", name)
	case '6':
		return fail(.Archive_Unsafe, "%s: FIFO", name)
	case 'g':
		return fail(.Archive_Unsafe, "pax global header")
	case 'K':
		return fail(.Archive_Unsafe, "GNU long link name")
	case:
		return fail(.Archive_Unsafe, "%s: unsupported tar entry type %q", name, rune(typeflag))
	}

	if t.next_path != "" do name = t.next_path
	if t.next_size >= 0 do size = t.next_size
	t.next_path = ""
	t.next_size = -1

	path, is_dir, is_root, reason := clean_entry_path(name)
	if reason != "" do return fail(.Archive_Unsafe, "%q: %s", name, reason)
	if typeflag == '5' do is_dir = true
	if is_dir {
		if size != 0 do return fail(.Archive_Unsafe, "%s: directory with data", name)
		if !is_root do ensure_dir(t.x, path) or_return
		t.state = .Header
		return nil
	}
	if is_root do return fail(.Archive_Unsafe, "%q: file at the archive root name", name)
	begin_file(t.x, path, size, mode & 0o111 != 0) or_return
	t.remaining = size
	t.padding = int((512 - size % 512) % 512)
	if size == 0 {
		close_current(t.x, true) or_return
		t.state = .Padding if t.padding > 0 else .Header
	} else {
		t.state = .File_Data
	}
	return nil
}

// tar_meta applies a pax 'x' or GNU 'L' payload to the next entry.
@(private)
tar_meta :: proc(t: ^Tar) -> Error {
	data := string(t.meta[:])
	if t.meta_kind == 'L' {
		name := data
		if i := strings.index_byte(name, 0); i >= 0 do name = name[:i]
		if name == "" do return fail(.Archive_Unsafe, "empty GNU long name")
		t.next_path = strings.clone(name, context.temp_allocator)
		return nil
	}
	// pax records: "<len> <key>=<value>\n", len counting the whole record.
	for len(data) > 0 {
		sp := strings.index_byte(data, ' ')
		if sp <= 0 do return fail(.Archive_Unsafe, "malformed pax header")
		n, n_ok := strconv.parse_int(data[:sp], 10)
		if !n_ok || n <= sp + 1 || n > len(data) || data[n - 1] != '\n' do return fail(.Archive_Unsafe, "malformed pax record")
		record := data[sp + 1:n - 1]
		data = data[n:]
		eq := strings.index_byte(record, '=')
		if eq <= 0 do return fail(.Archive_Unsafe, "malformed pax record")
		key, value := record[:eq], record[eq + 1:]
		switch {
		case key == "path":
			if value == "" do return fail(.Archive_Unsafe, "empty pax path")
			t.next_path = strings.clone(value, context.temp_allocator)
		case key == "size":
			v, v_ok := strconv.parse_i64_of_base(value, 10)
			if !v_ok || v < 0 do return fail(.Archive_Unsafe, "bad pax size")
			t.next_size = v
		case strings.has_prefix(key, "GNU.sparse."):
			return fail(.Archive_Unsafe, "sparse file")
		case:
		// linkpath, mtime, uid, gid, uname, gname, SCHILY.*, LIBARCHIVE.*:
		// irrelevant for regular files and directories.
		}
	}
	return nil
}

// ---------------------------------------------------------------------------
// zip

@(private)
le16 :: proc(b: []byte) -> u32 {return u32(b[0]) | u32(b[1]) << 8}
@(private)
le32 :: proc(b: []byte) -> u32 {return u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24}

@(private)
Zip_Entry :: struct {
	name:        string,
	path:        string,
	is_dir:      bool,
	is_root:     bool,
	exec:        bool,
	method:      u32,
	crc:         u32,
	csize:       i64,
	usize:       i64,
	header_off:  i64,
	data_off:    i64,
}

@(private)
MAX_CENTRAL_DIRECTORY :: 16 << 20

@(private)
read_at :: proc(f: ^os.File, off: i64, dst: []byte) -> bool {
	n, e := os.read_at(f, dst, off)
	return e == nil && n == len(dst)
}

@(private)
extract_zip :: proc(x: ^Extractor, f: ^os.File) -> Error {
	size, serr := os.file_size(f)
	if serr != nil do return fail(.Fs_Error, "stat archive: %v", serr)
	if size < 22 do return fail(.Archive_Unsafe, "not a zip file")

	// End of central directory: the last 22..65557 bytes.
	tail_len := min(size, 22 + 65535)
	tail := make([]byte, tail_len, context.temp_allocator)
	if !read_at(f, size - tail_len, tail) do return fail(.Fs_Error, "read archive tail")
	eocd := -1
	for i := len(tail) - 22; i >= 0; i -= 1 {
		if le32(tail[i:]) == 0x06054b50 && i + 22 + int(le16(tail[i + 20:])) == len(tail) {
			eocd = i
			break
		}
	}
	if eocd < 0 do return fail(.Archive_Unsafe, "zip end of central directory not found")
	e := tail[eocd:]
	disk, cd_disk := le16(e[4:]), le16(e[6:])
	n_disk, n_total := le16(e[8:]), le16(e[10:])
	cd_size, cd_off := i64(le32(e[12:])), i64(le32(e[16:]))
	if n_total == 0xffff || cd_size == 0xffffffff || cd_off == 0xffffffff do return fail(.Archive_Unsafe, "zip64 archives are not supported")
	if disk != 0 || cd_disk != 0 || n_disk != n_total do return fail(.Archive_Unsafe, "multi-disk zip")
	eocd_off := size - tail_len + i64(eocd)
	if cd_off + cd_size != eocd_off do return fail(.Archive_Unsafe, "zip central directory is not where the end record says")
	if cd_size > MAX_CENTRAL_DIRECTORY do return fail(.Archive_Unsafe, "zip central directory too large")
	if int(n_total) > x.limits.max_entries do return fail(.Archive_Unsafe, "more than %d entries", x.limits.max_entries)

	cd := make([]byte, cd_size, context.temp_allocator)
	if !read_at(f, cd_off, cd) do return fail(.Fs_Error, "read central directory")

	entries := make([dynamic]Zip_Entry, 0, int(n_total), context.temp_allocator)
	declared: i64
	p := cd
	for _ in 0 ..< n_total {
		if len(p) < 46 || le32(p) != 0x02014b50 do return fail(.Archive_Unsafe, "bad zip central directory header")
		made_by_host := (le16(p[4:]) >> 8) & 0xff
		flags := le16(p[8:])
		ze: Zip_Entry
		ze.method = le16(p[10:])
		ze.crc = le32(p[16:])
		ze.csize = i64(le32(p[20:]))
		ze.usize = i64(le32(p[24:]))
		name_len, extra_len, comment_len := int(le16(p[28:])), int(le16(p[30:])), int(le16(p[32:]))
		disk_start := le16(p[34:])
		ext_attr := le32(p[38:])
		ze.header_off = i64(le32(p[42:]))
		if len(p) < 46 + name_len + extra_len + comment_len do return fail(.Archive_Unsafe, "truncated zip central directory")
		ze.name = string(p[46:46 + name_len])
		p = p[46 + name_len + extra_len + comment_len:]

		if flags & 0x41 != 0 do return fail(.Archive_Unsafe, "%q: encrypted zip entry", ze.name)
		if ze.method != 0 && ze.method != 8 do return fail(.Archive_Unsafe, "%q: unsupported compression method %d", ze.name, ze.method)
		if disk_start != 0 do return fail(.Archive_Unsafe, "multi-disk zip")
		if ze.csize == 0xffffffff || ze.usize == 0xffffffff || ze.header_off == 0xffffffff do return fail(.Archive_Unsafe, "zip64 entry")

		path, is_dir, is_root, reason := clean_entry_path(ze.name)
		if reason != "" do return fail(.Archive_Unsafe, "%q: %s", ze.name, reason)
		if made_by_host == 3 || made_by_host == 19 { 	// Unix, OS X: st_mode in the high half
			mode := ext_attr >> 16
			switch mode & 0o170000 {
			case 0, 0o100000:
			case 0o040000:
				is_dir = true
			case 0o120000:
				return fail(.Archive_Unsafe, "%q: symbolic link", ze.name)
			case:
				return fail(.Archive_Unsafe, "%q: special file", ze.name)
			}
			ze.exec = mode & 0o111 != 0
		} else if ext_attr & 0x10 != 0 { 	// MS-DOS directory attribute
			is_dir = true
		}
		if is_dir && ze.usize != 0 do return fail(.Archive_Unsafe, "%q: directory with data", ze.name)
		if !is_dir && is_root do return fail(.Archive_Unsafe, "%q: file at the archive root name", ze.name)
		if ze.method == 0 && ze.csize != ze.usize do return fail(.Archive_Unsafe, "%q: stored entry size mismatch", ze.name)
		ze.path, ze.is_dir, ze.is_root = path, is_dir, is_root
		declared += ze.usize
		if declared > x.limits.max_bytes do return fail(.Archive_Unsafe, "uncompressed size exceeds %d bytes", x.limits.max_bytes)
		append(&entries, ze)
	}

	// Local headers must match and entries must not overlap.
	for &ze in entries {
		lh: [30]byte
		if ze.header_off + 30 > cd_off || !read_at(f, ze.header_off, lh[:]) || le32(lh[:]) != 0x04034b50 {
			return fail(.Archive_Unsafe, "%q: bad local header", ze.name)
		}
		lname_len, lextra_len := i64(le16(lh[26:])), i64(le16(lh[28:]))
		if le16(lh[8:]) != ze.method do return fail(.Archive_Unsafe, "%q: local header method differs", ze.name)
		lname := make([]byte, lname_len, context.temp_allocator)
		if !read_at(f, ze.header_off + 30, lname) || string(lname) != ze.name {
			return fail(.Archive_Unsafe, "%q: local header name differs", ze.name)
		}
		ze.data_off = ze.header_off + 30 + lname_len + lextra_len
		if ze.data_off + ze.csize > cd_off do return fail(.Archive_Unsafe, "%q: data runs into the central directory", ze.name)
	}
	by_offset := slice.clone(entries[:], context.temp_allocator)
	slice.sort_by(by_offset, proc(a, b: Zip_Entry) -> bool {return a.header_off < b.header_off})
	for i in 1 ..< len(by_offset) {
		prev := by_offset[i - 1]
		if prev.data_off + prev.csize > by_offset[i].header_off do return fail(.Archive_Unsafe, "overlapping zip entries")
	}

	buf := make([]byte, READ_CHUNK, context.temp_allocator)
	for ze in entries {
		count_entry(x) or_return
		if ze.is_dir {
			if !ze.is_root do ensure_dir(x, ze.path) or_return
			continue
		}
		begin_file(x, ze.path, ze.usize, ze.exec) or_return
		if _, e := os.seek(f, ze.data_off, .Start); e != nil do return fail(.Fs_Error, "seek: %v", e)
		br: Bit_Reader
		bit_reader_init(&br, os.to_reader(f), buf, ze.csize)
		if ze.method == 0 {
			chunk: [4096]byte
			left := ze.usize
			for left > 0 {
				n := int(min(left, i64(len(chunk))))
				if !read_full(&br, chunk[:n]) do return fail(.Archive_Unsafe, "%q: truncated", ze.name)
				write_current(x, chunk[:n]) or_return
				left -= i64(n)
			}
		} else {
			ws := Zip_Write{x = x}
			total, res := inflate(&br, Sink{write = zip_write, user = &ws}, ze.usize)
			if ws.err != nil do return ws.err
			switch res {
			case .Ok:
				if total != ze.usize do return fail(.Archive_Unsafe, "%q: size differs from the central directory", ze.name)
			case .Too_Large:
				return fail(.Archive_Unsafe, "%q: larger than its declared size", ze.name)
			case .Corrupt, .Truncated, .Sink_Failed:
				return fail(.Archive_Unsafe, "%q: corrupt deflate data (%v)", ze.name, res)
			case .Read_Error:
				return fail(.Fs_Error, "read error")
			}
		}
		if x.cur_crc != ze.crc do return fail(.Archive_Unsafe, "%q: CRC-32 mismatch", ze.name)
		close_current(x, true) or_return
	}
	return nil
}

@(private)
Zip_Write :: struct {
	x:   ^Extractor,
	err: Error,
}

@(private)
zip_write :: proc(user: rawptr, data: []byte) -> bool {
	w := (^Zip_Write)(user)
	w.err = write_current(w.x, data)
	return w.err == nil
}
