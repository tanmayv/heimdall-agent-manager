package main

// Version-control (VCS) provider abstraction for the bridge host.
//
// Powers the UI's per-project "changed files + diff" view (Phase 2 hub, Phase 3
// UI). The bridge is the only component with project-local filesystem access, so
// it shells out to the project's VCS and returns a provider-neutral shape the hub
// can relay and the UI can render without knowing whether the backend is git or
// jj.
//
// Design mirrors fs_management.odin: pure value structs, opaque base64 int-offset
// cursor pagination (shared bridge_fs_encode_cursor / bridge_fs_decode_cursor),
// and a bridge_vcs_handle_command dispatcher (see vcs_api.odin) that speaks the
// same command_id-cached, bridge_hub_send envelope as the fs_* commands.
//
// A provider is a proc-table struct; the registry is an ordered list and the first
// adapter whose detect() returns true for a path wins (fig before git before jj).

import "core:os"
import "core:strings"
import "core:path/filepath"

// --- shared value types --------------------------------------------------

VCS_Status :: struct {
	provider: string,
	branch:   string,
	remote:   string,
	ahead:    int,
	behind:   int,
	is_clean: bool,
}

// status: added | modified | deleted | renamed | untracked
VCS_Changed_File :: struct {
	path:      string,
	status:    string,
	staged:    bool,
	additions: int,
	deletions: int,
}

// op: "+" (added) | "-" (removed) | " " (context)
VCS_Diff_Line :: struct {
	op:   string,
	text: string,
}

VCS_Diff_Hunk :: struct {
	old_start: int,
	old_len:   int,
	new_start: int,
	new_len:   int,
	lines:     []VCS_Diff_Line,
}

VCS_Capabilities :: struct {
	provider:         string,
	supports_staging: bool,
}

// --- provider interface (proc-table struct) ------------------------------

VCS_Provider :: struct {
	name:          proc() -> string,
	detect:        proc(path: string) -> bool,
	status:        proc(path: string) -> (VCS_Status, bool),
	// returns (files, next_cursor, has_more, ok)
	changed_files: proc(path, cursor: string, limit: int) -> ([]VCS_Changed_File, string, bool, bool),
	// returns (hunks, next_cursor, has_more, ok)
	diff_file:     proc(path, file, cursor: string, limit: int) -> ([]VCS_Diff_Hunk, string, bool, bool),
	capabilities:  proc(path: string) -> VCS_Capabilities,
}

// --- registry ------------------------------------------------------------

// vcs_init is retained as an empty stub so the startup call site (main.odin) stays
// valid. The provider registry is no longer held in a global slice: detection now
// always builds a stack-local provider list (see vcs_detect_provider), which avoids
// a crash observed when the .detect proc pointer was loaded through the global
// slice indirection.
vcs_init :: proc() {}

// vcs_detect_provider returns the first provider that detects a VCS at `path`.
// ok=false means no known VCS is present (or path is empty). The provider list is
// always built as a stack-local array (fig before git before jj), so the detector touches no
// shared global and is safe to call from multiple threads without any prior init.
vcs_detect_provider :: proc(path: string) -> (VCS_Provider, bool) {
	if path == "" do return VCS_Provider{}, false
	local := [3]VCS_Provider{vcs_fig_provider(), vcs_git_provider(), vcs_jj_provider()}
	providers := local[:]
	for p in providers {
		if p.detect != nil && p.detect(path) do return p, true
	}
	return VCS_Provider{}, false
}

// --- shared helpers ------------------------------------------------------

// vcs_run executes an argv (no shell) and returns its stdout plus whether the
// process ran and exited 0. Used by both adapters to shell out to git/jj. stderr
// is discarded. The returned string is owned by context.allocator.
vcs_run :: proc(args: []string) -> (out: string, ok: bool) {
	if len(args) == 0 do return "", false
	state, stdout, stderr, err := os.process_exec(os.Process_Desc{command = args}, context.allocator)
	if len(stderr) > 0 do delete(stderr, context.allocator)
	if err != nil {
		if len(stdout) > 0 do delete(stdout, context.allocator)
		return "", false
	}
	return string(stdout), state.success
}

// vcs_dir_exists reports whether `path`/<sub> exists (used by detect()).
vcs_dir_exists :: proc(path, sub: string) -> bool {
	joined, jerr := filepath.join([]string{path, sub}, context.temp_allocator)
	if jerr != nil do return false
	return os.exists(joined)
}

// vcs_paginate_files applies opaque base64 int-offset cursor pagination to a
// fully-collected changed-file list, mirroring fs_management's page logic. Returns
// (page, next_cursor, has_more).
vcs_paginate_files :: proc(all: []VCS_Changed_File, cursor: string, limit, default_limit, max_limit: int) -> ([]VCS_Changed_File, string, bool) {
	page_limit := limit
	if page_limit <= 0 do page_limit = default_limit
	if page_limit > max_limit do page_limit = max_limit
	total := len(all)
	start := bridge_fs_decode_cursor(cursor)
	if start < 0 do start = 0
	if start > total do start = total
	end := start + page_limit
	if end > total do end = total
	has_more := end < total
	next_cursor := ""
	if has_more do next_cursor = bridge_fs_encode_cursor(end)
	return all[start:end], next_cursor, has_more
}

// vcs_paginate_hunks is the hunk-list analogue of vcs_paginate_files.
vcs_paginate_hunks :: proc(all: []VCS_Diff_Hunk, cursor: string, limit, default_limit, max_limit: int) -> ([]VCS_Diff_Hunk, string, bool) {
	page_limit := limit
	if page_limit <= 0 do page_limit = default_limit
	if page_limit > max_limit do page_limit = max_limit
	total := len(all)
	start := bridge_fs_decode_cursor(cursor)
	if start < 0 do start = 0
	if start > total do start = total
	end := start + page_limit
	if end > total do end = total
	has_more := end < total
	next_cursor := ""
	if has_more do next_cursor = bridge_fs_encode_cursor(end)
	return all[start:end], next_cursor, has_more
}

// vcs_parse_unified_diff parses a unified/`--git` diff into hunks. Lines before the
// first "@@" hunk header (the diff/index/---/+++ preamble) are ignored. Within a
// hunk, a leading '+' is an added line, '-' removed, ' ' (or empty) context; the
// "\ No newline at end of file" marker and any other non +/-/space line ends the
// current hunk's line collection defensively. Shared by the git and jj adapters
// since both emit the same unified format.
vcs_parse_unified_diff :: proc(diff: string) -> []VCS_Diff_Hunk {
	hunks := make([dynamic]VCS_Diff_Hunk, context.allocator)
	lines := strings.split_lines(diff, context.temp_allocator)
	cur_lines: [dynamic]VCS_Diff_Line
	have_hunk := false
	cur := VCS_Diff_Hunk{}

	flush :: proc(hunks: ^[dynamic]VCS_Diff_Hunk, cur: ^VCS_Diff_Hunk, cur_lines: ^[dynamic]VCS_Diff_Line, have_hunk: bool) {
		if !have_hunk do return
		cur.lines = cur_lines^[:]
		append(hunks, cur^)
	}

	for line in lines {
		if strings.has_prefix(line, "@@") {
			// Close the previous hunk, then parse this header.
			flush(&hunks, &cur, &cur_lines, have_hunk)
			cur = VCS_Diff_Hunk{}
			cur_lines = make([dynamic]VCS_Diff_Line, context.allocator)
			have_hunk = true
			vcs_parse_hunk_header(line, &cur)
			continue
		}
		if !have_hunk do continue // skip file-header preamble
		// A zero-length line is never diff content: real empty context/added lines
		// still carry their one-char prefix (" " / "+"). This is the trailing
		// split_lines artifact or a blank separator, so drop it.
		if len(line) == 0 do continue
		switch line[0] {
		case '+':
			append(&cur_lines, VCS_Diff_Line{op = "+", text = strings.clone(line[1:])})
		case '-':
			append(&cur_lines, VCS_Diff_Line{op = "-", text = strings.clone(line[1:])})
		case ' ':
			append(&cur_lines, VCS_Diff_Line{op = " ", text = strings.clone(line[1:])})
		case '\\':
			// "\ No newline at end of file" — metadata, not a content line.
			continue
		case:
			// Anything else (a stray file header inside a combined diff) closes the
			// current hunk defensively; a following "@@" starts a fresh one.
			flush(&hunks, &cur, &cur_lines, have_hunk)
			have_hunk = false
		}
	}
	flush(&hunks, &cur, &cur_lines, have_hunk)
	return hunks[:]
}

// vcs_parse_hunk_header fills the old/new start+len from a "@@ -a,b +c,d @@" header.
// A missing length ("@@ -a +c @@") defaults to 1, matching unified-diff semantics.
vcs_parse_hunk_header :: proc(header: string, hunk: ^VCS_Diff_Hunk) {
	// Strip the leading "@@ " and everything from the trailing " @@".
	body := header
	if strings.has_prefix(body, "@@") do body = body[2:]
	if end := strings.index(body, "@@"); end >= 0 do body = body[:end]
	body = strings.trim_space(body)
	// body is now like "-a,b +c,d". Split on space.
	parts := strings.fields(body, context.temp_allocator)
	for part in parts {
		if len(part) < 2 do continue
		sign := part[0]
		nums := part[1:]
		start, length := vcs_split_range(nums)
		switch sign {
		case '-':
			hunk.old_start = start
			hunk.old_len = length
		case '+':
			hunk.new_start = start
			hunk.new_len = length
		}
	}
}

// vcs_split_range parses "start,len" or "start" (len defaults to 1).
vcs_split_range :: proc(s: string) -> (start: int, length: int) {
	length = 1
	comma := strings.index_byte(s, ',')
	if comma < 0 {
		return vcs_atoi(s), 1
	}
	return vcs_atoi(s[:comma]), vcs_atoi(s[comma + 1:])
}

// vcs_atoi parses a non-negative base-10 int, returning 0 on any junk (diff hunk
// counts are always non-negative integers).
vcs_atoi :: proc(s: string) -> int {
	n := 0
	trimmed := strings.trim_space(s)
	if trimmed == "" do return 0
	for ch in trimmed {
		if ch < '0' || ch > '9' do return 0
		n = n * 10 + int(ch - '0')
	}
	return n
}
