package main

import "core:os"
import "core:strings"
import "core:testing"

// BR-1 unit tests: the bridge-side clean-slate + HEIMDALL_* env map that runs
// pre-spawn. The hub-backed assembly (bridge_bootstrap_fetch_and_materialize) is
// covered through the launch path; here we lock in the clean-slate guarantee and
// the env shape, which are the parts that carry the WRP-1 semantics forward.

// bridge_prespawn_test_tmp returns a unique tmp run_dir path for a test.
bridge_prespawn_test_tmp :: proc(name: string) -> string {
	return strings.concatenate({"/tmp/ham-br1-", name})
}

// bridge_prespawn_test_write seeds a file (creating parents), freeing the joined
// path so tests stay leak-clean.
bridge_prespawn_test_write :: proc(t: ^testing.T, dir, rel, content: string) {
	full := strings.concatenate({dir, "/", rel})
	defer delete(full)
	if slash := strings.last_index_byte(full, '/'); slash > 0 {
		parent := full[:slash]
		_ = os.make_directory_all(parent)
	}
	testing.expect(t, os.write_entire_file(full, transmute([]u8)content) == nil, "seed file")
}

// bridge_prespawn_test_absent reports (via expect) that dir/rel does not exist,
// freeing the joined path.
bridge_prespawn_test_absent :: proc(t: ^testing.T, dir, rel, why: string) {
	full := strings.concatenate({dir, "/", rel})
	defer delete(full)
	fi, err := os.stat(full, context.allocator)
	if err == nil do os.file_info_delete(fi, context.allocator)
	testing.expect(t, err != nil, why)
}

@(test)
bridge_prespawn_clean_slate_creates_empty_dir :: proc(t: ^testing.T) {
	dir := bridge_prespawn_test_tmp("fresh")
	defer delete(dir)
	defer bridge_prespawn_rmdir_all(dir)
	bridge_prespawn_rmdir_all(dir) // start from nothing

	bridge_prespawn_clean_slate(dir)

	fi, err := os.stat(dir, context.allocator)
	testing.expect(t, err == nil, "run_dir should exist after clean_slate")
	testing.expect(t, fi.type == .Directory, "run_dir should be a directory")
	if err == nil do os.file_info_delete(fi, context.allocator)

	// Freshly created dir has no entries.
	fd, oerr := os.open(dir)
	testing.expect(t, oerr == nil, "run_dir should be openable")
	infos, rerr := os.read_dir(fd, -1, context.allocator)
	os.close(fd)
	testing.expect(t, rerr == nil, "run_dir should be readable")
	testing.expect_value(t, len(infos), 0)
	os.file_info_slice_delete(infos, context.allocator)
}

@(test)
bridge_prespawn_clean_slate_removes_stale_files :: proc(t: ^testing.T) {
	dir := bridge_prespawn_test_tmp("relaunch")
	defer delete(dir)
	defer bridge_prespawn_rmdir_all(dir)
	bridge_prespawn_rmdir_all(dir)

	// Simulate a prior run's placement: a stale bootstrap file, a nested skill,
	// and the ham-ctl shim under .heimdall/bin.
	bridge_prespawn_test_write(t, dir, "CLAUDE.md", "stale")
	bridge_prespawn_test_write(t, dir, ".heimdall/bin/ham-ctl", "old shim")
	bridge_prespawn_test_write(t, dir, "skills/old-skill/SKILL.md", "old skill")

	// A simulated relaunch clean-slates the dir.
	bridge_prespawn_clean_slate(dir)

	// Nothing stale survives: the dir exists but is empty.
	bridge_prespawn_test_absent(t, dir, "CLAUDE.md", "stale CLAUDE.md must be gone after relaunch")
	bridge_prespawn_test_absent(t, dir, ".heimdall/bin/ham-ctl", "stale ham-ctl shim must be gone after relaunch")
	bridge_prespawn_test_absent(t, dir, "skills/old-skill/SKILL.md", "stale skill must be gone after relaunch")

	fd, oerr := os.open(dir)
	testing.expect(t, oerr == nil, "run_dir should be openable after relaunch")
	infos, rerr := os.read_dir(fd, -1, context.allocator)
	os.close(fd)
	testing.expect(t, rerr == nil, "run_dir should be readable after relaunch")
	testing.expect_value(t, len(infos), 0)
	os.file_info_slice_delete(infos, context.allocator)
}

@(test)
bridge_prespawn_env_has_all_heimdall_vars :: proc(t: ^testing.T) {
	env := bridge_prespawn_env("/tmp/run/inst_abc", "unix:/tmp/bridge.sock", "hlat_tok_1", "inst_abc")
	defer { for e in env do delete(e); delete(env) }

	testing.expect_value(t, len(env), 4)
	testing.expect(t, bridge_prespawn_test_env_has(env, "HEIMDALL_BRIDGE_ENDPOINT=unix:/tmp/bridge.sock"), "endpoint entry")
	testing.expect(t, bridge_prespawn_test_env_has(env, "HEIMDALL_AGENT_TOKEN=hlat_tok_1"), "token entry")
	testing.expect(t, bridge_prespawn_test_env_has(env, "HEIMDALL_AGENT_INSTANCE_ID=inst_abc"), "instance entry")
	testing.expect(t, bridge_prespawn_test_env_has(env, "HEIMDALL_CTL_BIN=/tmp/run/inst_abc/.heimdall/bin/ham-ctl"), "ctl bin entry")
}

@(test)
bridge_prespawn_ctl_bin_path_is_run_dir_relative :: proc(t: ^testing.T) {
	p1 := bridge_prespawn_ctl_bin_path("/tmp/run/inst_abc")
	defer delete(p1)
	testing.expect_value(t, p1, "/tmp/run/inst_abc/.heimdall/bin/ham-ctl")
	// Trailing slash on run_dir must not double up.
	p2 := bridge_prespawn_ctl_bin_path("/tmp/run/inst_abc/")
	defer delete(p2)
	testing.expect_value(t, p2, "/tmp/run/inst_abc/.heimdall/bin/ham-ctl")
}

// bridge_prespawn_test_env_has reports whether want is present in env.
bridge_prespawn_test_env_has :: proc(env: []string, want: string) -> bool {
	for e in env do if e == want do return true
	return false
}
