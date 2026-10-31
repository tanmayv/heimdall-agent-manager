package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import json "core:encoding/json"
import cfg_lib "odin_test:lib/config"

session_test_root :: proc(t: ^testing.T) -> string {
	home: string
	{ context.allocator = context.temp_allocator; home = cfg_lib.home_dir() }
	root := fmt.aprintf("%s/.cache/heimdall-tests/session-projects-%d", home, time.to_unix_nanoseconds(time.now()))
	testing.expect(t, os.make_directory_all(root) == nil)
	canonical, _ := session_project_resolve(root, root)
	delete(root)
	return canonical
}
session_test_seed :: proc(t: ^testing.T, root, rel, body: string) {
	full := fmt.tprintf("%s/%s", root, rel)
	_ = os.make_directory_all(full[:strings.last_index_byte(full, '/')])
	testing.expect(t, os.write_entire_file_from_string(full, body) == nil)
}

@(test)
session_projects_empty_and_sandbox :: proc(t: ^testing.T) {
	root := session_test_root(t)
	defer { _ = os.remove_all(root); delete(root) }
	r := session_projects_discover(root, root)
	defer session_projects_destroy(&r)
	testing.expect(t, r.ok)
	testing.expect_value(t, len(r.projects), 0)
	wire, marshal_err := json.marshal(r)
	defer delete(wire)
	testing.expect(t, marshal_err == nil && strings.contains(string(wire), `"projects":[]`))
	_ = os.make_directory_all(fmt.tprintf("%s/.codex/sessions", root))
	r2 := session_projects_discover(root, fmt.tprintf("%s/elsewhere", root))
	defer session_projects_destroy(&r2)
	testing.expect_value(t, len(r2.projects), 0)
}

@(test)
session_projects_metadata_and_malformed :: proc(t: ^testing.T) {
	root := session_test_root(t)
	defer { _ = os.remove_all(root); delete(root) }
	cwd := fmt.tprintf("%s/code/app", root)
	_ = os.make_directory_all(cwd)
	meta := struct {type: string, payload: struct {cwd: string}}{type = "session_meta"}
	meta.payload.cwd = cwd
	data, _ := json.marshal(meta, allocator = context.temp_allocator)
	session_test_seed(t, root, ".codex/sessions/2026/10/rollout-a.jsonl", fmt.tprintf("bad json\n%s\n", string(data)))
	session_test_seed(t, root, ".codex/sessions/2026/10/rollout-b.jsonl", string(data))
	session_test_seed(t, root, ".codex/sessions/rollout-bad.jsonl", "{bad")
	session_test_seed(t, root, ".codex/sessions/ignored.jsonl", string(data))
	session_test_seed(t, root, ".codex/sessions/rollout-relative.jsonl", "{\"type\":\"session_meta\",\"payload\":{\"cwd\":\"relative\"}}")
	session_test_seed(t, root, ".claude/projects/-home-me-app/a.jsonl", "malformed session contents are never read")
	session_test_seed(t, root, ".claude/projects/-home-me-app/b.jsonl", "")
	session_test_seed(t, root, ".claude/projects/-home-me-app/memory/a.jsonl", "not a session")
	session_test_seed(t, root, ".claude/projects/empty/note.txt", "")
	older := time.unix(1_700_000_000, 0)
	newer := time.unix(1_700_003_600, 0)
	for rel in ([]string{".codex/sessions/2026/10/rollout-a.jsonl", ".claude/projects/-home-me-app/a.jsonl"}) {
		testing.expect(t, os.change_times(fmt.tprintf("%s/%s", root, rel), older, older) == nil)
	}
	for rel in ([]string{".codex/sessions/2026/10/rollout-b.jsonl", ".claude/projects/-home-me-app/b.jsonl"}) {
		testing.expect(t, os.change_times(fmt.tprintf("%s/%s", root, rel), newer, newer) == nil)
	}
	r := session_projects_discover(root, root)
	defer session_projects_destroy(&r)
	if !testing.expect_value(t, len(r.projects), 2) do return
	for project in r.projects {
		testing.expect_value(t, project.sessions, 2)
		testing.expect_value(t, project.last_session_at, bridge_fs_format_mtime(newer))
		if project.source == "Codex" { testing.expect_value(t, project.path, cwd) }
		else { testing.expect_value(t, project.path, "-home-me-app") }
	}
	r.command_id = "test"
	wire, err := json.marshal(r)
	defer delete(wire)
	testing.expect(t, err == nil)
	testing.expect(t, !strings.contains(string(wire), "malformed session contents"))
}

@(test)
session_projects_deadline_and_unreadable :: proc(t: ^testing.T) {
	root := session_test_root(t)
	defer { _ = os.remove_all(root); delete(root) }
	session_test_seed(t, root, ".codex/sessions/rollout-bad.jsonl", "{")
	testing.expect_value(t, session_project_codex_cwd(fmt.tprintf("%s/missing", root)), "")
	testing.expect_value(t, session_project_codex_cwd(fmt.tprintf("%s/.codex/sessions/rollout-bad.jsonl", root)), "")
	r := session_projects_discover(root, root, time.to_unix_nanoseconds(time.now()) - 1)
	defer session_projects_destroy(&r)
	testing.expect(t, r.truncated)
	testing.expect_value(t, len(r.projects), 0)
}


// Symlinked files and directories cannot escape fixed history roots.
@(test)
session_projects_ignores_symlink_history :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows { return }
	root := session_test_root(t)
	defer { _ = os.remove_all(root); delete(root) }
	session_test_seed(t, root, "outside/rollout-secret.jsonl", fmt.tprintf(`{{"type":"session_meta","payload":{{"cwd":"%s"}}}}`, root))
	_ = os.make_directory_all(fmt.tprintf("%s/.codex/sessions", root))
	testing.expect(t, os.symlink(fmt.tprintf("%s/outside", root), fmt.tprintf("%s/.codex/sessions/escape", root)) == nil)
	testing.expect(t, os.symlink(fmt.tprintf("%s/outside/rollout-secret.jsonl", root), fmt.tprintf("%s/.codex/sessions/rollout-link.jsonl", root)) == nil)
	r := session_projects_discover(root, root)
	defer session_projects_destroy(&r)
	testing.expect_value(t, len(r.projects), 0)
}

@(test)
session_projects_reports_prefix_limit :: proc(t: ^testing.T) {
	root := session_test_root(t)
	defer { _ = os.remove_all(root); delete(root) }
	data := make([]byte, 256 * 1024 + 1)
	defer delete(data)
	for &byte in data do byte = 'x'
	session_test_seed(t, root, ".codex/sessions/rollout-large.jsonl", string(data))
	r := session_projects_discover(root, root)
	defer session_projects_destroy(&r)
	testing.expect(t, r.truncated, "incomplete metadata prefix must be visible to the user")
	testing.expect_value(t, len(r.projects), 0)
}
