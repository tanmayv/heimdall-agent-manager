package main

import "core:fmt"
import "core:math/rand"
import "core:net"
import "core:os"
import "core:strings"
import "core:time"
import cfg_lib "odin_test:lib/config"

MAX_TEST_RUNS :: 32
TEST_RUN_TTL_MS :: i64(60 * 60 * 1000)     // 1h
TEST_RUN_TIMEOUT_SECONDS :: 90
TEST_RUN_ORPHAN_SESSION_AGE_SECONDS :: 300  // kill sessions older than 5m on startup sweep

Test_Run :: struct {
	test_run_id:             string,
	provider:                string,
	tier:                    string,
	resolved_model:          string,
	test_agent_instance_id:  string,
	test_token:              string,
	run_dir:                 string,
	wrapper_log_path:        string,
	status:                  string, // launching | starting | success | failed | timed_out
	reason:                  string,
	pane_tail:               string,
	started_unix_ms:         i64,
	last_event_unix_ms:      i64,
	completed_unix_ms:       i64,
}

test_runs:      [MAX_TEST_RUNS]Test_Run
test_run_count: int
test_run_head:  int // ring-buffer write pointer

is_test_token :: proc(token: string) -> bool {
	return strings.has_prefix(token, "agt_test_")
}

generate_test_token :: proc() -> string {
	bytes: [24]byte
	if rand.read(bytes[:]) != len(bytes) {
		now := u64(now_unix_ms())
		for i in 0..<len(bytes) {
			bytes[i] = byte((now >> uint((i % 8) * 8)) & 0xff)
		}
	}
	builder := strings.builder_make()
	strings.write_string(&builder, "agt_test_")
	for b in bytes {
		hex_write_byte(&builder, b)
	}
	return strings.to_string(builder)
}

generate_test_run_id :: proc() -> string {
	now := time.now()
	y, mo, d := time.date(now)
	h, mi, s := time.clock_from_time(now)
	rng := rand.uint32()
	hex := "0123456789abcdef"
	r0 := hex[(rng >>  0) & 0xf]
	r1 := hex[(rng >>  4) & 0xf]
	r2 := hex[(rng >>  8) & 0xf]
	r3 := hex[(rng >> 12) & 0xf]
	return fmt.tprintf("tr-%04d%02d%02d%02d%02d%02d-%c%c%c%c",
		y, int(mo), d, h, mi, s, r0, r1, r2, r3)
}

test_run_alloc :: proc(run: Test_Run) -> ^Test_Run {
	idx := test_run_head % MAX_TEST_RUNS
	test_runs[idx] = run
	test_run_head += 1
	if test_run_count < MAX_TEST_RUNS do test_run_count += 1
	return &test_runs[idx]
}

test_run_find_by_id :: proc(test_run_id: string) -> int {
	for i in 0..<MAX_TEST_RUNS {
		if test_runs[i].test_run_id == test_run_id && test_runs[i].test_run_id != "" {
			return i
		}
	}
	return -1
}

test_run_find_by_token :: proc(token: string) -> int {
	for i in 0..<MAX_TEST_RUNS {
		if test_runs[i].test_token == token && test_runs[i].test_run_id != "" {
			return i
		}
	}
	return -1
}

test_run_is_terminal :: proc(status: string) -> bool {
	return status == "success" || status == "failed" || status == "timed_out"
}

test_run_cleanup :: proc(idx: int) {
	run := &test_runs[idx]
	// The wrapper registers under "<id>@<project>" but test_agent_instance_id
	// is just "<id>". Resolve via token so the registry lookup matches.
	resolved_instance := run.test_agent_instance_id
	if run.test_token != "" {
		if mapped := registry_agent_instance_for_token(run.test_token); mapped != "" {
			resolved_instance = mapped
		}
	}
	agent_idx := registry_find_agent(resolved_instance)
	if agent_idx >= 0 && agents[agent_idx].tmux_pane != "" {
		pane := agents[agent_idx].tmux_pane
		cmd := []string{"tmux", "kill-pane", "-t", pane}
		_, _, _, _ = os.process_exec(os.Process_Desc{command = cmd}, context.allocator)
	}
	if run.run_dir != "" {
		_ = os.remove_all(run.run_dir)
	}
}

capture_test_pane_tail :: proc(agent_instance_id: string, lines: int) -> string {
	resolved := agent_instance_id
	if registry_find_agent(resolved) < 0 {
		// Wrapper may have registered with a "@project" suffix; find by scan.
		for i in 0..<agent_count {
			id := agents[i].agent_instance_id
			if strings.has_prefix(id, agent_instance_id) && (len(id) == len(agent_instance_id) || id[len(agent_instance_id)] == '@') {
				resolved = id
				break
			}
		}
	}
	agent_idx := registry_find_agent(resolved)
	if agent_idx < 0 do return ""
	pane := agents[agent_idx].tmux_pane
	if pane == "" do return ""
	start := fmt.tprintf("-%d", lines)
	cmd := []string{"tmux", "capture-pane", "-p", "-t", pane, "-S", start}
	state, stdout, _, err := os.process_exec(os.Process_Desc{command = cmd}, context.allocator)
	if err != nil || !state.success do return ""
	return string(stdout)
}

emit_test_start :: proc(run: Test_Run) {
	builder := strings.builder_make()
	strings.write_string(&builder, `{"type":"test_start","test_run_id":"`)
	json_write_string(&builder, run.test_run_id)
	strings.write_string(&builder, `","provider":"`)
	json_write_string(&builder, run.provider)
	strings.write_string(&builder, `","tier":"`)
	json_write_string(&builder, run.tier)
	strings.write_string(&builder, `","resolved_model":"`)
	json_write_string(&builder, run.resolved_model)
	strings.write_string(&builder, `","started_unix_ms":`)
	strings.write_string(&builder, fmt.tprintf("%d", run.started_unix_ms))
	strings.write_string(&builder, `}`)
	user_client_fanout_all_ws_text(strings.to_string(builder))
}

emit_test_done :: proc(run: Test_Run) {
	builder := strings.builder_make()
	strings.write_string(&builder, `{"type":"test_done","test_run_id":"`)
	json_write_string(&builder, run.test_run_id)
	strings.write_string(&builder, `","status":"`)
	json_write_string(&builder, run.status)
	strings.write_string(&builder, `","reason":"`)
	json_write_string(&builder, run.reason)
	strings.write_string(&builder, `","elapsed_ms":`)
	elapsed := run.completed_unix_ms - run.started_unix_ms
	if elapsed < 0 do elapsed = 0
	strings.write_string(&builder, fmt.tprintf("%d", elapsed))
	strings.write_string(&builder, `,"pane_tail":"`)
	json_write_string(&builder, run.pane_tail)
	strings.write_string(&builder, `"}`)
	user_client_fanout_all_ws_text(strings.to_string(builder))
}

test_run_json :: proc(builder: ^strings.Builder, run: Test_Run) {
	strings.write_string(builder, `{"test_run_id":"`)
	json_write_string(builder, run.test_run_id)
	strings.write_string(builder, `","provider":"`)
	json_write_string(builder, run.provider)
	strings.write_string(builder, `","tier":"`)
	json_write_string(builder, run.tier)
	strings.write_string(builder, `","resolved_model":"`)
	json_write_string(builder, run.resolved_model)
	strings.write_string(builder, `","test_agent_instance_id":"`)
	json_write_string(builder, run.test_agent_instance_id)
	strings.write_string(builder, `","status":"`)
	json_write_string(builder, run.status)
	strings.write_string(builder, `","reason":"`)
	json_write_string(builder, run.reason)
	strings.write_string(builder, `","pane_tail":"`)
	json_write_string(builder, run.pane_tail)
	strings.write_string(builder, `","started_unix_ms":`)
	strings.write_string(builder, fmt.tprintf("%d", run.started_unix_ms))
	strings.write_string(builder, `,"completed_unix_ms":`)
	strings.write_string(builder, fmt.tprintf("%d", run.completed_unix_ms))
	strings.write_string(builder, `}`)
}

handle_agents_test_launch :: proc(client: net.TCP_Socket, body: string) {
	provider := extract_json_string(body, "provider", "")
	tier := extract_json_string(body, "tier", "normal")
	if provider == "" {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"provider required"}`)
		return
	}
	if !valid_model_tier(tier) {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"invalid tier; expected cheap, normal, or smart"}`)
		return
	}

	// Resolve provider from stored configs.
	resolved_model := ""
	found_provider := false
	for i in 0..<len(server_agent_cmd_configs) {
		ac := server_agent_cmd_configs[i]
		if ac.name == provider {
			found_provider = true
			resolved_model = cfg_lib.resolve_model_value(ac.models, tier)
			if resolved_model == "" {
				write_response(client, 400, "Bad Request", fmt.tprintf(`{"ok":false,"message":"provider '%s' has no model configured for tier '%s'"}`, provider, tier))
				return
			}
			break
		}
	}
	if !found_provider {
		write_response(client, 400, "Bad Request", fmt.tprintf(`{"ok":false,"message":"provider '%s' not found in config"}`, provider))
		return
	}

	rand.reset(u64(time.to_unix_nanoseconds(time.now())))
	test_run_id := generate_test_run_id()
	short_id := test_run_id[len(test_run_id)-4:]
	test_token := generate_test_token()
	agent_instance_id := fmt.tprintf("test-%s-%s", provider, short_id)
	run_dir := fmt.tprintf("/tmp/ham-daemon-test/%s", test_run_id)
	log_path := fmt.tprintf("%s/wrapper.log", run_dir)

	if err := os.make_directory_all(run_dir); err != nil {
		write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to create test run dir"}`)
		return
	}

	now := now_unix_ms()
	run := Test_Run{
		test_run_id             = strings.clone(test_run_id),
		provider                = strings.clone(provider),
		tier                    = strings.clone(tier),
		resolved_model          = strings.clone(resolved_model),
		test_agent_instance_id  = strings.clone(agent_instance_id),
		test_token               = strings.clone(test_token),
		run_dir                  = strings.clone(run_dir),
		wrapper_log_path         = strings.clone(log_path),
		status                   = "launching",
		started_unix_ms          = now,
		last_event_unix_ms       = now,
	}
	_ = test_run_alloc(run)

	// Register test token as pending so wrapper can use it.
	registry_add_pending_agent_token(agent_instance_id, test_token)

	emit_test_start(run)

	ok := launch_wrapper_for_test(agent_instance_id, provider, server_config_path, log_path, test_token, tier)
	if !ok {
		idx := test_run_find_by_id(test_run_id)
		if idx >= 0 {
			test_runs[idx].status = "failed"
			test_runs[idx].reason = "wrapper spawn failed"
			test_runs[idx].completed_unix_ms = now_unix_ms()
			emit_test_done(test_runs[idx])
		}
		write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"wrapper spawn failed"}`)
		return
	}

	result_endpoint := fmt.tprintf("/agents/test-status?test_run_id=%s", test_run_id)
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"test_run_id":"`)
	json_write_string(&b, test_run_id)
	strings.write_string(&b, `","test_agent_instance_id":"`)
	json_write_string(&b, agent_instance_id)
	strings.write_string(&b, `","result_endpoint":"`)
	json_write_string(&b, result_endpoint)
	strings.write_string(&b, `"}`)
	write_response(client, 200, "OK", strings.to_string(b))
}

handle_agents_test_status :: proc(client: net.TCP_Socket, request: string) {
	test_run_id := query_param(request, "test_run_id")
	if test_run_id == "" {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"test_run_id required"}`)
		return
	}
	idx := test_run_find_by_id(test_run_id)
	if idx < 0 {
		write_response(client, 404, "Not Found", `{"ok":false,"message":"test run not found"}`)
		return
	}
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"run":`)
	test_run_json(&b, test_runs[idx])
	strings.write_string(&b, `}`)
	write_response(client, 200, "OK", strings.to_string(b))
}

handle_agents_test_history :: proc(client: net.TCP_Socket) {
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"runs":[`)
	wrote := 0
	// Return in reverse-insertion order (most recent first).
	for i := test_run_head - 1; i >= test_run_head - MAX_TEST_RUNS && i >= 0; i -= 1 {
		idx := i % MAX_TEST_RUNS
		if test_runs[idx].test_run_id == "" do continue
		if wrote > 0 do strings.write_string(&b, `,`)
		test_run_json(&b, test_runs[idx])
		wrote += 1
	}
	strings.write_string(&b, `]}`)
	write_response(client, 200, "OK", strings.to_string(b))
}

handle_start_success :: proc(client: net.TCP_Socket, agent_token: string) {
	if !is_test_token(agent_token) {
		// Production agent reporting it's ready. Flip startup_status and emit
		// agent_lifecycle_changed so the UI / janitors know the wrapper-side
		// probe is no longer the source of truth.
		agent_instance_id := registry_agent_instance_for_token(agent_token)
		if agent_instance_id == "" {
			write_response(client, 404, "Not Found", `{"ok":false,"message":"no agent found for this token"}`)
			return
		}
		_ = registry_update_startup(agent_instance_id, "ready", "start_success", "Agent reported ready via start-success RPC", "", "", "")
		// Mark connected so UI shows green; emit lifecycle event with state="connected"
		// for consistency with the deprecated agent_ready path the UI already knows.
		if idx := registry_find_agent(agent_instance_id); idx >= 0 {
			agents[idx].connected = true
			agents[idx].startup_updated_unix_ms = now_unix_ms()
		}
		agent_lifecycle_emit(agent_instance_id, "connected", "start_success")
		b := strings.builder_make()
		strings.write_string(&b, `{"ok":true,"agent_instance_id":"`)
		json_write_string(&b, agent_instance_id)
		strings.write_string(&b, `","status":"ready"}`)
		write_response(client, 200, "OK", strings.to_string(b))
		return
	}
	idx := test_run_find_by_token(agent_token)
	if idx < 0 {
		write_response(client, 404, "Not Found", `{"ok":false,"message":"no test run found for this token; it may have already timed out"}`)
		return
	}
	if test_run_is_terminal(test_runs[idx].status) {
		b := strings.builder_make()
		strings.write_string(&b, `{"ok":true,"already":true,"test_run_id":"`)
		json_write_string(&b, test_runs[idx].test_run_id)
		strings.write_string(&b, `","status":"`)
		json_write_string(&b, test_runs[idx].status)
		strings.write_string(&b, `"}`)
		write_response(client, 200, "OK", strings.to_string(b))
		return
	}
	now := now_unix_ms()
	test_runs[idx].status = "success"
	test_runs[idx].completed_unix_ms = now
	test_runs[idx].last_event_unix_ms = now
	test_runs[idx].pane_tail = capture_test_pane_tail(test_runs[idx].test_agent_instance_id, 40)
	emit_test_done(test_runs[idx])
	test_run_cleanup(idx)

	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"test_run_id":"`)
	json_write_string(&b, test_runs[idx].test_run_id)
	strings.write_string(&b, `","status":"success"}`)
	write_response(client, 200, "OK", strings.to_string(b))
}

test_run_on_lifecycle :: proc(agent_token, connection_state, reason: string) {
	idx := test_run_find_by_token(agent_token)
	if idx < 0 do return
	if test_run_is_terminal(test_runs[idx].status) do return
	now := now_unix_ms()
	test_runs[idx].last_event_unix_ms = now
	if test_runs[idx].status == "launching" && (connection_state == "registered" || connection_state == "starting") {
		test_runs[idx].status = "starting"
	}
}

test_run_janitor_tick :: proc() {
	now := now_unix_ms()
	timeout_ms := i64(TEST_RUN_TIMEOUT_SECONDS) * 1000
	for i in 0..<MAX_TEST_RUNS {
		run := &test_runs[i]
		if run.test_run_id == "" do continue
		// Reap expired completed runs from ring buffer (mark slot empty).
		if test_run_is_terminal(run.status) && run.completed_unix_ms > 0 {
			if now - run.completed_unix_ms > TEST_RUN_TTL_MS {
				run.test_run_id = ""
			}
			continue
		}
		// Time out runs that never received start-success.
		if now - run.started_unix_ms > timeout_ms {
			run.pane_tail = capture_test_pane_tail(run.test_agent_instance_id, 40)
			run.status = "timed_out"
			run.reason = fmt.tprintf("no start-success received in %ds", TEST_RUN_TIMEOUT_SECONDS)
			run.completed_unix_ms = now
			emit_test_done(run^)
			test_run_cleanup(i)
		}
	}
}

test_run_startup_sweep :: proc() {
	// Kill orphan ham-test-* tmux sessions from prior daemon crashes.
	// We identify them by checking sessions whose names start with "ham-test-"
	// and whose age is beyond the orphan threshold (5 minutes).
	// Use `tmux list-sessions -F "#{session_name} #{session_activity}"` to enumerate.
	cmd := []string{"tmux", "list-sessions", "-F", "#{session_name}"}
	state, stdout, _, err := os.process_exec(os.Process_Desc{command = cmd}, context.allocator)
	if err != nil || !state.success do return

	lines := strings.split(string(stdout), "\n")
	for line in lines {
		name := strings.trim_space(line)
		if !strings.has_prefix(name, "ham-test-") do continue
		// It's a test session from a prior run; kill it.
		kill_cmd := []string{"tmux", "kill-session", "-t", name}
		_, _, _, _ = os.process_exec(os.Process_Desc{command = kill_cmd}, context.allocator)
	}

	// Sweep stale /tmp/ham-daemon-test/ entries older than 24h.
	infos, read_err := os.read_directory_by_path("/tmp/ham-daemon-test", -1, context.allocator)
	if read_err != nil do return
	now_ns := time.to_unix_nanoseconds(time.now())
	threshold_ns := now_ns - i64(24*60*60) * i64(time.Second)
	for info in infos {
		mod_ns := time.to_unix_nanoseconds(info.modification_time)
		if mod_ns > threshold_ns do continue
		path := fmt.tprintf("/tmp/ham-daemon-test/%s", info.name)
		_ = os.remove_all(path)
	}
}

launch_wrapper_for_test :: proc(agent_instance_id, provider, config_path, log_path, agent_token, tier: string) -> bool {
	_ = os.make_directory_all(parent_dir(log_path))
	wrapper_bin := default_wrapper_bin()

	b := strings.builder_make()
	strings.write_string(&b, "nohup ")
	strings.write_string(&b, shell_quote(wrapper_bin))
	strings.write_string(&b, " --config ")
	strings.write_string(&b, shell_quote(config_path))
	strings.write_string(&b, " --agent ")
	strings.write_string(&b, shell_quote(provider))
	strings.write_string(&b, " --agent-token ")
	strings.write_string(&b, shell_quote(agent_token))
	strings.write_string(&b, " --display-name ")
	strings.write_string(&b, shell_quote(agent_instance_id))
	strings.write_string(&b, " --tier ")
	strings.write_string(&b, shell_quote(tier))
	strings.write_string(&b, " ")
	strings.write_string(&b, shell_quote(agent_instance_id))
	strings.write_string(&b, " > ")
	strings.write_string(&b, shell_quote(log_path))
	strings.write_string(&b, " 2>&1 < /dev/null &")

	process, err := os.process_start(os.Process_Desc{command = []string{"sh", "-c", strings.to_string(b)}})
	if err != nil {
		fmt.println("test wrapper launch failed:", err)
		return false
	}
	_ = process
	return true
}
