package fetch

// Bounded downloads (spec §14 steps 1 and 6, W9).
//
// The transport is injected: Download_Proc performs one GET (following
// redirects to GitHub's asset storage is the transport's business) and hands
// the body to the sink in chunks, stopping as soon as the sink returns false.
// URLs are built here from the release tag and asset name, never taken from
// the hub or from API data, and always point at this repository's release
// download path (REQ-SRC-1).

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:io"
import "core:os"
import "core:strings"

REPO :: "tanmayv/heimdall-agent-manager"
DOWNLOAD_PREFIX :: "https://github.com/" + REPO + "/releases/download/"

// Download_Proc returns the HTTP status (0 when the request failed before a
// status, or was aborted by the sink).
Download_Proc :: proc(user: rawptr, url: string, sink: Sink) -> (status: int)

Downloader :: struct {
	get:  Download_Proc,
	user: rawptr,
}

// asset_url is the release download URL of `asset` in release `tag`.
asset_url :: proc(tag, asset: string) -> (url: string, err: Error) {
	if !valid_tag(tag) do return "", fail(.Manifest_Mismatch, "invalid release tag %q", tag)
	if !valid_asset_name(asset) do return "", fail(.Manifest_Mismatch, "invalid asset name %q", asset)
	return strings.concatenate({DOWNLOAD_PREFIX, tag, "/", asset}, context.temp_allocator), nil
}

@(private)
Memory_Sink :: struct {
	buf:      [dynamic]byte,
	cap:      int,
	exceeded: bool,
}

@(private)
memory_sink_write :: proc(user: rawptr, data: []byte) -> bool {
	m := (^Memory_Sink)(user)
	if len(m.buf) + len(data) > m.cap {
		m.exceeded = true
		return false
	}
	append(&m.buf, ..data)
	return true
}

// download_small fetches a small asset (manifest, signature) into memory,
// refusing more than `cap` bytes (temp-allocated).
download_small :: proc(d: Downloader, url: string, cap: int) -> (data: []byte, err: Error) {
	if d.get == nil do return nil, fail(.Download_Failed, "no downloader")
	m := Memory_Sink{buf = make([dynamic]byte, 0, min(cap, 64 * 1024), context.temp_allocator), cap = cap}
	status := d.get(d.user, url, Sink{write = memory_sink_write, user = &m})
	if m.exceeded do return nil, fail(.Download_Failed, "%s: larger than %d bytes", url, cap)
	if status != 200 do return nil, fail(.Download_Failed, "%s: HTTP status %d", url, status)
	return m.buf[:], nil
}

@(private)
File_Sink :: struct {
	f:        ^os.File,
	limit:    i64,
	written:  i64,
	sha:      sha2.Context_256,
	exceeded: bool,
	write_err: os.Error,
}

@(private)
file_sink_write :: proc(user: rawptr, data: []byte) -> bool {
	s := (^File_Sink)(user)
	if s.written + i64(len(data)) > s.limit {
		s.exceeded = true // abort as soon as the manifest size is passed (§14 step 6)
		return false
	}
	n, e := os.write(s.f, data)
	if e != nil || n != len(data) {
		s.write_err = e if e != nil else io.Error.Short_Write
		return false
	}
	sha2.update(&s.sha, data)
	s.written += i64(len(data))
	return true
}

@(private)
digest_hex :: proc(ctx: ^sha2.Context_256) -> string {
	d: [sha2.DIGEST_SIZE_256]byte
	sha2.final(ctx, d[:])
	return string(hex.encode(d[:], context.temp_allocator))
}

// download_bundle streams the bundle to <dir>/<name>.part, checks the exact
// size and SHA-256 from the verified manifest, fsyncs, and only then renames
// it to <dir>/<name> (W9). Any failure deletes the .part file.
download_bundle :: proc(d: Downloader, m: ^Manifest, dir: string) -> (path: string, err: Error) {
	if d.get == nil do return "", fail(.Download_Failed, "no downloader")
	url := asset_url(m.tag, m.asset) or_return
	final_path := native_join(dir, m.asset)
	part := strings.concatenate({final_path, ".part"}, context.temp_allocator)
	os.remove(part) // J5: restart, no Range resume
	f, oerr := os.open(part, {.Write, .Create, .Excl}, FILE_PERMS)
	if oerr != nil do return "", fail(.Fs_Error, "create %s: %v", part, oerr)
	s := File_Sink{f = f, limit = m.size}
	sha2.init_256(&s.sha)
	status := d.get(d.user, url, Sink{write = file_sink_write, user = &s})
	sync_err := os.sync(f)
	os.close(f)
	defer if err != nil do os.remove(part)
	switch {
	case s.write_err != nil:
		return "", fail(.Fs_Error, "write %s: %v", part, s.write_err)
	case s.exceeded:
		return "", fail(.Bundle_Mismatch, "%s: more than the manifest's %d bytes", m.asset, m.size)
	case status != 200:
		return "", fail(.Download_Failed, "%s: HTTP status %d", url, status)
	case sync_err != nil:
		return "", fail(.Fs_Error, "fsync %s: %v", part, sync_err)
	case s.written != m.size:
		return "", fail(.Bundle_Mismatch, "%s: %d bytes, manifest says %d", m.asset, s.written, m.size)
	}
	if got := digest_hex(&s.sha); got != m.sha256 {
		return "", fail(.Bundle_Mismatch, "%s: SHA-256 %s, manifest says %s", m.asset, got, m.sha256)
	}
	os.remove(final_path)
	if e := os.rename(part, final_path); e != nil do return "", fail(.Fs_Error, "rename %s: %v", part, e)
	return final_path, nil
}

// verify_bundle_file checks a bundle already on disk (J6 re-verification,
// `repair` with a caller-supplied bundle, §16) against the manifest.
verify_bundle_file :: proc(path: string, m: ^Manifest) -> Error {
	f, oerr := os.open(path)
	if oerr != nil do return fail(.Fs_Error, "open %s: %v", path, oerr)
	defer os.close(f)
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	buf := make([]byte, READ_CHUNK, context.temp_allocator)
	total: i64
	for {
		n, e := os.read(f, buf)
		if n > 0 {
			total += i64(n)
			if total > m.size do return fail(.Bundle_Mismatch, "%s: more than the manifest's %d bytes", path, m.size)
			sha2.update(&ctx, buf[:n])
		}
		if e == .EOF || (e == nil && n == 0) do break
		if e != nil do return fail(.Fs_Error, "read %s: %v", path, e)
	}
	if total != m.size do return fail(.Bundle_Mismatch, "%s: %d bytes, manifest says %d", path, total, m.size)
	if got := digest_hex(&ctx); got != m.sha256 do return fail(.Bundle_Mismatch, "%s: SHA-256 %s, manifest says %s", path, got, m.sha256)
	return nil
}

// read_capped reads a small local file (manifest, signature) refusing more
// than `cap` bytes (temp-allocated).
read_capped :: proc(path: string, cap: int, code: Code) -> (data: []byte, err: Error) {
	f, oerr := os.open(path)
	if oerr != nil do return nil, fail(.Fs_Error, "open %s: %v", path, oerr)
	defer os.close(f)
	size, serr := os.file_size(f)
	if serr != nil do return nil, fail(.Fs_Error, "stat %s: %v", path, serr)
	if size > i64(cap) do return nil, fail(code, "%s: larger than %d bytes", path, cap)
	buf := make([]byte, int(size), context.temp_allocator)
	n, rerr := os.read_full(f, buf)
	if rerr != nil || n != int(size) do return nil, fail(.Fs_Error, "read %s: %v", path, rerr)
	return buf, nil
}
