package main

// Sandboxed filesystem directory management for the bridge host.
//
// Powers the UI's bridge-aware directory picker (browse + create project paths)
// and the "is this project path present on bridge X?" check. All operations are
// confined to a configured trusted root (default $HOME) — see the security model
// in docs/plans/bridge-directory-management.md.
//
// v1 capabilities: list a directory, stat a path, mkdir -p. No file contents, no
// delete/rename, no browsing outside the root.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:path/filepath"
import "core:time"
import "core:c/libc"
import base64 "core:encoding/base64"
import ws "odin_test:lib/ws"

// The resolved (symlink-free, absolute) sandbox root. Set once at startup by
// bridge_fs_init. Empty means FS management is effectively disabled (deny all).
bridge_fs_root: string

// bridge_fs_init resolves the configured fs_root (or $HOME when unset) to a real
// absolute path and stores it. Call once at startup.
bridge_fs_init :: proc(configured_root: string) {
	home := os.get_env_alloc("HOME", context.allocator)
	root := strings.trim_space(configured_root)
	// Default to $HOME when unset. Also expand a bare "~" or "~/..." to $HOME
	// (bridge_expand_home only handles the "~/" form, so handle bare "~" here).
	if root == "" || root == "~" {
		root = home != "" ? home : "/"
	} else {
		root = bridge_expand_home(root)
	}
	// Resolve symlinks + make absolute so containment compares real paths. NOTE:
	// os.get_absolute_path only makes the path absolute — it does NOT resolve
	// symlinks. That matters because project-root overrides are canonicalized via
	// bridge_fs_realpath_existing_prefix (which DOES follow symlinks), so on a host
	// where the root traverses a symlink (e.g. macOS /tmp -> /private/tmp) the two
	// would never prefix-match and every project-scoped fs op would fail with
	// path_outside_root. Resolve the existing prefix here too so both sides compare
	// the same real path.
	real_prefix, tail := bridge_fs_realpath_existing_prefix(root)
	if real_prefix != "" {
		resolved := real_prefix
		if tail != "" {
			if joined, jerr := filepath.join([]string{real_prefix, tail}, context.allocator); jerr == nil do resolved = joined
		}
		bridge_fs_root = resolved
	} else if resolved, err := os.get_absolute_path(root, context.allocator); err == nil {
		// Root does not exist yet: fall back to absolute (non-symlink-resolved).
		bridge_fs_root = resolved
	} else {
		// Cannot resolve at all: keep the expanded form (lexical containment only).
		bridge_fs_root = strings.clone(root)
	}
	fmt.printfln("bridge fs sandbox root: %s", bridge_fs_root)
}

Bridge_Fs_Entry :: struct {
	name:        string,
	is_dir:      bool,
	hidden:      bool,
	has_git:     bool,
	size:        i64,    // bytes for regular files; 0 for dirs
	modified_at: string, // RFC3339 UTC
}

Bridge_Fs_List_Result :: struct {
	ok:          bool,
	path:        string, // canonical absolute path actually listed
	root:        string, // sandbox root (for UI breadcrumb bounds)
	parent:      string, // parent within root, or "" if path == root
	entries:     []Bridge_Fs_Entry,
	next_cursor: string, // opaque base64 offset for the next page ("" when none)
	has_more:    bool,
	truncated:   bool,
	error_code:  string,
	message:     string,
}

Bridge_Fs_Read_File_Result :: struct {
	ok:          bool,
	path:        string,
	viewable:    bool,
	content:     string,
	encoding:    string, // "utf8" | "base64" | ""
	mime:        string,
	size:        i64,
	modified_at: string,
	truncated:   bool,
	// Byte-range pagination (utf8 text only). offset = byte offset of the first
	// byte of `content` within the file; bytes_returned = number of file bytes
	// this chunk covers (may be < len(content) is impossible, but may be trimmed
	// back from the requested limit to a UTF-8 boundary); eof = this chunk reaches
	// end of file. Callers page by requesting offset += bytes_returned until eof.
	offset:         i64,
	bytes_returned: i64,
	eof:            bool,
	error_code:  string,
	message:     string,
}

Bridge_Fs_Create_File_Result :: struct {
	ok:          bool,
	path:        string,
	created:     bool,
	within_root: bool,
	error_code:  string,
	message:     string,
}

Bridge_Fs_Move_Result :: struct {
	ok:          bool,
	from:        string,
	to:          string,
	within_root: bool,
	error_code:  string,
	message:     string,
}

Bridge_Fs_Delete_Result :: struct {
	ok:          bool,
	path:        string,
	deleted:     bool,
	within_root: bool,
	error_code:  string,
	message:     string,
}

Bridge_Fs_Stat_Result :: struct {
	ok:          bool, // request itself succeeded (within root, no fatal error)
	path:        string,
	exists:      bool,
	is_dir:      bool,
	has_git:     bool,
	within_root: bool,
	error_code:  string,
	message:     string,
}

Bridge_Fs_Mkdir_Result :: struct {
	ok:          bool,
	path:        string,
	created:     bool, // false if it already existed as a dir (idempotent)
	within_root: bool,
	error_code:  string,
	message:     string,
}

BRIDGE_FS_MAX_ENTRIES :: 2000
BRIDGE_FS_DEFAULT_LIMIT :: 200
BRIDGE_FS_MAX_VIEW_BYTES :: 1_000_000 // 1 MB read-file total-size view cap
// Default per-request byte window for paginated text reads. Kept comfortably
// below the WS relay's practical single-frame budget (empirically frames around
// ~64KB+ stall/time out on the hub relay, while ~48KB and below are instant), so
// the JSON-escaped result frame always fits. The UI pages by requesting
// offset += bytes_returned until eof.
BRIDGE_FS_READ_PAGE_BYTES :: 32_000

// --- helpers -------------------------------------------------------------

// bridge_fs_format_mtime converts a File_Info modification time to RFC3339 UTC,
// reusing the scheduler's civil-date formatter (same package).
bridge_fs_format_mtime :: proc(t: time.Time) -> string {
	ms := time.to_unix_nanoseconds(t) / 1_000_000
	return action_scheduler_format_rfc3339_utc(ms)
}

// bridge_fs_entry_less orders entries dirs-first, then name ascending. Stable
// ordering is required so cursor offsets stay meaningful across pages.
bridge_fs_entry_less :: proc(a, b: Bridge_Fs_Entry) -> bool {
	if a.is_dir != b.is_dir do return a.is_dir // dirs before files
	return strings.compare(a.name, b.name) < 0
}

// bridge_fs_decode_cursor decodes an opaque base64 offset. Empty cursor => 0.
// A malformed cursor is treated as offset 0 (fail-open to the first page).
bridge_fs_decode_cursor :: proc(cursor: string) -> int {
	if cursor == "" do return 0
	decoded, err := base64.decode(cursor, allocator = context.temp_allocator)
	if err != nil do return 0
	s := strings.trim_space(string(decoded))
	n := 0
	for ch in s {
		if ch < '0' || ch > '9' do return 0
		n = n * 10 + int(ch - '0')
	}
	return n
}

// bridge_fs_encode_cursor encodes an integer offset as an opaque base64 token.
bridge_fs_encode_cursor :: proc(offset: int) -> string {
	s := fmt.tprintf("%d", offset)
	return base64.encode(transmute([]byte)s)
}

// bridge_fs_mime_for_ext maps a lowercase file extension to (mime, encoding).
// encoding is "utf8" for text/code, "base64" for supported images, "" (with
// mime "application/octet-stream") for unknown/binary types.
bridge_fs_mime_for_ext :: proc(name: string) -> (mime: string, encoding: string) {
	lower := strings.to_lower(name, context.temp_allocator)
	dot := strings.last_index_byte(lower, '.')
	ext := ""
	if dot >= 0 do ext = lower[dot + 1:]
	switch ext {
	// images -> base64
	case "png":  return "image/png", "base64"
	case "jpg", "jpeg": return "image/jpeg", "base64"
	case "gif":  return "image/gif", "base64"
	case "webp": return "image/webp", "base64"
	case "svg":  return "image/svg+xml", "base64"
	// text/code -> utf8
	case "md", "markdown": return "text/markdown", "utf8"
	case "txt", "text", "log": return "text/plain", "utf8"
	case "json": return "application/json", "utf8"
	case "js", "mjs", "cjs": return "text/javascript", "utf8"
	case "ts", "tsx": return "text/typescript", "utf8"
	case "jsx": return "text/jsx", "utf8"
	case "html", "htm": return "text/html", "utf8"
	case "css": return "text/css", "utf8"
	case "odin": return "text/x-odin", "utf8"
	case "go": return "text/x-go", "utf8"
	case "py": return "text/x-python", "utf8"
	case "rs": return "text/x-rust", "utf8"
	case "c", "h": return "text/x-c", "utf8"
	case "cpp", "cc", "cxx", "hpp", "hxx": return "text/x-c++", "utf8"
	case "cs": return "text/x-csharp", "utf8"
	case "java": return "text/x-java", "utf8"
	case "kt", "kts": return "text/x-kotlin", "utf8"
	case "swift": return "text/x-swift", "utf8"
	case "rb": return "text/x-ruby", "utf8"
	case "php": return "text/x-php", "utf8"
	case "lua": return "text/x-lua", "utf8"
	case "r": return "text/x-r", "utf8"
	case "zig": return "text/x-zig", "utf8"
	case "nix": return "text/x-nix", "utf8"
	case "sh", "bash", "zsh", "fish": return "text/x-shellscript", "utf8"
	case "toml": return "text/x-toml", "utf8"
	case "yaml", "yml": return "text/x-yaml", "utf8"
	case "xml": return "text/xml", "utf8"
	case "csv": return "text/csv", "utf8"
	case "sql": return "text/x-sql", "utf8"
	case "graphql", "gql": return "text/x-graphql", "utf8"
	case "proto": return "text/x-proto", "utf8"
	case "diff", "patch": return "text/x-diff", "utf8"
	case "vue": return "text/x-vue", "utf8"
	case "svelte": return "text/x-svelte", "utf8"
	case "scss": return "text/x-scss", "utf8"
	case "sass": return "text/x-sass", "utf8"
	case "less": return "text/x-less", "utf8"
	case "jsonc": return "application/json", "utf8"
	case "ini", "conf", "cfg": return "text/plain", "utf8"
	case "env": return "text/plain", "utf8"
	case "gitignore", "dockerignore": return "text/plain", "utf8"
	case:
		return "application/octet-stream", ""
	}
}

// --- containment ---------------------------------------------------------

// bridge_fs_resolve_within canonicalizes `requested` (which may not exist yet) and
// checks that it is the root or a descendant of it. Returns the canonical absolute
// path and whether it is contained. Handles ~-expansion, relative paths (against
// root), `..`, and symlink escapes (by resolving the deepest existing ancestor).
bridge_fs_resolve_within :: proc(requested: string, sandbox_root: string = "") -> (canonical: string, within: bool) {
	// sandbox_root lets project-scoped commands re-sandbox to a project root that is
	// itself contained within the global bridge_fs_root; "" falls back to the global root.
	root := sandbox_root if sandbox_root != "" else bridge_fs_root
	if root == "" do return "", false
	req := strings.trim_space(requested)
	// Empty request means "the root itself".
	if req == "" || req == "~" do return strings.clone(root), true
	expanded := bridge_expand_home(req)
	// Relative paths resolve against the root, not the process cwd.
	if !filepath.is_abs(expanded) {
		joined, jerr := filepath.join([]string{root, expanded}, context.allocator)
		if jerr != nil do return "", false
		expanded = joined
	}
	// Resolve the deepest EXISTING ancestor to a real path (defeats symlink escape),
	// then re-append the non-existent tail (needed for mkdir of a new dir).
	real_prefix, tail := bridge_fs_realpath_existing_prefix(expanded)
	if real_prefix == "" do return "", false
	full := real_prefix
	if tail != "" {
		joined, jerr := filepath.join([]string{real_prefix, tail}, context.allocator)
		if jerr != nil do return "", false
		full = joined
	}
	cleaned, cerr := filepath.clean(full, context.allocator)
	if cerr != nil do return "", false
	if !bridge_fs_is_within_root(cleaned, root) do return "", false
	return cleaned, true
}

// bridge_fs_realpath_existing_prefix walks up `path` until it finds an existing
// ancestor, resolves that ancestor to its real (symlink-free) absolute form, and
// returns (real_ancestor, remaining_tail) where tail is the not-yet-existing
// suffix (may be "").
bridge_fs_realpath_existing_prefix :: proc(path: string) -> (real_prefix: string, tail: string) {
	cleaned, cerr := filepath.clean(path, context.allocator)
	if cerr != nil do return "", ""
	cursor := cleaned
	suffix_parts := make([dynamic]string)
	defer delete(suffix_parts)
	for {
		if os.exists(cursor) {
			resolved, rerr := os.get_absolute_path(cursor, context.allocator)
			if rerr != nil do return "", ""
			// Reassemble the suffix in forward order.
			tail_parts := make([dynamic]string)
			defer delete(tail_parts)
			for i := len(suffix_parts) - 1; i >= 0; i -= 1 do append(&tail_parts, suffix_parts[i])
			joined_tail := strings.join(tail_parts[:], "/", context.allocator)
			return resolved, joined_tail
		}
		dir := filepath.dir(cursor)
		base := filepath.base(cursor)
		if dir == cursor || base == "" || base == "." || base == "/" {
			// Reached the top without finding an existing ancestor.
			return "", ""
		}
		append(&suffix_parts, base)
		cursor = dir
	}
}

bridge_fs_is_within_root :: proc(abs_path: string, sandbox_root: string = "") -> bool {
	root := sandbox_root if sandbox_root != "" else bridge_fs_root
	if root == "" do return false
	if abs_path == root do return true
	// Must be a strict descendant: root + "/" prefix.
	prefix := strings.concatenate({root, "/"}, context.allocator)
	return strings.has_prefix(abs_path, prefix)
}

// bridge_fs_effective_root resolves an optional project-root override to a canonical
// absolute path, requiring it to be contained within the global bridge_fs_root
// (defense-in-depth: a hostile hub request cannot escape the bridge sandbox). An
// empty override yields the global root. ok=false means the override escaped.
bridge_fs_effective_root :: proc(root_override: string) -> (root: string, ok: bool) {
	if strings.trim_space(root_override) == "" do return bridge_fs_root, bridge_fs_root != ""
	canonical, within := bridge_fs_resolve_within(root_override) // checked against GLOBAL root
	if !within do return "", false
	return canonical, true
}

// --- operations ----------------------------------------------------------

// bridge_fs_list_dir lists a single directory with server-side hidden filtering,
// dirs-first/name-asc sorting, and opaque cursor pagination. `limit` <= 0 uses the
// default; it is clamped to BRIDGE_FS_MAX_ENTRIES. `cursor` is an opaque base64
// offset into the sorted list.
bridge_fs_list_dir :: proc(requested: string, include_hidden: bool = true, cursor: string = "", limit: int = BRIDGE_FS_DEFAULT_LIMIT, sandbox_root: string = "") -> Bridge_Fs_List_Result {
	root, root_ok := bridge_fs_effective_root(sandbox_root)
	if !root_ok {
		return Bridge_Fs_List_Result{ok = false, root = bridge_fs_root, error_code = "path_outside_root", message = "Project root is outside the allowed root"}
	}
	canonical, within := bridge_fs_resolve_within(requested, root)
	if !within {
		return Bridge_Fs_List_Result{ok = false, root = root, error_code = "path_outside_root", message = "Path is outside the allowed root"}
	}
	if !os.exists(canonical) {
		return Bridge_Fs_List_Result{ok = false, path = canonical, root = root, error_code = "path_not_found", message = "Path does not exist"}
	}
	if !os.is_dir(canonical) {
		return Bridge_Fs_List_Result{ok = false, path = canonical, root = root, error_code = "path_not_directory", message = "Path is not a directory"}
	}
	infos, rerr := os.read_directory_by_path(canonical, -1, context.allocator)
	if rerr != nil {
		return Bridge_Fs_List_Result{ok = false, path = canonical, root = root, error_code = "read_failed", message = "Could not read directory"}
	}
	defer os.file_info_slice_delete(infos, context.allocator)
	// Build the full filtered set first so sort + cursor operate on a stable order.
	all := make([dynamic]Bridge_Fs_Entry, context.allocator)
	for info in infos {
		name := info.name
		if name == "" || name == "." || name == ".." do continue
		hidden := len(name) > 0 && name[0] == '.'
		if !include_hidden && hidden do continue
		is_dir := info.type == .Directory
		has_git := false
		if is_dir {
			git_dir := strings.concatenate({info.fullpath, "/.git"}, context.allocator)
			has_git = os.exists(git_dir)
			delete(git_dir)
		}
		size := i64(0)
		if !is_dir do size = info.size
		append(&all, Bridge_Fs_Entry{
			name        = strings.clone(name),
			is_dir      = is_dir,
			hidden      = hidden,
			has_git     = has_git,
			size        = size,
			modified_at = bridge_fs_format_mtime(info.modification_time),
		})
	}
	// Sort: dirs-first, then name asc (stable for cursor paging).
	slice.sort_by(all[:], bridge_fs_entry_less)
	total := len(all)
	// Clamp the page size.
	page_limit := limit
	if page_limit <= 0 do page_limit = BRIDGE_FS_DEFAULT_LIMIT
	if page_limit > BRIDGE_FS_MAX_ENTRIES do page_limit = BRIDGE_FS_MAX_ENTRIES
	// Decode + clamp the cursor offset.
	start := bridge_fs_decode_cursor(cursor)
	if start < 0 do start = 0
	if start > total do start = total
	end := start + page_limit
	if end > total do end = total
	page := make([dynamic]Bridge_Fs_Entry, context.allocator)
	for i in start..<end do append(&page, all[i])
	has_more := end < total
	next_cursor := ""
	if has_more do next_cursor = bridge_fs_encode_cursor(end)
	parent := ""
	if canonical != root {
		p := filepath.dir(canonical)
		if bridge_fs_is_within_root(p, root) do parent = p
	}
	return Bridge_Fs_List_Result{
		ok = true, path = canonical, root = root, parent = parent,
		entries = page[:], next_cursor = next_cursor, has_more = has_more,
		truncated = false,
	}
}

// bridge_fs_read_file returns a bounded, type-gated view of a regular file. Text
// is returned as utf8; supported images as base64; oversized files as viewable
// false + file_too_large; unknown/binary as viewable false + unsupported_type.
//
// Byte-range pagination (utf8 text only): `offset`/`limit` request a chunk so a
// large file can be streamed page-by-page over the size-limited WS relay instead
// of one huge frame that times out. limit <= 0 uses BRIDGE_FS_READ_PAGE_BYTES.
// The returned chunk is trimmed back to a UTF-8 char boundary; bytes_returned is
// the actual file bytes covered (caller's next offset = offset + bytes_returned)
// and eof marks the final chunk. base64/images ignore offset/limit (returned
// whole, still under the 1MB cap). The whole file (up to the cap) is still capped
// by BRIDGE_FS_MAX_VIEW_BYTES on total size.
bridge_fs_read_file :: proc(requested: string, sandbox_root: string = "", offset: i64 = 0, limit: i64 = 0) -> Bridge_Fs_Read_File_Result {
	root, root_ok := bridge_fs_effective_root(sandbox_root)
	if !root_ok {
		return Bridge_Fs_Read_File_Result{ok = false, path = requested, error_code = "path_outside_root", message = "Project root is outside the allowed root"}
	}
	canonical, within := bridge_fs_resolve_within(requested, root)
	if !within {
		return Bridge_Fs_Read_File_Result{ok = false, path = requested, error_code = "path_outside_root", message = "Path is outside the allowed root"}
	}
	if !os.exists(canonical) {
		return Bridge_Fs_Read_File_Result{ok = false, path = canonical, error_code = "path_not_found", message = "Path does not exist"}
	}
	info, ierr := os.stat(canonical, context.allocator)
	if ierr != nil {
		return Bridge_Fs_Read_File_Result{ok = false, path = canonical, error_code = "read_failed", message = "Could not stat file"}
	}
	defer os.file_info_delete(info, context.allocator)
	if info.type == .Directory {
		return Bridge_Fs_Read_File_Result{ok = false, path = canonical, error_code = "not_a_file", message = "Path is not a regular file"}
	}
	mime, encoding := bridge_fs_mime_for_ext(info.name)
	modified_at := bridge_fs_format_mtime(info.modification_time)
	// Unknown/binary types: gate before reading any bytes.
	if encoding == "" {
		return Bridge_Fs_Read_File_Result{ok = true, path = canonical, viewable = false, mime = mime, size = info.size, modified_at = modified_at, error_code = "unsupported_type", message = "File type is not viewable"}
	}
	// Total-size cap: metadata still populated, but no content read.
	if info.size > BRIDGE_FS_MAX_VIEW_BYTES {
		return Bridge_Fs_Read_File_Result{ok = true, path = canonical, viewable = false, mime = mime, size = info.size, modified_at = modified_at, error_code = "file_too_large", message = "File exceeds the maximum viewable size"}
	}
	data, derr := os.read_entire_file_from_path(canonical, context.allocator)
	if derr != nil {
		return Bridge_Fs_Read_File_Result{ok = false, path = canonical, mime = mime, size = info.size, modified_at = modified_at, error_code = "read_failed", message = "Could not read file"}
	}
	defer delete(data, context.allocator)

	// base64/images: return whole (already bounded by the size cap); no paging.
	if encoding == "base64" {
		content := base64.encode(data)
		return Bridge_Fs_Read_File_Result{
			ok = true, path = canonical, viewable = true, content = content,
			encoding = encoding, mime = mime, size = info.size, modified_at = modified_at,
			offset = 0, bytes_returned = info.size, eof = true,
		}
	}

	// utf8 text: return the [offset, offset+page) byte window, trimmed to a valid
	// UTF-8 boundary so a multi-byte rune isn't split across chunks.
	total := i64(len(data))
	start := offset
	if start < 0 do start = 0
	if start > total do start = total
	page := limit
	if page <= 0 do page = BRIDGE_FS_READ_PAGE_BYTES
	end := start + page
	if end > total do end = total
	// Trim `end` back off the middle of a multi-byte UTF-8 sequence (a continuation
	// byte has the top bits 10xxxxxx). Never trim below `start`.
	for end > start && end < total && (data[end] & 0xC0) == 0x80 {
		end -= 1
	}
	chunk := string(data[start:end])
	return Bridge_Fs_Read_File_Result{
		ok = true, path = canonical, viewable = true, content = strings.clone(chunk),
		encoding = encoding, mime = mime, size = info.size, modified_at = modified_at,
		offset = start, bytes_returned = end - start, eof = end >= total,
	}
}

// bridge_fs_create_file creates an empty regular file. The parent directory must
// already exist within the sandbox root. Existing path => path_exists.
bridge_fs_create_file :: proc(requested: string, sandbox_root: string = "") -> Bridge_Fs_Create_File_Result {
	root, root_ok := bridge_fs_effective_root(sandbox_root)
	if !root_ok {
		return Bridge_Fs_Create_File_Result{ok = false, path = requested, within_root = false, error_code = "path_outside_root", message = "Project root is outside the allowed root"}
	}
	canonical, within := bridge_fs_resolve_within(requested, root)
	if !within {
		return Bridge_Fs_Create_File_Result{ok = false, path = requested, within_root = false, error_code = "path_outside_root", message = "Path is outside the allowed root"}
	}
	if canonical == root {
		return Bridge_Fs_Create_File_Result{ok = false, path = canonical, within_root = true, error_code = "path_exists", message = "Path already exists"}
	}
	if os.exists(canonical) {
		return Bridge_Fs_Create_File_Result{ok = false, path = canonical, within_root = true, error_code = "path_exists", message = "Path already exists"}
	}
	parent := filepath.dir(canonical)
	if !os.exists(parent) || !os.is_dir(parent) {
		return Bridge_Fs_Create_File_Result{ok = false, path = canonical, within_root = true, error_code = "path_not_found", message = "Parent directory does not exist"}
	}
	if err := os.write_entire_file_from_string(canonical, ""); err != nil {
		return Bridge_Fs_Create_File_Result{ok = false, path = canonical, within_root = true, error_code = "write_failed", message = "Could not create file"}
	}
	return Bridge_Fs_Create_File_Result{ok = true, path = canonical, created = true, within_root = true}
}

// bridge_fs_move renames/moves a path. Both endpoints are sandboxed; the source
// must exist and the destination must not (dest_exists). Works for files + dirs.
bridge_fs_move :: proc(from_req, to_req: string, sandbox_root: string = "") -> Bridge_Fs_Move_Result {
	root, root_ok := bridge_fs_effective_root(sandbox_root)
	if !root_ok {
		return Bridge_Fs_Move_Result{ok = false, from = from_req, to = to_req, within_root = false, error_code = "path_outside_root", message = "Project root is outside the allowed root"}
	}
	from_canonical, from_within := bridge_fs_resolve_within(from_req, root)
	if !from_within {
		return Bridge_Fs_Move_Result{ok = false, from = from_req, to = to_req, within_root = false, error_code = "path_outside_root", message = "Source path is outside the allowed root"}
	}
	to_canonical, to_within := bridge_fs_resolve_within(to_req, root)
	if !to_within {
		return Bridge_Fs_Move_Result{ok = false, from = from_canonical, to = to_req, within_root = false, error_code = "path_outside_root", message = "Destination path is outside the allowed root"}
	}
	if from_canonical == root {
		return Bridge_Fs_Move_Result{ok = false, from = from_canonical, to = to_canonical, within_root = true, error_code = "cannot_delete_root", message = "Cannot move the root itself"}
	}
	if !os.exists(from_canonical) {
		return Bridge_Fs_Move_Result{ok = false, from = from_canonical, to = to_canonical, within_root = true, error_code = "path_not_found", message = "Source path does not exist"}
	}
	if os.exists(to_canonical) {
		return Bridge_Fs_Move_Result{ok = false, from = from_canonical, to = to_canonical, within_root = true, error_code = "dest_exists", message = "Destination already exists"}
	}
	to_parent := filepath.dir(to_canonical)
	if !os.exists(to_parent) || !os.is_dir(to_parent) {
		return Bridge_Fs_Move_Result{ok = false, from = from_canonical, to = to_canonical, within_root = true, error_code = "path_not_found", message = "Destination parent directory does not exist"}
	}
	from_c := strings.clone_to_cstring(from_canonical, context.temp_allocator)
	to_c := strings.clone_to_cstring(to_canonical, context.temp_allocator)
	if libc.rename(from_c, to_c) != 0 {
		return Bridge_Fs_Move_Result{ok = false, from = from_canonical, to = to_canonical, within_root = true, error_code = "move_failed", message = "Could not move path"}
	}
	return Bridge_Fs_Move_Result{ok = true, from = from_canonical, to = to_canonical, within_root = true}
}

// bridge_fs_delete removes a file or directory. Non-empty directories require
// recursive=true (else dir_not_empty). The sandbox root itself is never deletable.
bridge_fs_delete :: proc(requested: string, recursive: bool, sandbox_root: string = "") -> Bridge_Fs_Delete_Result {
	root, root_ok := bridge_fs_effective_root(sandbox_root)
	if !root_ok {
		return Bridge_Fs_Delete_Result{ok = false, path = requested, within_root = false, error_code = "path_outside_root", message = "Project root is outside the allowed root"}
	}
	canonical, within := bridge_fs_resolve_within(requested, root)
	if !within {
		return Bridge_Fs_Delete_Result{ok = false, path = requested, within_root = false, error_code = "path_outside_root", message = "Path is outside the allowed root"}
	}
	if canonical == root {
		return Bridge_Fs_Delete_Result{ok = false, path = canonical, within_root = true, error_code = "cannot_delete_root", message = "Cannot delete the root directory"}
	}
	if !os.exists(canonical) {
		return Bridge_Fs_Delete_Result{ok = false, path = canonical, within_root = true, error_code = "path_not_found", message = "Path does not exist"}
	}
	if os.is_dir(canonical) {
		if !recursive {
			infos, rerr := os.read_directory_by_path(canonical, -1, context.allocator)
			if rerr != nil {
				return Bridge_Fs_Delete_Result{ok = false, path = canonical, within_root = true, error_code = "delete_failed", message = "Could not inspect directory"}
			}
			non_empty := false
			for info in infos {
				if info.name == "" || info.name == "." || info.name == ".." do continue
				non_empty = true
				break
			}
			os.file_info_slice_delete(infos, context.allocator)
			if non_empty {
				return Bridge_Fs_Delete_Result{ok = false, path = canonical, within_root = true, error_code = "dir_not_empty", message = "Directory is not empty"}
			}
		}
		if err := os.remove_all(canonical); err != nil {
			return Bridge_Fs_Delete_Result{ok = false, path = canonical, within_root = true, error_code = "delete_failed", message = "Could not delete directory"}
		}
		return Bridge_Fs_Delete_Result{ok = true, path = canonical, deleted = true, within_root = true}
	}
	if err := os.remove(canonical); err != nil {
		return Bridge_Fs_Delete_Result{ok = false, path = canonical, within_root = true, error_code = "delete_failed", message = "Could not delete file"}
	}
	return Bridge_Fs_Delete_Result{ok = true, path = canonical, deleted = true, within_root = true}
}

bridge_fs_stat :: proc(requested: string, sandbox_root: string = "") -> Bridge_Fs_Stat_Result {
	root, root_ok := bridge_fs_effective_root(sandbox_root)
	if !root_ok {
		return Bridge_Fs_Stat_Result{ok = true, path = requested, exists = false, within_root = false, error_code = "path_outside_root", message = "Project root is outside the allowed root"}
	}
	canonical, within := bridge_fs_resolve_within(requested, root)
	if !within {
		return Bridge_Fs_Stat_Result{ok = true, path = requested, exists = false, within_root = false, error_code = "path_outside_root", message = "Path is outside the allowed root"}
	}
	exists := os.exists(canonical)
	is_dir := exists && os.is_dir(canonical)
	has_git := is_dir && bridge_path_has_git_root(canonical)
	return Bridge_Fs_Stat_Result{ok = true, path = canonical, exists = exists, is_dir = is_dir, has_git = has_git, within_root = true}
}

bridge_fs_make_dir :: proc(requested: string, sandbox_root: string = "") -> Bridge_Fs_Mkdir_Result {
	root, root_ok := bridge_fs_effective_root(sandbox_root)
	if !root_ok {
		return Bridge_Fs_Mkdir_Result{ok = false, path = requested, within_root = false, error_code = "path_outside_root", message = "Project root is outside the allowed root"}
	}
	canonical, within := bridge_fs_resolve_within(requested, root)
	if !within {
		return Bridge_Fs_Mkdir_Result{ok = false, path = requested, within_root = false, error_code = "path_outside_root", message = "Path is outside the allowed root"}
	}
	if os.exists(canonical) {
		if os.is_dir(canonical) {
			return Bridge_Fs_Mkdir_Result{ok = true, path = canonical, created = false, within_root = true}
		}
		return Bridge_Fs_Mkdir_Result{ok = false, path = canonical, within_root = true, error_code = "path_exists_not_dir", message = "A non-directory already exists at this path"}
	}
	if err := os.make_directory_all(canonical); err != nil {
		return Bridge_Fs_Mkdir_Result{ok = false, path = canonical, within_root = true, error_code = "mkdir_failed", message = "Could not create directory"}
	}
	return Bridge_Fs_Mkdir_Result{ok = true, path = canonical, created = true, within_root = true}
}

// --- WS command handling (Hub -> Bridge) ---------------------------------

// bridge_fs_handle_command dispatches the fs_* command types over the runtime WS.
// Returns true if `type` was an fs command (handled), false otherwise. Results are
// cached by command_id for idempotent replay, matching the other command handlers.
bridge_fs_handle_command :: proc(conn: ^ws.Connection, type, text: string) -> bool {
	switch type {
	case "fs_list_dir":
		command_id := extract_json_string(text, "command_id", "")
		if cached, ok := bridge_runtime_cached_command(command_id); ok { _ = ws.send_text(conn, cached); return true }
		path := extract_json_string(text, "path", "")
		// include_hidden defaults to true when the key is absent (back-compat with the
		// existing picker which never sent it and expects hidden entries returned).
		include_hidden := true
		if strings.contains(text, "\"include_hidden\"") do include_hidden = bridge_fs_extract_json_bool(text, "include_hidden", true)
		cursor := extract_json_string(text, "cursor", "")
		limit := extract_json_int(text, "limit", BRIDGE_FS_DEFAULT_LIMIT)
		root := extract_json_string(text, "root", "")
		result := bridge_fs_list_dir(path, include_hidden, cursor, limit, root)
		out := bridge_fs_list_result_json(command_id, result)
		bridge_runtime_cache_command(command_id, out)
		_ = ws.send_text(conn, out)
		return true
	case "fs_stat":
		command_id := extract_json_string(text, "command_id", "")
		if cached, ok := bridge_runtime_cached_command(command_id); ok { _ = ws.send_text(conn, cached); return true }
		path := extract_json_string(text, "path", "")
		root := extract_json_string(text, "root", "")
		result := bridge_fs_stat(path, root)
		out := bridge_fs_stat_result_json(command_id, result)
		bridge_runtime_cache_command(command_id, out)
		_ = ws.send_text(conn, out)
		return true
	case "fs_make_dir":
		command_id := extract_json_string(text, "command_id", "")
		if cached, ok := bridge_runtime_cached_command(command_id); ok { _ = ws.send_text(conn, cached); return true }
		path := extract_json_string(text, "path", "")
		root := extract_json_string(text, "root", "")
		result := bridge_fs_make_dir(path, root)
		out := bridge_fs_mkdir_result_json(command_id, result)
		bridge_runtime_cache_command(command_id, out)
		_ = ws.send_text(conn, out)
		return true
	case "fs_read_file":
		command_id := extract_json_string(text, "command_id", "")
		if cached, ok := bridge_runtime_cached_command(command_id); ok { _ = ws.send_text(conn, cached); return true }
		path := extract_json_string(text, "path", "")
		root := extract_json_string(text, "root", "")
		offset := i64(extract_json_int(text, "offset", 0))
		limit := i64(extract_json_int(text, "limit", 0))
		result := bridge_fs_read_file(path, root, offset, limit)
		out := bridge_fs_read_file_result_json(command_id, result)
		bridge_runtime_cache_command(command_id, out)
		_ = ws.send_text(conn, out)
		return true
	case "fs_create_file":
		command_id := extract_json_string(text, "command_id", "")
		if cached, ok := bridge_runtime_cached_command(command_id); ok { _ = ws.send_text(conn, cached); return true }
		path := extract_json_string(text, "path", "")
		root := extract_json_string(text, "root", "")
		result := bridge_fs_create_file(path, root)
		out := bridge_fs_create_file_result_json(command_id, result)
		bridge_runtime_cache_command(command_id, out)
		_ = ws.send_text(conn, out)
		return true
	case "fs_move":
		command_id := extract_json_string(text, "command_id", "")
		if cached, ok := bridge_runtime_cached_command(command_id); ok { _ = ws.send_text(conn, cached); return true }
		from := extract_json_string(text, "from", "")
		to := extract_json_string(text, "to", "")
		root := extract_json_string(text, "root", "")
		result := bridge_fs_move(from, to, root)
		out := bridge_fs_move_result_json(command_id, result)
		bridge_runtime_cache_command(command_id, out)
		_ = ws.send_text(conn, out)
		return true
	case "fs_delete":
		command_id := extract_json_string(text, "command_id", "")
		if cached, ok := bridge_runtime_cached_command(command_id); ok { _ = ws.send_text(conn, cached); return true }
		path := extract_json_string(text, "path", "")
		recursive := bridge_fs_extract_json_bool(text, "recursive", false)
		root := extract_json_string(text, "root", "")
		result := bridge_fs_delete(path, recursive, root)
		out := bridge_fs_delete_result_json(command_id, result)
		bridge_runtime_cache_command(command_id, out)
		_ = ws.send_text(conn, out)
		return true
	}
	return false
}

// bridge_fs_extract_json_bool reads a top-level JSON boolean by key. Returns the
// fallback when the key is missing or the value is not a clean true/false literal.
bridge_fs_extract_json_bool :: proc(body, key: string, fallback: bool) -> bool {
	pattern := fmt.tprintf("\"%s\":", key)
	idx := strings.index(body, pattern)
	if idx < 0 do return fallback
	rest := strings.trim_space(body[idx + len(pattern):])
	if strings.has_prefix(rest, "true") do return true
	if strings.has_prefix(rest, "false") do return false
	return fallback
}

bridge_fs_list_result_json :: proc(command_id: string, r: Bridge_Fs_List_Result) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"fs_list_dir_result\",\"command_id\":\""); json_write_string(&b, command_id)
	strings.write_string(&b, "\",\"ok\":"); strings.write_string(&b, "true" if r.ok else "false")
	strings.write_string(&b, ",\"path\":\""); json_write_string(&b, r.path)
	strings.write_string(&b, "\",\"root\":\""); json_write_string(&b, r.root)
	strings.write_string(&b, "\",\"parent\":\""); json_write_string(&b, r.parent)
	strings.write_string(&b, "\",\"truncated\":"); strings.write_string(&b, "true" if r.truncated else "false")
	strings.write_string(&b, ",\"has_more\":"); strings.write_string(&b, "true" if r.has_more else "false")
	if r.next_cursor == "" {
		strings.write_string(&b, ",\"next_cursor\":null")
	} else {
		strings.write_string(&b, ",\"next_cursor\":\""); json_write_string(&b, r.next_cursor); strings.write_string(&b, "\"")
	}
	strings.write_string(&b, ",\"entries\":[")
	for e, i in r.entries {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, "{\"name\":\""); json_write_string(&b, e.name)
		strings.write_string(&b, "\",\"is_dir\":"); strings.write_string(&b, "true" if e.is_dir else "false")
		strings.write_string(&b, ",\"hidden\":"); strings.write_string(&b, "true" if e.hidden else "false")
		strings.write_string(&b, ",\"has_git\":"); strings.write_string(&b, "true" if e.has_git else "false")
		strings.write_string(&b, ",\"size\":"); strings.write_string(&b, fmt.tprintf("%d", e.size))
		strings.write_string(&b, ",\"modified_at\":\""); json_write_string(&b, e.modified_at)
		strings.write_string(&b, "\"}")
	}
	strings.write_string(&b, "],\"error\":{\"code\":\""); json_write_string(&b, r.error_code)
	strings.write_string(&b, "\",\"message\":\""); json_write_string(&b, r.message)
	strings.write_string(&b, "\"}}")
	return strings.to_string(b)
}

bridge_fs_read_file_result_json :: proc(command_id: string, r: Bridge_Fs_Read_File_Result) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"fs_read_file_result\",\"command_id\":\""); json_write_string(&b, command_id)
	strings.write_string(&b, "\",\"ok\":"); strings.write_string(&b, "true" if r.ok else "false")
	strings.write_string(&b, ",\"path\":\""); json_write_string(&b, r.path)
	strings.write_string(&b, "\",\"viewable\":"); strings.write_string(&b, "true" if r.viewable else "false")
	if r.viewable {
		strings.write_string(&b, ",\"content\":\""); json_write_string(&b, r.content)
		strings.write_string(&b, "\",\"encoding\":\""); json_write_string(&b, r.encoding); strings.write_string(&b, "\"")
	}
	strings.write_string(&b, ",\"mime\":\""); json_write_string(&b, r.mime)
	strings.write_string(&b, "\",\"size\":"); strings.write_string(&b, fmt.tprintf("%d", r.size))
	strings.write_string(&b, ",\"offset\":"); strings.write_string(&b, fmt.tprintf("%d", r.offset))
	strings.write_string(&b, ",\"bytes_returned\":"); strings.write_string(&b, fmt.tprintf("%d", r.bytes_returned))
	strings.write_string(&b, ",\"eof\":"); strings.write_string(&b, "true" if r.eof else "false")
	strings.write_string(&b, ",\"modified_at\":\""); json_write_string(&b, r.modified_at)
	strings.write_string(&b, "\",\"truncated\":"); strings.write_string(&b, "true" if r.truncated else "false")
	strings.write_string(&b, ",\"error\":{\"code\":\""); json_write_string(&b, r.error_code)
	strings.write_string(&b, "\",\"message\":\""); json_write_string(&b, r.message)
	strings.write_string(&b, "\"}}")
	return strings.to_string(b)
}

bridge_fs_create_file_result_json :: proc(command_id: string, r: Bridge_Fs_Create_File_Result) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"fs_create_file_result\",\"command_id\":\""); json_write_string(&b, command_id)
	strings.write_string(&b, "\",\"ok\":"); strings.write_string(&b, "true" if r.ok else "false")
	strings.write_string(&b, ",\"path\":\""); json_write_string(&b, r.path)
	strings.write_string(&b, "\",\"created\":"); strings.write_string(&b, "true" if r.created else "false")
	strings.write_string(&b, ",\"within_root\":"); strings.write_string(&b, "true" if r.within_root else "false")
	strings.write_string(&b, ",\"error\":{\"code\":\""); json_write_string(&b, r.error_code)
	strings.write_string(&b, "\",\"message\":\""); json_write_string(&b, r.message)
	strings.write_string(&b, "\"}}")
	return strings.to_string(b)
}

bridge_fs_move_result_json :: proc(command_id: string, r: Bridge_Fs_Move_Result) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"fs_move_result\",\"command_id\":\""); json_write_string(&b, command_id)
	strings.write_string(&b, "\",\"ok\":"); strings.write_string(&b, "true" if r.ok else "false")
	strings.write_string(&b, ",\"from\":\""); json_write_string(&b, r.from)
	strings.write_string(&b, "\",\"to\":\""); json_write_string(&b, r.to)
	strings.write_string(&b, "\",\"within_root\":"); strings.write_string(&b, "true" if r.within_root else "false")
	strings.write_string(&b, ",\"error\":{\"code\":\""); json_write_string(&b, r.error_code)
	strings.write_string(&b, "\",\"message\":\""); json_write_string(&b, r.message)
	strings.write_string(&b, "\"}}")
	return strings.to_string(b)
}

bridge_fs_delete_result_json :: proc(command_id: string, r: Bridge_Fs_Delete_Result) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"fs_delete_result\",\"command_id\":\""); json_write_string(&b, command_id)
	strings.write_string(&b, "\",\"ok\":"); strings.write_string(&b, "true" if r.ok else "false")
	strings.write_string(&b, ",\"path\":\""); json_write_string(&b, r.path)
	strings.write_string(&b, "\",\"deleted\":"); strings.write_string(&b, "true" if r.deleted else "false")
	strings.write_string(&b, ",\"within_root\":"); strings.write_string(&b, "true" if r.within_root else "false")
	strings.write_string(&b, ",\"error\":{\"code\":\""); json_write_string(&b, r.error_code)
	strings.write_string(&b, "\",\"message\":\""); json_write_string(&b, r.message)
	strings.write_string(&b, "\"}}")
	return strings.to_string(b)
}

bridge_fs_stat_result_json :: proc(command_id: string, r: Bridge_Fs_Stat_Result) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"fs_stat_result\",\"command_id\":\""); json_write_string(&b, command_id)
	strings.write_string(&b, "\",\"ok\":"); strings.write_string(&b, "true" if r.ok else "false")
	strings.write_string(&b, ",\"path\":\""); json_write_string(&b, r.path)
	strings.write_string(&b, "\",\"exists\":"); strings.write_string(&b, "true" if r.exists else "false")
	strings.write_string(&b, ",\"is_dir\":"); strings.write_string(&b, "true" if r.is_dir else "false")
	strings.write_string(&b, ",\"has_git\":"); strings.write_string(&b, "true" if r.has_git else "false")
	strings.write_string(&b, ",\"within_root\":"); strings.write_string(&b, "true" if r.within_root else "false")
	strings.write_string(&b, ",\"error\":{\"code\":\""); json_write_string(&b, r.error_code)
	strings.write_string(&b, "\",\"message\":\""); json_write_string(&b, r.message)
	strings.write_string(&b, "\"}}")
	return strings.to_string(b)
}

bridge_fs_mkdir_result_json :: proc(command_id: string, r: Bridge_Fs_Mkdir_Result) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"fs_make_dir_result\",\"command_id\":\""); json_write_string(&b, command_id)
	strings.write_string(&b, "\",\"ok\":"); strings.write_string(&b, "true" if r.ok else "false")
	strings.write_string(&b, ",\"path\":\""); json_write_string(&b, r.path)
	strings.write_string(&b, "\",\"created\":"); strings.write_string(&b, "true" if r.created else "false")
	strings.write_string(&b, ",\"within_root\":"); strings.write_string(&b, "true" if r.within_root else "false")
	strings.write_string(&b, ",\"error\":{\"code\":\""); json_write_string(&b, r.error_code)
	strings.write_string(&b, "\",\"message\":\""); json_write_string(&b, r.message)
	strings.write_string(&b, "\"}}")
	return strings.to_string(b)
}
