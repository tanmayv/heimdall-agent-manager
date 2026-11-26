#+build !windows
package main

import "core:fmt"
import agent_runtime "odin_test:lib/agent_runtime"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:sys/posix"

// BR-1 unit tests: the bridge-side clean-slate + HEIMDALL_* env map that runs
// pre-spawn. The hub-backed assembly (bridge_bootstrap_fetch_and_materialize) is
// covered through the launch path; here we lock in the clean-slate guarantee and
// the env shape, which are the parts that carry the WRP-1 semantics forward.

// bridge_prespawn_test_tmp returns a unique tmp run_dir path for a test.
bridge_prespawn_test_tmp :: proc(name: string) -> string {
	return fmt.aprintf("/tmp/ham-br1-%s-%d", name, os.get_pid())
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
	// the ham-ctl shim under bin/, and a shim left at the pre-bin/ location.
	bridge_prespawn_test_write(t, dir, "CLAUDE.md", "stale")
	bridge_prespawn_test_write(t, dir, "bin/ham-ctl", "old shim")
	bridge_prespawn_test_write(t, dir, ".heimdall/bin/ham-ctl", "legacy shim")
	bridge_prespawn_test_write(t, dir, "skills/old-skill/SKILL.md", "old skill")

	// A simulated relaunch clean-slates the dir.
	bridge_prespawn_clean_slate(dir)

	// Nothing stale survives: the dir exists but is empty.
	bridge_prespawn_test_absent(t, dir, "CLAUDE.md", "stale CLAUDE.md must be gone after relaunch")
	bridge_prespawn_test_absent(t, dir, "bin/ham-ctl", "stale ham-ctl shim must be gone after relaunch")
	bridge_prespawn_test_absent(t, dir, ".heimdall/bin/ham-ctl", "legacy-location ham-ctl shim must be gone after relaunch")
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

	when ODIN_OS == .Linux {
		expected := 5
		for name in BRIDGE_BROWSER_SESSION_ENV {
			value := os.get_env(name, context.temp_allocator)
			if value == "" {
				testing.expect(t, !bridge_prespawn_test_env_has(env, fmt.tprintf("%s=", name)))
			} else {
				expected += 1
				testing.expect(t, bridge_prespawn_test_env_has(env, fmt.tprintf("%s=%s", name, value)))
			}
		}
		testing.expect_value(t, len(env), expected)
	} else {
		testing.expect_value(t, len(env), 5)
	}
	testing.expect(t, bridge_prespawn_test_env_has(env, "HEIMDALL_BRIDGE_ENDPOINT=unix:/tmp/bridge.sock"), "endpoint entry")
	testing.expect(t, bridge_prespawn_test_env_has(env, "HEIMDALL_AGENT_TOKEN=hlat_tok_1"), "token entry")
	testing.expect(t, bridge_prespawn_test_env_has(env, "HEIMDALL_AGENT_INSTANCE_ID=inst_abc"), "instance entry")
	testing.expect(t, bridge_prespawn_test_env_has(env, "HEIMDALL_CTL_BIN=/tmp/run/inst_abc/bin/ham-ctl"), "ctl bin entry")
}

@(test)
bridge_prespawn_ctl_bin_path_is_run_dir_relative :: proc(t: ^testing.T) {
	p1 := bridge_prespawn_ctl_bin_path("/tmp/run/inst_abc")
	defer delete(p1)
	testing.expect_value(t, p1, "/tmp/run/inst_abc/bin/ham-ctl")
	// Trailing slash on run_dir must not double up.
	p2 := bridge_prespawn_ctl_bin_path("/tmp/run/inst_abc/")
	defer delete(p2)
	testing.expect_value(t, p2, "/tmp/run/inst_abc/bin/ham-ctl")
}

@(test)
// The prespawn env must NOT carry the vault key. It used to, and because the env is
// built once at spawn and never refreshed while ctl checks $HEIMDALL_VAULT_KEY
// (source 2) before the key file (source 3), a rotated key left every running agent
// authoritatively holding the OLD one — silent decryption failure for the rest of
// the instance's life. This assertion is deliberately inverted from its original
// form so that re-adding the bake fails the suite rather than passing it.
bridge_prespawn_env_omits_vault_key :: proc(t: ^testing.T) {
	env := bridge_prespawn_env(
		"/tmp/run/inst_abc",
		"unix:/tmp/bridge.sock",
		"hlat_tok_1",
		"inst_abc",
	)
	defer { for e in env do delete(e); delete(env) }

	testing.expect(t, bridge_prespawn_test_env_has(env, "HEIMDALL_BRIDGE_ENDPOINT=unix:/tmp/bridge.sock"), "endpoint entry")
	testing.expect(t, bridge_prespawn_test_env_has(env, "HEIMDALL_AGENT_TOKEN=hlat_tok_1"), "token entry")
	testing.expect(t, bridge_prespawn_test_env_has(env, "HEIMDALL_AGENT_INSTANCE_ID=inst_abc"), "instance entry")
	testing.expect(t, bridge_prespawn_test_env_has(env, "HEIMDALL_CTL_BIN=/tmp/run/inst_abc/bin/ham-ctl"), "ctl bin entry")

	// No HEIMDALL_VAULT_KEY entry under any value: assert on the NAME, so the test
	// still catches a re-added bake that uses a different key.
	for e in env {
		testing.expect(t, !strings.has_prefix(e, "HEIMDALL_VAULT_KEY="), "prespawn env must not carry the vault key")
	}
}

// bridge_prespawn_test_env_has reports whether want is present in env.
bridge_prespawn_test_env_has :: proc(env: []string, want: string) -> bool {
	for e in env do if e == want do return true
	return false
}

// The rendered ham-ctl shim must not bake the vault key either. The shim is written
// once per spawn from the key as it was AT THAT MOMENT, so a baked `export
// HEIMDALL_VAULT_KEY` is stale the instant the operator rotates the key — and being
// an export it then overrides the correct value ctl would otherwise read from the
// key file. Dropping it is what makes the key resolve live on every invocation.
//
// Asserted on the variable NAME so that re-adding the bake under any value fails.
@(test)
bridge_bootstrap_shim_omits_vault_key :: proc(t: ^testing.T) {
	// HEIMDALL_VAULT_KEY is a PROCESS-GLOBAL and this test mutated it while holding no
	// lock at all, racing every other env-mutating test (iss_18db48473fc5cb6d, 2026-10-04).
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	// Point the resolver at a real executable so rendering can succeed; the shim
	// only embeds this path, it never runs it.
	prev, had := os.lookup_env("HEIMDALL_HAM_CTL_BIN", context.allocator)
	defer {
		if had {
			_ = os.set_env("HEIMDALL_HAM_CTL_BIN", prev)
		} else {
			os.unset_env("HEIMDALL_HAM_CTL_BIN")
		}
		delete(prev)
	}
	_ = os.set_env("HEIMDALL_HAM_CTL_BIN", "/bin/sh")

	// A key IS configured while this renders, which is the whole point: even with a
	// key available, the shim must not capture it.
	prev_key, had_key := os.lookup_env("HEIMDALL_VAULT_KEYRING", context.allocator)
	defer {
		if had_key {
			_ = os.set_env("HEIMDALL_VAULT_KEYRING", prev_key)
		} else {
			os.unset_env("HEIMDALL_VAULT_KEYRING")
		}
		delete(prev_key)
	}
	_ = os.set_env("HEIMDALL_VAULT_KEYRING", test_keyring_env_value("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))

	script, ok := bridge_bootstrap_render_ham_ctl_shim("unix:/tmp/bridge.sock", "hlat_tok_1", "inst_abc")
	testing.expect(t, ok, "shim must render when ham-ctl resolves")
	if !ok do return
	defer delete(script)

	testing.expect(
		t,
		!strings.contains(script, "HEIMDALL_VAULT_KEYRING"),
		"the rendered ham-ctl shim must not bake the vault key",
	)

	// The three the shim legitimately carries must all still be there, so this test
	// fails loudly if the removal took anything else with it.
	testing.expect(t, strings.contains(script, "HEIMDALL_BRIDGE_ENDPOINT="), "shim keeps the endpoint")
	testing.expect(t, strings.contains(script, "HEIMDALL_AGENT_TOKEN="), "shim keeps the agent token")
	testing.expect(t, strings.contains(script, "HEIMDALL_AGENT_INSTANCE_ID="), "shim keeps the instance id")
}

// The same guarantee for the wrapper that is actually written to disk. This is the
// live path — bridge_bootstrap_write_ham_ctl_wrapper is called from
// bootstrap_service.odin:51 and :89 — so a bake re-added here would reach real
// agents even if the renderer above stayed clean. Asserted by reading the file back,
// not the builder, so it also covers the write.
@(test)
bridge_bootstrap_written_wrapper_omits_vault_key :: proc(t: ^testing.T) {
	// HEIMDALL_VAULT_KEY is a PROCESS-GLOBAL and this test mutated it while holding no
	// lock at all, racing every other env-mutating test (iss_18db48473fc5cb6d, 2026-10-04).
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	prev, had := os.lookup_env("HEIMDALL_HAM_CTL_BIN", context.allocator)
	defer {
		if had {
			_ = os.set_env("HEIMDALL_HAM_CTL_BIN", prev)
		} else {
			os.unset_env("HEIMDALL_HAM_CTL_BIN")
		}
		delete(prev)
	}
	_ = os.set_env("HEIMDALL_HAM_CTL_BIN", "/bin/sh")

	// A key IS configured while the wrapper is written: that is the condition under
	// which the old code baked it in.
	prev_key, had_key := os.lookup_env("HEIMDALL_VAULT_KEYRING", context.allocator)
	defer {
		if had_key {
			_ = os.set_env("HEIMDALL_VAULT_KEYRING", prev_key)
		} else {
			os.unset_env("HEIMDALL_VAULT_KEYRING")
		}
		delete(prev_key)
	}
	_ = os.set_env("HEIMDALL_VAULT_KEYRING", test_keyring_env_value("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))

	run_dir := fmt.aprintf("/tmp/heimdall-bridge-wrapper-test-%d", int(posix.getpid()))
	defer delete(run_dir)
	defer _ = os.remove_all(run_dir)
	_ = os.make_directory_all(run_dir)

	ok := bridge_bootstrap_write_ham_ctl_wrapper(run_dir, "unix:/tmp/bridge.sock", "hlat_tok_1", "inst_abc")
	testing.expect(t, ok, "wrapper must be written")
	if !ok do return

	wrapper_path := fmt.aprintf("%s/bin/ham-ctl", run_dir)
	defer delete(wrapper_path)
	data, err := os.read_entire_file(wrapper_path, context.allocator)
	testing.expect(t, err == nil, "wrapper must be readable")
	if err != nil do return
	defer delete(data)

	script := string(data)
	testing.expect(
		t,
		!strings.contains(script, "HEIMDALL_VAULT_KEYRING"),
		"the written ham-ctl wrapper must not bake the vault key",
	)
	testing.expect(t, strings.contains(script, "HEIMDALL_BRIDGE_ENDPOINT="), "wrapper keeps the endpoint")
	testing.expect(t, strings.contains(script, "HEIMDALL_AGENT_TOKEN="), "wrapper keeps the agent token")
	testing.expect(t, strings.contains(script, "HEIMDALL_AGENT_INSTANCE_ID="), "wrapper keeps the instance id")

	// The starter prompt must name exactly the shim the bridge just wrote.
	prompt := agent_runtime.render_starter_prompt_for_agent(agent_runtime.Agent_Profile{starter_prompt = "Run {ctl_bin} start-success."}, "", "hlat_tok_1", "inst_abc")
	defer delete(prompt)
	testing.expect(t, strings.contains(prompt, "Run ./bin/ham-ctl agent start-success."), "starter prompt points at the written shim")
	testing.expect(t, strings.contains(prompt, "use `./bin/ham-ctl` for CLI actions"), "runtime footer points at the written shim")
}

// ---- REQ-37: wake_agent / scheduler launch descriptor round-trip ----

@(test)
wake_launch_command_json_roundtrips_full_descriptor :: proc(t: ^testing.T) {
	cmd := bridge_wake_launch_command_json(
		"cmd_1", "inst_abc", "task_9", "reviewer", "pi", "smart",
		"agt_42", "coder", "chain_7", "Heimdall — Coordinator Session",
		"inst_coord", "proj_3", "/home/x/project",
	)
	defer delete(cmd)

	testing.expect(t, strings.contains(cmd, "\"type\":\"launch_agent\""))
	d := bridge_bootstrap_descriptor_from_launch(cmd)
	testing.expect_value(t, d.instance_id, "inst_abc")
	testing.expect_value(t, d.agent_id, "agt_42")
	testing.expect_value(t, d.agent_name, "coder")
	testing.expect_value(t, d.role, "reviewer")
	testing.expect_value(t, d.chain_id, "chain_7")
	testing.expect_value(t, d.chain_title, "Heimdall — Coordinator Session")
	testing.expect_value(t, d.coordinator_id, "inst_coord")
	testing.expect_value(t, d.project_id, "proj_3")
	testing.expect_value(t, d.project_path, "/home/x/project")
}

@(test)
wake_launch_command_json_escapes_free_text :: proc(t: ^testing.T) {
	cmd := bridge_wake_launch_command_json(
		"cmd_2", "inst_q", "", "worker", "", "",
		"agt_1", "coder", "chain_1", "Say \"hi\" now",
		"", "proj_1", "",
	)
	defer delete(cmd)
	d := bridge_bootstrap_descriptor_from_launch(cmd)
	testing.expect_value(t, d.agent_id, "agt_1")
	testing.expect_value(t, d.chain_title, "Say \"hi\" now")
}

@(test)
bare_launch_payload_leaves_agent_id_empty :: proc(t: ^testing.T) {
	bare := "{\"type\":\"launch_agent\",\"command_id\":\"c\",\"payload\":{\"agent_instance_id\":\"inst_bare\"}}"
	d := bridge_bootstrap_descriptor_from_launch(bare)
	testing.expect_value(t, d.instance_id, "inst_bare")
	testing.expect_value(t, d.agent_id, "")
	testing.expect_value(t, d.role, "worker")
}

// Task System v2 (M1): a wake run entry's lease_id + pack ride the synthetic
// launch verbatim (the bootstrap consumes them in M3); the descriptor still
// parses, and non-lease wakes omit both keys.
@(test)
wake_launch_command_json_forwards_lease_and_pack :: proc(t: ^testing.T) {
	cmd := bridge_wake_launch_command_json(
		"cmd_3", "inst_l", "task_l", "worker", "claude", "opus",
		"agt_l", "coder", "chain_l", "Chain L",
		"inst_coord", "proj_l", "/srv/l", "", "lease_77", `{"version":1,"why":"first_grant"}`,
	)
	defer delete(cmd)
	testing.expect(t, strings.contains(cmd, `"lease_id":"lease_77"`), "lease_id forwarded")
	testing.expect(t, strings.contains(cmd, `"pack":{"version":1,"why":"first_grant"}`), "pack forwarded verbatim")
	d := bridge_bootstrap_descriptor_from_launch(cmd)
	testing.expect_value(t, d.instance_id, "inst_l")
	testing.expect_value(t, d.agent_id, "agt_l")
	plain := bridge_wake_launch_command_json("cmd_4", "inst_p", "", "worker", "", "", "agt_p", "coder", "chain_p", "P", "", "", "")
	defer delete(plain)
	testing.expect(t, !strings.contains(plain, "lease_id") && !strings.contains(plain, "\"pack\""), "no lease keys without a lease")
}

// nix develop can mount its private /tmp as uid nobody. That is correctly
// rejected by the resolver, so give these cases a real owner-controlled root.
bridge_browser_test_root :: proc() -> (string, os.Error) {
	dir, err := os.get_working_directory(context.temp_allocator)
	if err != nil do return "", err
	return os.make_directory_temp(dir, "ham-browser-fixture-*", context.allocator)
}

@(test)
bridge_browser_profile_persists_and_separates_registrations :: proc(t: ^testing.T) {
	root, err := bridge_browser_test_root()
	if !testing.expect(t, err == nil) do return
	defer { _ = os.remove_all(root); delete(root) }
	first := bridge_os_browser_profile_dir(root, "brg_a")
	defer delete(first)
	second := bridge_os_browser_profile_dir(root, "brg_b")
	defer delete(second)
	if !testing.expect(t, first != "" && second != "" && first != second) do return
	marker := fmt.tprintf("%s/fixture", first)
	if !testing.expect(t, os.write_entire_file_from_string(marker, "local-only") == nil) do return
	reopened := bridge_os_browser_profile_dir(root, "brg_a")
	defer delete(reopened)
	contents, read_err := os.read_entire_file(fmt.tprintf("%s/fixture", reopened), context.temp_allocator)
	testing.expect(t, first == reopened && read_err == nil && string(contents) == "local-only")
	_, other_err := os.stat(fmt.tprintf("%s/fixture", second), context.temp_allocator)
	testing.expect(t, other_err != nil)
}

@(test)
bridge_browser_profile_refuses_symlinks_and_unsafe_mode :: proc(t: ^testing.T) {
	root, err := bridge_browser_test_root()
	if !testing.expect(t, err == nil) do return
	defer { _ = os.remove_all(root); delete(root) }
	first := bridge_os_browser_profile_dir(root, "brg_a")
	defer delete(first)
	if !testing.expect(t, first != "") do return
	link := strings.clone_to_cstring(fmt.tprintf("%s/browser-profiles/brg_b", root), context.temp_allocator)
	target := strings.clone_to_cstring(fmt.tprintf("%s/browser-profiles/brg_a", root), context.temp_allocator)
	if !testing.expect(t, posix.symlink(target, link) == .OK) do return
	bad := bridge_os_browser_profile_dir(root, "brg_b")
	defer delete(bad)
	testing.expect_value(t, bad, "")
	if !testing.expect(t, posix.chmod(strings.clone_to_cstring(first, context.temp_allocator), posix.S_IRWXU | posix.S_IRWXG) == .OK) do return
	wide := bridge_os_browser_profile_dir(root, "brg_a")
	defer delete(wide)
	testing.expect_value(t, wide, "")
}

@(test)
bridge_browser_profile_resolves_only_trusted_ancestor_alias :: proc(t: ^testing.T) {
	root, err := bridge_browser_test_root()
	if !testing.expect(t, err == nil) do return
	defer { _ = os.remove_all(root); delete(root) }
	link := strings.clone_to_cstring(fmt.tprintf("%s/alias", root), context.temp_allocator)
	if !testing.expect(t, posix.symlink("real", link) == .OK) do return
	direct := bridge_os_browser_profile_dir(fmt.tprintf("%s/real/data", root), "brg_a")
	defer delete(direct)
	if !testing.expect(t, direct != "") do return
	// Model a system-owned protected parent with a fixture owned by this
	// unprivileged test process. The public entry point still requires UID 0.
	uid := posix.geteuid()
	resolved := bridge_browser_walk_unix(fmt.tprintf("%s/alias/data/browser-profiles/brg_a/browser-profile", root), uid, 16)
	defer delete(resolved)
	managed := bridge_browser_walk_unix(fmt.tprintf("%s/alias/browser-profiles/brg_a/browser-profile", root), uid, 16)
	defer delete(managed)
	testing.expect_value(t, resolved, direct)
	testing.expect_value(t, managed, "")
	if uid != 0 {
		untrusted := bridge_os_browser_profile_dir(fmt.tprintf("%s/alias/data", root), "brg_a")
		defer delete(untrusted)
		testing.expect_value(t, untrusted, "")
	}
}

@(test)
bridge_browser_shell_desktop_env_preserves_explicit_values :: proc(t: ^testing.T) {
	config := Bridge_Config{}
	env := bridge_shell_child_env(.Run, {{"DISPLAY", ":99"}, {"DBUS_SESSION_BUS_ADDRESS", ""}}, &config)
	defer bridge_pty_host_spawn_request_delete({env = env})
	values := [?][2]string{{"DISPLAY", ":99"}, {"DBUS_SESSION_BUS_ADDRESS", ""}}
	for expected in values {
		count := 0
		for pair in env {
			if pair[0] != expected[0] do continue
			count += 1
			testing.expect_value(t, pair[1], expected[1])
		}
		testing.expect_value(t, count, 1)
	}
}

@(test)
bridge_browser_profile_matches_in_agent_and_shell_children :: proc(t: ^testing.T) {
	root, err := bridge_browser_test_root()
	if !testing.expect(t, err == nil) do return
	defer { _ = os.remove_all(root); delete(root) }
	config := Bridge_Config{data_dir = root, daemon_id = "brg_fixture"}
	// Optional host smoke: pass a system alias for the current workdir while
	// still creating and cleaning up only this test's unique fixture.
	if alias := os.get_env("HAM_TEST_BROWSER_WORKDIR_ALIAS", context.temp_allocator); alias != "" {
		cwd, cwd_err := os.get_working_directory(context.temp_allocator)
		if !testing.expect(t, cwd_err == nil && strings.has_prefix(root, fmt.tprintf("%s/", cwd))) do return
		config.data_dir = fmt.tprintf("%s%s", alias, root[len(cwd):])
	}
	expected := fmt.tprintf("%s/browser-profiles/brg_fixture/browser-profile", root)
	argv := [?]string{"/bin/sh", "-c", `printf '%s' "$HEIMDALL_BROWSER_PROFILE_DIR"`}

	instances := [?]string{"agent_a", "agent_b"}
	for instance in instances {
		env := bridge_prespawn_env(root, "", "", instance, &config)
		defer { for e in env do delete(e); delete(env) }
		state, stdout, stderr, exec_err := os.process_exec({command = argv[:], env = env}, context.temp_allocator)
		testing.expect(t, exec_err == nil && state.exit_code == 0, string(stderr))
		testing.expect_value(t, string(stdout), expected)
	}

	kinds := [?]Bridge_Shell_Session_Kind{.Run, .Shell, .Server}
	for kind in kinds {
		env := bridge_shell_child_env(kind, {{BRIDGE_BROWSER_PROFILE_ENV, "/unrelated"}}, &config)
		defer bridge_pty_host_spawn_request_delete({env = env})
		child_env := make([]string, len(env), context.temp_allocator)
		for pair, i in env do child_env[i] = fmt.tprintf("%s=%s", pair[0], pair[1])
		state, stdout, stderr, exec_err := os.process_exec({command = argv[:], env = child_env}, context.temp_allocator)
		testing.expect(t, exec_err == nil && state.exit_code == 0, string(stderr))
		testing.expect_value(t, string(stdout), expected)
	}
}
