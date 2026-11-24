package fetch

// Steps 9-11 of spec §14: make the staging tree durable, give it its final
// name (§4), run the --version preflight from the final tree, and mark it
// valid with .complete.
//
//   9.  write release.json + release.json.minisig (the verified bytes) and
//       tree.json, fsync every file and directory, choose the name, rename
//       .staging-<op_id> -> <name> once (W2), retrying sharing violations (W3);
//   10. run `<exe> --version` for each preflight binary from the final tree,
//       10 s each, output must contain the manifest version; wait until every
//       process has exited;
//   11. write .complete, fsync it and the tree directory.
//
// Nothing has executed from a tree before its rename, and a tree without
// .complete is never valid, so no pointer can name it until step 11.

import "core:crypto/sha2"
import "core:encoding/json"
import "core:io"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

PREFLIGHT_TIMEOUT_MS :: 10_000
COMPLETE_FILE :: ".complete"
TREE_JSON :: "tree.json"
RELEASE_JSON :: "release.json"
RELEASE_SIG :: "release.json.minisig"

// Executables run by the preflight, relative to the tree root (without the
// Windows .exe suffix, added here). The tree is the bundle exactly as
// archived (bin/, share/heimdall/extensions/, ...), so the binaries are in
// bin/ (user decision 2026-11-23, spec §3: verbatim, no flattening; the
// launcher starts bin/ham-supervisor, src/launcher/core TREE_BIN_DIR).
BIN_DIR :: "bin"
DEFAULT_PREFLIGHT :: []string{BIN_DIR + "/ham-supervisor", BIN_DIR + "/ham-bridge"}

// Retry_Policy implements W3. rename and sleep are injectable so the
// failure-injection suite can simulate antivirus sharing violations.
Retry_Policy :: struct {
	budget_ms: int, // total time to keep retrying (60 s)
	first_ms:  int, // first backoff (100 ms), doubling
	max_ms:    int, // backoff cap (2 s)
	rename:    proc(old_path, new_path: string) -> os.Error, // nil = os.rename
	sleep:     proc(ms: int), // nil = time.sleep
}

DEFAULT_RETRY :: Retry_Policy {
	budget_ms = 60_000,
	first_ms  = 100,
	max_ms    = 2_000,
}

// is_busy_error: the errors W3 retries (Windows sharing/lock violations and
// access denied while a scanner holds the file; EBUSY/ETXTBSY elsewhere).
// core:os maps ERROR_ACCESS_DENIED and ERROR_SHARING_VIOLATION to
// io.Error.Permission_Denied on Windows; other codes arrive as Platform_Error.
is_busy_error :: proc(e: os.Error) -> bool {
	#partial switch v in e {
	case io.Error:
		return ODIN_OS == .Windows && v == .Permission_Denied
	case os.Platform_Error:
		when ODIN_OS == .Windows {
			code := u32(v)
			return code == 32 || code == 33 || code == 5 // SHARING, LOCK, ACCESS_DENIED
		} else {
			code := i32(v)
			return code == 16 || code == 26 // EBUSY, ETXTBSY
		}
	}
	return false
}

rename_with_retry :: proc(old_path, new_path: string, policy := DEFAULT_RETRY) -> Error {
	rename := policy.rename if policy.rename != nil else os.rename
	waited := 0
	backoff := max(policy.first_ms, 1)
	for {
		e := rename(old_path, new_path)
		if e == nil do return nil
		if !is_busy_error(e) do return fail(.Fs_Error, "rename %s -> %s: %v", old_path, new_path, e)
		if waited >= policy.budget_ms do return fail(.Fs_Busy, "rename %s -> %s still refused after %d ms: %v", old_path, new_path, waited, e)
		step := min(backoff, policy.budget_ms - waited)
		if policy.sleep != nil do policy.sleep(step)
		else do time.sleep(time.Duration(step) * time.Millisecond)
		waited += step
		backoff = min(backoff * 2, max(policy.max_ms, 1))
	}
}

// write_durable writes data to a new file and fsyncs it.
write_durable :: proc(path: string, data: []byte) -> Error {
	f, e := os.open(path, {.Write, .Create, .Trunc}, FILE_PERMS)
	if e != nil do return fail(.Fs_Error, "create %s: %v", path, e)
	n, we := os.write(f, data)
	if we != nil || n != len(data) {
		os.close(f)
		return fail(.Fs_Error, "write %s: %v", path, we)
	}
	if se := os.sync(f); se != nil {
		os.close(f)
		return fail(.Fs_Error, "fsync %s: %v", path, se)
	}
	if ce := os.close(f); ce != nil do return fail(.Fs_Error, "close %s: %v", path, ce)
	return nil
}

// sync_dir fsyncs a directory so a rename or new entry in it is durable.
// Windows has no directory fsync through this API; NTFS journals metadata.
sync_dir :: proc(path: string) -> Error {
	when ODIN_OS == .Windows {
		return nil
	} else {
		f, e := os.open(path)
		if e != nil do return fail(.Fs_Error, "open dir %s: %v", path, e)
		defer os.close(f)
		if se := os.sync(f); se != nil do return fail(.Fs_Error, "fsync dir %s: %v", path, se)
		return nil
	}
}

Tree_Entry :: struct {
	path:   string,
	size:   i64,
	sha256: string,
}

// tree_json renders {"files":[{"path","size","sha256"}...]} sorted by path.
tree_json :: proc(files: []Tree_Entry) -> string {
	sorted := slice.clone(files, context.temp_allocator)
	slice.sort_by(sorted, proc(a, b: Tree_Entry) -> bool {return a.path < b.path})
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"files":[`)
	for f, i in sorted {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, `{"path":`)
		write_canonical_string(&b, f.path)
		strings.write_string(&b, `,"size":`)
		strings.write_i64(&b, f.size)
		strings.write_string(&b, `,"sha256":"`)
		strings.write_string(&b, f.sha256)
		strings.write_string(&b, `"}`)
	}
	strings.write_string(&b, "]}\n")
	return strings.to_string(b)
}

// write_tree_metadata adds release.json, its signature and tree.json to the
// staging tree and fsyncs every directory (files were fsynced when written).
write_tree_metadata :: proc(staging: string, m: ^Manifest, extracted: ^Extracted) -> Error {
	write_durable(native_join(staging, RELEASE_JSON), m.raw) or_return
	write_durable(native_join(staging, RELEASE_SIG), m.signature) or_return
	entries := make([dynamic]Tree_Entry, 0, len(extracted.files) + 2, context.temp_allocator)
	for f in extracted.files do append(&entries, Tree_Entry{f.path, f.size, f.sha256})
	append(&entries, Tree_Entry{RELEASE_JSON, i64(len(m.raw)), sha256_of(m.raw)})
	append(&entries, Tree_Entry{RELEASE_SIG, i64(len(m.signature)), sha256_of(m.signature)})
	write_durable(native_join(staging, TREE_JSON), transmute([]byte)tree_json(entries[:])) or_return
	// Deepest directories first, then the root.
	dirs := slice.clone(extracted.dirs[:], context.temp_allocator)
	slice.sort_by(dirs, proc(a, b: string) -> bool {return len(a) > len(b)})
	for d in dirs do sync_dir(native_join(staging, d)) or_return
	return sync_dir(staging)
}

@(private)
sha256_of :: proc(data: []byte) -> string {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, data)
	return digest_hex(&ctx)
}

// tree_base_name is "<ver>-<d12>" (spec §3/§4).
tree_base_name :: proc(m: ^Manifest) -> string {
	return strings.concatenate({m.version, "-", m.sha256[:12]}, context.temp_allocator)
}

// read_tree_json parses <tree>/tree.json (temp-allocated).
read_tree_json :: proc(tree_dir: string) -> (entries: []Tree_Entry, ok: bool) {
	data, rerr := read_capped(native_join(tree_dir, TREE_JSON), 16 << 20, .Tree_Damaged)
	if rerr != nil do return nil, false
	v, perr := json.parse(data, .JSON, true, context.temp_allocator) // strict JSON (the default is JSON5)
	if perr != nil do return nil, false
	files, fok := v.(json.Object)["files"].(json.Array)
	if !fok do return nil, false
	out := make([]Tree_Entry, len(files), context.temp_allocator)
	for item, i in files {
		obj, is_obj := item.(json.Object)
		if !is_obj do return nil, false
		p, p_ok := obj["path"].(json.String)
		s, s_ok := obj["size"].(json.Integer)
		h, h_ok := obj["sha256"].(json.String)
		if !(p_ok && s_ok && h_ok) do return nil, false
		_, _, _, reason := clean_entry_path(p)
		if reason != "" && p != RELEASE_JSON && p != RELEASE_SIG do return nil, false
		out[i] = Tree_Entry{p, i64(s), h}
	}
	return out, true
}

// tree_check_sizes is the read-only damage check of J7/J28: tree.json parses
// and every listed file exists with its recorded size.
tree_check_sizes :: proc(tree_dir: string) -> Error {
	entries, ok := read_tree_json(tree_dir)
	if !ok do return fail(.Tree_Damaged, "%s: tree.json missing or invalid", tree_dir)
	for e in entries {
		fi, serr := os.stat(native_join(tree_dir, e.path), context.temp_allocator)
		if serr != nil do return fail(.Tree_Damaged, "%s: %s missing", tree_dir, e.path)
		if fi.size != e.size do return fail(.Tree_Damaged, "%s: %s is %d bytes, tree.json says %d", tree_dir, e.path, fi.size, e.size)
	}
	return nil
}

// tree_intact: the tree is valid per §4 for this manifest (.complete,
// release.json names the same version and digest) and undamaged.
tree_intact :: proc(tree_dir: string, m: ^Manifest) -> bool {
	if !os.exists(native_join(tree_dir, COMPLETE_FILE)) do return false
	data, rerr := read_capped(native_join(tree_dir, RELEASE_JSON), MAX_MANIFEST_BYTES, .Tree_Damaged)
	if rerr != nil do return false
	v, perr := json.parse(data, .JSON, true, context.temp_allocator) // strict JSON (the default is JSON5)
	if perr != nil do return false
	obj, _ := v.(json.Object)
	version, _ := obj["version"].(json.String)
	if version != m.version do return false
	targets, _ := obj["targets"].(json.Object)
	entry, _ := targets[m.target].(json.Object)
	digest, _ := entry["sha256"].(json.String)
	if digest != m.sha256 do return false
	return tree_check_sizes(tree_dir) == nil
}

Name_Choice :: enum {
	Use, // rename staging to `name`
	Reuse, // `name` is already a valid, undamaged tree of this release
}

// choose_tree_name implements the §4 rule. `live` lists the tree names that
// W1 protects (current, previous, known-good, the op's from/to, trees of
// running processes). A damaged, non-live tree with the base name is moved
// aside and deleted (W5) here.
choose_tree_name :: proc(releases_dir: string, m: ^Manifest, live: []string, op_id: string, policy := DEFAULT_RETRY) -> (name: string, choice: Name_Choice, err: Error) {
	base := tree_base_name(m)
	path := native_join(releases_dir, base)
	if !os.exists(path) do return base, .Use, nil
	if tree_intact(path, m) do return base, .Reuse, nil
	if !slice.contains(live, base) {
		remove_tree(releases_dir, base, op_id, policy) or_return
		return base, .Use, nil
	}
	for n := 1; n < 1000; n += 1 {
		buf: [16]byte
		candidate := strings.concatenate({base, "-r", strconv.write_int(buf[:], i64(n), 10)}, context.temp_allocator)
		if !os.exists(native_join(releases_dir, candidate)) do return candidate, .Use, nil
	}
	return "", .Use, fail(.Fs_Error, "no free repair name for %s", base)
}

// remove_tree deletes a non-live tree the W5 way: rename to .trash-<name>-<op>,
// then delete. A failure leaves the trash for GC (§15) and is fs_busy.
remove_tree :: proc(releases_dir, name, op_id: string, policy := DEFAULT_RETRY) -> Error {
	from := native_join(releases_dir, name)
	trash := native_join(releases_dir, strings.concatenate({".trash-", name, "-", op_id}, context.temp_allocator))
	os.remove_all(trash)
	rename_with_retry(from, trash, policy) or_return
	if e := os.remove_all(trash); e != nil do return fail(.Fs_Busy, "delete %s: %v", trash, e)
	return nil
}

exe_name :: proc(rel: string) -> string {
	when ODIN_OS == .Windows {
		return strings.concatenate({rel, ".exe"}, context.temp_allocator)
	} else {
		return rel
	}
}

// run_preflight runs each binary with --version from the final tree and
// waits for it to exit (step 10).
run_preflight :: proc(tree_dir: string, binaries: []string, version: string, timeout_ms := PREFLIGHT_TIMEOUT_MS) -> Error {
	for rel in binaries {
		exe := native_join(tree_dir, exe_name(rel))
		if !os.exists(exe) do return fail(.Preflight_Failed, "%s: missing from the tree", exe_name(rel))
		code, stdout, stderr, ran := run_process({exe, "--version"}, timeout_ms, tree_dir)
		if !ran do return fail(.Preflight_Failed, "%s --version did not finish within %d ms", exe_name(rel), timeout_ms)
		if code != 0 do return fail(.Preflight_Failed, "%s --version exited %d: %s", exe_name(rel), code, strings.trim_space(stderr))
		if !contains_version(stdout, version) {
			return fail(.Preflight_Failed, "%s --version printed %q, expected %s", exe_name(rel), strings.trim_space(stdout), version)
		}
	}
	return nil
}

// contains_version: `version` appears as a whole token (not as a prefix of
// 1.2.30 or inside 11.2.3).
@(private)
contains_version :: proc(output, version: string) -> bool {
	is_token_char :: proc(c: byte) -> bool {
		return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '.' || c == '-' || c == '+'
	}
	s := output
	offset := 0
	for {
		i := strings.index(s[offset:], version)
		if i < 0 do return false
		start := offset + i
		end := start + len(version)
		before_ok := start == 0 || !is_token_char(s[start - 1]) || s[start - 1] == 'v' && (start == 1 || !is_token_char(s[start - 2]))
		after_ok := end == len(s) || !is_token_char(s[end]) || (s[end] == '.' && (end + 1 == len(s) || !is_token_char(s[end + 1])))
		if before_ok && after_ok do return true
		offset = start + 1
	}
}

// mark_complete writes .complete (step 11).
mark_complete :: proc(tree_dir, op_id: string) -> Error {
	write_durable(native_join(tree_dir, COMPLETE_FILE), transmute([]byte)strings.concatenate({op_id, "\n"}, context.temp_allocator)) or_return
	return sync_dir(tree_dir)
}
