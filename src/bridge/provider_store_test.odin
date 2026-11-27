package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

Provider_Discovery_Test_Job :: struct {
	filter: []string,
	results: [dynamic]Bridge_Provider_Path,
}

provider_discovery_test_worker :: proc(th: ^thread.Thread) {
	job := (^Provider_Discovery_Test_Job)(th.data)
	job.results = bridge_provider_discover(job.filter)
}

@(test)
test_provider_json_helpers :: proc(t: ^testing.T) {
	body := `{"provider":"codex","models":["gpt-5","gpt-5-pro"]}`
	provider := bridge_provider_json_extract_string(body, "provider", "")
	defer delete(provider)
	testing.expect_value(t, provider, "codex")
	models, ok := bridge_provider_json_extract_string_array(body, "models")
	defer if models != nil {
		for model in models do delete(model)
		delete(models)
	}
	testing.expect(t, ok)
	testing.expect_value(t, len(models), 2)
	if len(models) == 2 do testing.expect_value(t, models[1], "gpt-5-pro")
}

@(test)
test_provider_shell_join_quotes_arguments :: proc(t: ^testing.T) {
	joined := bridge_shell_join([]string{"/usr/bin/codex", "-m", "gpt-5 pro", "it's ready"})
	defer delete(joined)
	testing.expect(t, strings.contains(joined, "'gpt-5 pro'"))
	testing.expect(t, strings.contains(joined, "'it'\\''s ready'"))
}

@(test)
test_runtime_find_on_path_returns_owned_path :: proc(t: ^testing.T) {
	path := bridge_runtime_find_on_path("sh")
	if !testing.expect(t, path != "", "test shell is discoverable on PATH") do return
	// The resolver contract gives ownership to the caller. In particular, an
	// already-absolute PATH entry must not be freed inside the resolver and then
	// returned as a dangling string.
	delete(path)
}

@(test)
test_provider_removed_from_path_degrades_to_absent :: proc(t: ^testing.T) {
	result := bridge_provider_probe_one(
		"codex",
		"heimdall-provider-binary-that-does-not-exist-18dcd",
	)
	defer bridge_provider_path_destroy(&result)
	testing.expect_value(t, result.provider, "codex")
	testing.expect_value(t, result.state, "absent")
	testing.expect_value(t, result.resolved_path, "")
	// Destruction is part of the regression: an unavailable formerly-cached
	// provider must produce a fully owned absent record, not a dangling PATH
	// string that crashes the Bridge during launch cleanup.
}

@(test)
test_provider_version_probe_kills_and_reaps_at_deadline :: proc(t: ^testing.T) {
	path := fmt.aprintf("/tmp/heimdall-provider-probe-timeout-%d", time.to_unix_nanoseconds(time.now()))
	defer { _ = os.remove(path); delete(path) }
	fixture := "#!/bin/sh\nwhile :; do :; done\n"
	write_err := os.write_entire_file(path, fixture)
	if !testing.expect(t, write_err == nil, "timeout fixture must be writable") do return
	chmod_err := os.chmod(path, os.Permissions{.Read_User, .Write_User, .Execute_User})
	if !testing.expect(t, chmod_err == nil, "timeout fixture must be executable") do return
	started := time.to_unix_nanoseconds(time.now())
	probe := bridge_provider_cli_version(bridge_provider_descriptor("claude"), path, nil, 50 * time.Millisecond)
	elapsed := time.to_unix_nanoseconds(time.now()) - started
	testing.expect(t, !probe.ok && probe.timed_out && probe.raw == "" && probe.parsed == "", "timed out provider probe must not report a version")
	testing.expect(t, elapsed < i64(2 * time.Second), "timed out provider probe must be killed and reaped promptly")
}

@(test)
test_provider_discovery_coalesces_identical_concurrent_scans :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	filter := []string{"provider-that-is-not-in-the-catalog"}
	// Other tests resolve provider paths concurrently and start their own scans, so
	// the global scan count is not ours alone: count only scans for this test's key.
	filter_key := bridge_provider_discovery_key(filter)
	defer delete(filter_key)
	sync.mutex_lock(&bridge_provider_discovery_mutex)
	bridge_provider_discovery_test_key = filter_key
	bridge_provider_discovery_test_key_scans = 0
	sync.mutex_unlock(&bridge_provider_discovery_mutex)
	bridge_provider_discovery_test_delay = 100 * time.Millisecond
	defer {
		bridge_provider_discovery_test_delay = 0
		sync.mutex_lock(&bridge_provider_discovery_mutex)
		bridge_provider_discovery_test_key = ""
		sync.mutex_unlock(&bridge_provider_discovery_mutex)
	}

	jobs := [2]Provider_Discovery_Test_Job{{filter = filter}, {filter = filter}}
	workers: [2]^thread.Thread
	for i in 0..<2 {
		workers[i] = thread.create(provider_discovery_test_worker)
		workers[i].data = rawptr(&jobs[i])
		thread.start(workers[i])
	}
	for i in 0..<2 {
		thread.join(workers[i])
		thread.destroy(workers[i])
	}
	defer for &job in jobs {
		for &result in job.results do bridge_provider_path_destroy(&result)
		delete(job.results)
	}

	sync.mutex_lock(&bridge_provider_discovery_mutex)
	scans := bridge_provider_discovery_test_key_scans
	sync.mutex_unlock(&bridge_provider_discovery_mutex)
	testing.expect_value(t, scans, u64(1))
	testing.expect_value(t, len(jobs[0].results), len(jobs[1].results))
}

@(test)
bridge_provider_catalog_name_supported_accepts_slugs_only :: proc(t: ^testing.T) {
	for name in ([]string{"claude", "codex", "copilot", "antigravity", "pi", "open-code", "gpt5"}) {
		testing.expectf(t, bridge_provider_catalog_name_supported(name), "%q should be a supported provider slug", name)
	}
	for name in ([]string{"", "Claude", "pi agent", "-pi", "pi-", "pi/x", "a-very-long-provider-name-over-32b"}) {
		testing.expectf(t, !bridge_provider_catalog_name_supported(name), "%q should be rejected", name)
	}
}

@(test)
bridge_provider_catalog_valid_accepts_any_provider_count :: proc(t: ^testing.T) {
	models := []Bridge_Catalog_Model{{model_id = "m1", label = "M1", state = "active"}}
	providers := []Bridge_Catalog_Provider{
		{provider = "claude", display_name = "Claude Code", binary = "claude", state = "active", models = models},
		{provider = "codex", display_name = "Codex", binary = "codex", state = "active", models = models},
		{provider = "copilot", display_name = "GitHub Copilot", binary = "copilot", state = "active", models = models},
		{provider = "antigravity", display_name = "Antigravity", binary = "agy", state = "active", models = models},
		{provider = "pi", display_name = "Pi", binary = "pi", state = "active", models = models},
	}
	testing.expect(t, bridge_provider_catalog_valid({providers = providers}), "five-provider catalog (with pi) is valid")
	testing.expect(t, bridge_provider_catalog_valid({providers = providers[:1]}), "single-provider catalog is valid")
	testing.expect(t, !bridge_provider_catalog_valid({}), "empty catalog is rejected")

	duplicate := []Bridge_Catalog_Provider{providers[0], providers[0]}
	testing.expect(t, !bridge_provider_catalog_valid({providers = duplicate}), "duplicate provider is rejected")

	bad_name := []Bridge_Catalog_Provider{{provider = "Pi Agent", display_name = "Pi", binary = "pi", state = "active", models = models}}
	testing.expect(t, !bridge_provider_catalog_valid({providers = bad_name}), "malformed provider name is rejected")

	no_models := []Bridge_Catalog_Provider{{provider = "pi", display_name = "Pi", binary = "pi", state = "active"}}
	testing.expect(t, !bridge_provider_catalog_valid({providers = no_models}), "provider without models is rejected")
}

// Pin the native PTY boundary, including account-profile args and repeated
// launches of the same instance. ACP constructs its argv separately.
@(test)
test_codex_native_launch_bypasses_loaded_daemon_on_restart :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	testing.expect(t, bridge_codex_no_daemon_supported("codex-test-daemon-supported", proc(_: string) -> Bridge_Codex_Daemon_Probe_Result { return {.Supported, 0, false} }))
	for mode in ([]string{"ask", "yolo"}) {
		for extra in ([][]string{nil, {"-c", "features.daemon_auto_start=true"}}) {
			profile := Bridge_Provider_Profile{
				name = "codex", command = {"codex-test-daemon-supported"}, model_flag = "-m",
				ask_flags = {"--ask-for-approval", "on-request"},
				yolo_flags = {"--ask-for-approval", "never"},
				extra_args = extra, prompt_delivery = "flag-injection",
				starter_prompt = "start the worker",
			}
			// The old daemon can still be loaded when the PTY is restarted. Both
			// launches must bypass it, regardless of the user's feature setting.
			for attempt in 0..<2 {
				req, ok := bridge_pty_host_build_spawn_for_profile("inst_codex_restart", "/managed/run", profile, "model", "token", nil, permission_mode = mode)
				testing.expect(t, ok)
				if !ok do continue
				testing.expect_value(t, req.instance, "inst_codex_restart")
				testing.expect_value(t, req.argv[len(req.argv)-2], "--no-daemon")
				testing.expect(t, strings.has_prefix(req.argv[len(req.argv)-1], "start the worker"))
				for arg, i in extra do testing.expect_value(t, req.argv[len(req.argv)-2-len(extra)+i], arg)
				bridge_pty_host_spawn_request_delete(req)
			}
		}
	}
	bridge_pty_host_untrack_instance_provider("inst_codex_restart")
}

@(test)
test_native_daemon_bypass_is_codex_only :: proc(t: ^testing.T) {
	profile := Bridge_Provider_Profile{
		name = "claude", command = {"claude"}, model_flag = "--model",
		extra_args = {"--verbose"}, prompt_delivery = "none",
	}
	argv := bridge_runtime_agent_argv_for_profile(profile, "model", "token", "inst_claude")
	defer delete(argv)
	testing.expect_value(t, len(argv), 4)
	for arg in argv do testing.expect(t, arg != "--no-daemon")
	testing.expect_value(t, argv[len(argv)-1], "--verbose")
}


@(test)
test_codex_native_launch_without_daemon_option_keeps_legacy_argv :: proc(t: ^testing.T) {
	path := "codex-test-daemon-unsupported"
	testing.expect(t, !bridge_codex_no_daemon_supported(path, proc(_: string) -> Bridge_Codex_Daemon_Probe_Result { return {.Unsupported, 0, false} }))
	// A later caller must use the cached result rather than probe again.
	testing.expect(t, !bridge_codex_no_daemon_supported(path, proc(_: string) -> Bridge_Codex_Daemon_Probe_Result { return {.Supported, 0, false} }))
	profile := Bridge_Provider_Profile{
		name = "codex", command = {path}, model_flag = "-m",
		extra_args = {"--verbose"}, prompt_delivery = "none",
	}
	argv := bridge_runtime_agent_argv_for_profile(profile, "model", "token", "inst_legacy_codex")
	defer delete(argv)
	testing.expect_value(t, len(argv), 4)
	testing.expect_value(t, argv[0], path)
	testing.expect_value(t, argv[1], "-m")
	testing.expect_value(t, argv[2], "model")
	testing.expect_value(t, argv[3], "--verbose")
}

@(test)
test_codex_native_daemon_probe_requires_successful_help_option :: proc(t: ^testing.T) {
	for path in ([]string{"supported", "unsupported", "failed", "timeout", "start_failed", "empty"}) {
		result := bridge_codex_no_daemon_probe(path, proc(args: []string, timeout: time.Duration) -> (string, string, int, bool, bool) {
			if len(args) != 2 || args[1] != "--help" || timeout != 2*time.Second do return "", "", -1, false, false
			help := "Options:\n      --no-daemon\n          Run without daemon\n"
			if args[0] == "unsupported" do help = "Options:\n      --no-daemon-extra\n"
			if args[0] == "failed" do return strings.clone(help), "", 1, false, false
			if args[0] == "timeout" do return strings.clone(help), "", -1, false, true
			if args[0] == "start_failed" do return "", "", -1, false, false
			if args[0] == "empty" do return "", "", 0, true, false
			return strings.clone(help), "", 0, true, false
		})
		expected: Bridge_Codex_Daemon_Support = .Unknown
		if path == "supported" do expected = .Supported
		if path == "unsupported" do expected = .Unsupported
		testing.expect_value(t, result.status, expected)
		testing.expect_value(t, result.timed_out, path == "timeout")
		if path == "failed" do testing.expect_value(t, result.exit_code, 1)
		if path == "start_failed" || path == "timeout" do testing.expect_value(t, result.exit_code, -1)
	}
	// Positive capability is cached as well, separately for each binary path.
	testing.expect(t, bridge_codex_no_daemon_supported("codex-test-daemon-cache", proc(_: string) -> Bridge_Codex_Daemon_Probe_Result { return {.Supported, 0, false} }))
	testing.expect(t, bridge_codex_no_daemon_supported("codex-test-daemon-cache", proc(_: string) -> Bridge_Codex_Daemon_Probe_Result { return {.Unsupported, 0, false} }))
}

@(test)
test_codex_native_daemon_transient_probe_failure_retries :: proc(t: ^testing.T) {
	for path in ([]string{"codex-test-probe-slot-or-start", "codex-test-probe-timeout", "codex-test-probe-nonzero"}) {
		testing.expect(t, !bridge_codex_no_daemon_supported(path, proc(path: string) -> Bridge_Codex_Daemon_Probe_Result {
			if strings.has_suffix(path, "timeout") do return {.Unknown, -1, true}
			if strings.has_suffix(path, "nonzero") do return {.Unknown, 1, false}
			return {.Unknown, -1, false}
		}))
		// The next launch must probe again and enable the bypass, rather than
		// caching a temporary slot shortage, start failure or timeout forever.
		testing.expect(t, bridge_codex_no_daemon_supported(path, proc(_: string) -> Bridge_Codex_Daemon_Probe_Result { return {.Supported, 0, false} }))
		profile := Bridge_Provider_Profile{name = "codex", command = {path}, model_flag = "-m", prompt_delivery = "none"}
		argv := bridge_runtime_agent_argv_for_profile(profile, "model", "token", "inst_retry_codex")
		testing.expect_value(t, argv[len(argv)-1], "--no-daemon")
		delete(argv)
	}
}
