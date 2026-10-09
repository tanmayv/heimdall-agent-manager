package main

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import ws "odin_test:lib/ws"

// Commands known to perform process, PTY-host, filesystem, or network waits are
// admitted here instead of being executed by the Hub WebSocket reader. The first
// slice deliberately covers the incident paths; commands not listed here retain
// their existing path until their state/ordering contract is migrated.
Bridge_Command_Class :: enum {
	Lifecycle,
	Interactive,
	Background,
	Exclusive,
	General_IO,
	Shell,
}

Bridge_Dispatch_Claim_State :: enum {
	Queued,
	Running,
	Completed,
}

Bridge_Dispatch_Job :: struct {
	text: string,
	command_id: string,
	command_type: string,
	ordering_key: string,
	class: Bridge_Command_Class,
	generation: i64,
	deadline_ns: i64,
	owned_bytes: int,
}

Bridge_Dispatch_Output :: struct {
	text: string,
	generation: i64,
}

Bridge_Dispatch_Claim :: struct {
	command_id: string,
	state: Bridge_Dispatch_Claim_State,
	result_json: string,
}

Bridge_Dispatch_Worker :: struct {
	index: int,
	class: Bridge_Command_Class,
	sink_conn: ws.Connection,
	current_generation: i64,
	current_command_id: string,
	last_result: string,
	output_failed: bool,
}

BRIDGE_DISPATCH_TOTAL_LIMIT :: 128
BRIDGE_DISPATCH_RECOVERY_RESERVE :: 8
BRIDGE_DISPATCH_LIFECYCLE_LIMIT :: 32
BRIDGE_DISPATCH_INTERACTIVE_LIMIT :: 48
BRIDGE_DISPATCH_BACKGROUND_LIMIT :: 32
BRIDGE_DISPATCH_EXCLUSIVE_LIMIT :: 4
BRIDGE_DISPATCH_GENERAL_IO_LIMIT :: 24
BRIDGE_DISPATCH_SHELL_LIMIT :: 24
BRIDGE_DISPATCH_OWNED_BYTES_LIMIT :: 4 * 1024 * 1024
BRIDGE_DISPATCH_RECOVERY_BYTES_RESERVE :: 256 * 1024
BRIDGE_DISPATCH_COMMAND_BYTES_LIMIT :: 1024 * 1024
BRIDGE_DISPATCH_OUTBOX_BYTES_LIMIT :: 8 * 1024 * 1024
BRIDGE_DISPATCH_DEFAULT_TIMEOUT_MS :: 30_000
BRIDGE_DISPATCH_CLAIM_LIMIT :: 256

bridge_dispatch_mu: sync.Mutex
bridge_dispatch_lifecycle: [dynamic]Bridge_Dispatch_Job
bridge_dispatch_interactive: [dynamic]Bridge_Dispatch_Job
bridge_dispatch_background: [dynamic]Bridge_Dispatch_Job
bridge_dispatch_exclusive: [dynamic]Bridge_Dispatch_Job
bridge_dispatch_general_io: [dynamic]Bridge_Dispatch_Job
bridge_dispatch_shell: [dynamic]Bridge_Dispatch_Job
bridge_dispatch_outputs: [dynamic]Bridge_Dispatch_Output
bridge_dispatch_claims: [dynamic]Bridge_Dispatch_Claim
bridge_dispatch_workers: [12]Bridge_Dispatch_Worker
bridge_dispatch_active_keys: [dynamic]string
bridge_dispatch_owned_bytes: int
bridge_dispatch_outbox_bytes: int
bridge_dispatch_generation: i64
bridge_dispatch_initialized: bool

bridge_command_dispatch_init :: proc() {
	sync.mutex_lock(&bridge_dispatch_mu)
	if bridge_dispatch_initialized {
		sync.mutex_unlock(&bridge_dispatch_mu)
		return
	}
	bridge_dispatch_lifecycle = make([dynamic]Bridge_Dispatch_Job, runtime.default_allocator())
	bridge_dispatch_interactive = make([dynamic]Bridge_Dispatch_Job, runtime.default_allocator())
	bridge_dispatch_background = make([dynamic]Bridge_Dispatch_Job, runtime.default_allocator())
	bridge_dispatch_exclusive = make([dynamic]Bridge_Dispatch_Job, runtime.default_allocator())
	bridge_dispatch_general_io = make([dynamic]Bridge_Dispatch_Job, runtime.default_allocator())
	bridge_dispatch_shell = make([dynamic]Bridge_Dispatch_Job, runtime.default_allocator())
	bridge_dispatch_outputs = make([dynamic]Bridge_Dispatch_Output, runtime.default_allocator())
	bridge_dispatch_claims = make([dynamic]Bridge_Dispatch_Claim, runtime.default_allocator())
	bridge_dispatch_active_keys = make([dynamic]string, runtime.default_allocator())
	classes := [12]Bridge_Command_Class{.Lifecycle, .Lifecycle, .Interactive, .Interactive, .Background, .Exclusive, .General_IO, .General_IO, .General_IO, .General_IO, .Shell, .Shell}
	for class, i in classes {
		bridge_dispatch_workers[i].index = i
		bridge_dispatch_workers[i].class = class
	}
	bridge_dispatch_initialized = true
	sync.mutex_unlock(&bridge_dispatch_mu)
	for i in 0..<len(bridge_dispatch_workers) {
		_ = thread.create_and_start_with_data(rawptr(&bridge_dispatch_workers[i]), bridge_command_dispatch_worker)
	}
}

bridge_command_dispatch_begin_connection :: proc() -> i64 {
	bridge_command_dispatch_init()
	sync.mutex_lock(&bridge_dispatch_mu)
	defer sync.mutex_unlock(&bridge_dispatch_mu)
	bridge_dispatch_generation += 1
	bridge_command_dispatch_drop_stale_queue_locked(&bridge_dispatch_lifecycle, bridge_dispatch_generation)
	bridge_command_dispatch_drop_stale_queue_locked(&bridge_dispatch_interactive, bridge_dispatch_generation)
	bridge_command_dispatch_drop_stale_queue_locked(&bridge_dispatch_background, bridge_dispatch_generation)
	bridge_command_dispatch_drop_stale_queue_locked(&bridge_dispatch_exclusive, bridge_dispatch_generation)
	bridge_command_dispatch_drop_stale_queue_locked(&bridge_dispatch_general_io, bridge_dispatch_generation)
	bridge_command_dispatch_drop_stale_queue_locked(&bridge_dispatch_shell, bridge_dispatch_generation)
	return bridge_dispatch_generation
}

bridge_command_dispatch_drop_stale_queue_locked :: proc(queue: ^[dynamic]Bridge_Dispatch_Job, generation: i64) {
	for i := 0; i < len(queue); {
		job := queue[i]
		if job.generation == generation { i += 1; continue }
		if claim_i := bridge_command_dispatch_claim_index_locked(job.command_id); claim_i >= 0 {
			delete(bridge_dispatch_claims[claim_i].command_id, runtime.default_allocator())
			delete(bridge_dispatch_claims[claim_i].result_json, runtime.default_allocator())
			ordered_remove(&bridge_dispatch_claims, claim_i)
		}
		bridge_dispatch_owned_bytes -= job.owned_bytes
		delete(job.text, runtime.default_allocator())
		delete(job.command_id, runtime.default_allocator())
		delete(job.command_type, runtime.default_allocator())
		delete(job.ordering_key, runtime.default_allocator())
		ordered_remove(queue, i)
	}
}

bridge_command_dispatch_class :: proc(command_type: string) -> (Bridge_Command_Class, bool) {
	switch command_type {
	case "launch_agent", "launch_provider_test", "stop_agent", "wake_agent", "agent_pty_input", "agent_pty_resize", "bridge_unseal", "bridge_lock", "set_telemetry", "lsp_start", "lsp_stop":
		return .Lifecycle, true
	case "notify_agent_message", "notify_task_nudge", "notify_shell_run", "notify_title_nudge", "task_status_changed_notify", "capture_agent_pane", "get_agent_pane":
		return .Interactive, true
	case "provider_discover", "shell_stream_attach":
		return .Background, true
	case "bridge_update":
		return .Exclusive, true
	case "fs_list_dir", "fs_stat", "fs_make_dir", "fs_read_file", "agent_run_dir_list", "agent_run_dir_read", "fs_create_file", "fs_write_file", "fs_batch_write", "fs_move", "fs_delete", "fs_find_files", "fs_grep", "vcs_capabilities", "vcs_status", "vcs_files", "vcs_diff", "vcs_stage", "vcs_unstage", "vcs_revert", "vcs_save_file", "vcs_commit", "vcs_upload", "vcs_push", "vcs_sync", "vcs_pull", "vcs_log", "vcs_commit_diff", "vcs_workspaces":
		return .General_IO, true
	case "get_shell_output", "shell_pty_input", "shell_pty_resize", "shell_stream_detach", "shell_start", "shell_background", "shell_kill", "shell_signal", "shell_restart", "shell_set_port", "shell_list", "shell_logs", "shell_capture", "shell_get_pane":
		return .Shell, true
	}
	return .Interactive, false
}

bridge_command_inline_type :: proc(command_type: string) -> bool {
	switch command_type {
	case "bridge_heartbeat_ack", "provider_catalog_version", "provider_catalog", "lsp_send", "tunnel_open", "tunnel_data", "tunnel_close", "proxy_data", "proxy_close":
		return true
	}
	return false
}

bridge_command_is_recovery :: proc(command_type: string) -> bool {
	switch command_type {
	case "stop_agent", "bridge_lock", "shell_kill", "shell_signal", "shell_stream_detach", "lsp_stop":
		return true
	}
	return false
}

bridge_command_ordering_key :: proc(command_type, text: string) -> string {
	switch command_type {
	case "provider_discover": return strings.clone("provider-discovery")
	case "bridge_update": return strings.clone("bridge-update")
	case "bridge_unseal", "bridge_lock", "set_telemetry": return strings.clone("bridge-control")
	case "fs_make_dir", "fs_create_file", "fs_write_file", "fs_batch_write", "fs_move", "fs_delete":
		// Batch operations can touch several paths. A single filesystem mutation key
		// is conservative but correct until canonical roots are part of the contract.
		return strings.clone("fs-mutation")
	case "vcs_stage", "vcs_unstage", "vcs_revert", "vcs_save_file", "vcs_commit", "vcs_upload", "vcs_push", "vcs_sync", "vcs_pull":
		root := extract_json_string(text, "root", "")
		if root == "" {
			delete(root)
			root = extract_json_string(text, "path", "")
		}
		defer delete(root)
		return strings.concatenate({"vcs:", root if root != "" else "global"})
	}
	if strings.has_prefix(command_type, "shell_") || command_type == "get_shell_output" {
		id := extract_json_string(text, "session_id", "")
		if id == "" {
			delete(id)
			id = extract_json_string(text, "shell_id", "")
		}
		defer delete(id)
		if id != "" do return strings.concatenate({"shell:", id})
		return ""
	}
	if strings.has_prefix(command_type, "lsp_") {
		id := extract_json_string(text, "session_id", "")
		defer delete(id)
		if id != "" do return strings.concatenate({"lsp:", id})
		return ""
	}
	switch command_type {
	case "launch_agent", "launch_provider_test", "stop_agent", "agent_pty_input", "agent_pty_resize", "capture_agent_pane", "get_agent_pane", "notify_agent_message", "notify_task_nudge", "notify_shell_run", "notify_title_nudge":
		id := extract_json_string(text, "agent_instance_id", "")
		defer delete(id)
		if id != "" do return strings.concatenate({"agent:", id})
	case "wake_agent", "task_status_changed_notify":
		return strings.clone("agent-control")
	}
	return ""
}

bridge_command_dispatch_queue_len_locked :: proc(class: Bridge_Command_Class) -> int {
	switch class {
	case .Lifecycle: return len(bridge_dispatch_lifecycle)
	case .Interactive: return len(bridge_dispatch_interactive)
	case .Background: return len(bridge_dispatch_background)
	case .Exclusive: return len(bridge_dispatch_exclusive)
	case .General_IO: return len(bridge_dispatch_general_io)
	case .Shell: return len(bridge_dispatch_shell)
	}
	return 0
}

bridge_command_dispatch_class_limit :: proc(class: Bridge_Command_Class) -> int {
	switch class {
	case .Lifecycle: return BRIDGE_DISPATCH_LIFECYCLE_LIMIT
	case .Interactive: return BRIDGE_DISPATCH_INTERACTIVE_LIMIT
	case .Background: return BRIDGE_DISPATCH_BACKGROUND_LIMIT
	case .Exclusive: return BRIDGE_DISPATCH_EXCLUSIVE_LIMIT
	case .General_IO: return BRIDGE_DISPATCH_GENERAL_IO_LIMIT
	case .Shell: return BRIDGE_DISPATCH_SHELL_LIMIT
	}
	return 0
}

bridge_command_dispatch_total_locked :: proc() -> int {
	return len(bridge_dispatch_lifecycle) + len(bridge_dispatch_interactive) + len(bridge_dispatch_background) + len(bridge_dispatch_exclusive) + len(bridge_dispatch_general_io) + len(bridge_dispatch_shell)
}

bridge_command_dispatch_admission_scope :: proc(class: Bridge_Command_Class, total, class_depth, owned_bytes, outbox_bytes, incoming_bytes: int, recovery: bool = false) -> string {
	normal_limit := BRIDGE_DISPATCH_TOTAL_LIMIT - BRIDGE_DISPATCH_RECOVERY_RESERVE
	owned_limit := BRIDGE_DISPATCH_OWNED_BYTES_LIMIT if recovery else BRIDGE_DISPATCH_OWNED_BYTES_LIMIT - BRIDGE_DISPATCH_RECOVERY_BYTES_RESERVE
	outbox_limit := BRIDGE_DISPATCH_OUTBOX_BYTES_LIMIT if recovery else BRIDGE_DISPATCH_OUTBOX_BYTES_LIMIT * 3 / 4
	if total >= (BRIDGE_DISPATCH_TOTAL_LIMIT if recovery else normal_limit) || owned_bytes + incoming_bytes > owned_limit || outbox_bytes > outbox_limit do return "global"
	if class_depth >= bridge_command_dispatch_class_limit(class) + (BRIDGE_DISPATCH_RECOVERY_RESERVE if recovery else 0) {
		return "background" if class == .Background else ("lifecycle" if class == .Lifecycle else ("exclusive" if class == .Exclusive else "interactive"))
	}
	return ""
}

bridge_command_dispatch_claim_index_locked :: proc(command_id: string) -> int {
	for claim, i in bridge_dispatch_claims {
		if claim.command_id == command_id do return i
	}
	return -1
}

bridge_command_dispatch_prune_claim_locked :: proc() -> bool {
	if len(bridge_dispatch_claims) < BRIDGE_DISPATCH_CLAIM_LIMIT do return true
	for claim, i in bridge_dispatch_claims {
		if claim.state != .Completed do continue
		delete(claim.command_id, runtime.default_allocator())
		delete(claim.result_json, runtime.default_allocator())
		ordered_remove(&bridge_dispatch_claims, i)
		return true
	}
	return false
}

bridge_command_dispatch_busy_json :: proc(command_id, scope: string, retry_after_ms: int = 1000) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"command_result\",\"protocol_version\":1,\"command_id\":\"")
	bridge_runtime_write_json_string(&b, command_id)
	strings.write_string(&b, "\",\"payload\":{\"status\":\"failed\",\"error_code\":\"bridge_busy\",\"retryable\":true,\"retry_after_ms\":")
	strings.write_string(&b, fmt.tprintf("%d", retry_after_ms))
	strings.write_string(&b, ",\"overload_scope\":\"")
	bridge_runtime_write_json_string(&b, scope)
	strings.write_string(&b, "\"}}")
	return strings.to_string(b)
}

bridge_command_dispatch_deadline_json :: proc(command_id: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"command_result\",\"protocol_version\":1,\"command_id\":\"")
	bridge_runtime_write_json_string(&b, command_id)
	strings.write_string(&b, "\",\"payload\":{\"status\":\"failed\",\"error_code\":\"deadline_exceeded\",\"retryable\":false}}")
	return strings.to_string(b)
}

bridge_command_dispatch_protocol_error_json :: proc(command_id, error_code: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"command_result\",\"protocol_version\":1,\"command_id\":\"")
	bridge_runtime_write_json_string(&b, command_id)
	strings.write_string(&b, "\",\"payload\":{\"status\":\"failed\",\"error_code\":\"")
	bridge_runtime_write_json_string(&b, error_code)
	strings.write_string(&b, "\",\"retryable\":false}}")
	return strings.to_string(b)
}

bridge_command_dispatch :: proc(conn: ^ws.Connection, text: string, generation: i64) -> bool {
	command_type := extract_json_string(text, "type", "")
	defer delete(command_type)
	class, asynchronous := bridge_command_dispatch_class(command_type)
	if !asynchronous {
		if bridge_command_inline_type(command_type) do return false
		protocol_error := bridge_command_dispatch_protocol_error_json("", "unknown_command")
		defer delete(protocol_error)
		_ = bridge_hub_send(conn, protocol_error)
		return true
	}
	command_id := extract_json_string(text, "command_id", "")
	if command_id == "" {
		delete(command_id)
		command_id = extract_json_string(text, "request_id", "")
	}
	defer delete(command_id)
	if command_id == "" {
		protocol_error := bridge_command_dispatch_protocol_error_json("", "missing_command_id")
		defer delete(protocol_error)
		_ = bridge_hub_send(conn, protocol_error)
		return true
	}
	if len(text) > BRIDGE_DISPATCH_COMMAND_BYTES_LIMIT {
		protocol_error := bridge_command_dispatch_protocol_error_json(command_id, "command_too_large")
		defer delete(protocol_error)
		_ = bridge_hub_send(conn, protocol_error)
		return true
	}
	ordering_key := bridge_command_ordering_key(command_type, text)
	defer delete(ordering_key)

	timeout_ms := extract_json_int(text, "timeout_ms", BRIDGE_DISPATCH_DEFAULT_TIMEOUT_MS)
	if timeout_ms <= 0 || timeout_ms > BRIDGE_DISPATCH_DEFAULT_TIMEOUT_MS do timeout_ms = BRIDGE_DISPATCH_DEFAULT_TIMEOUT_MS
	deadline := time.to_unix_nanoseconds(time.now()) + i64(time.Duration(timeout_ms) * time.Millisecond)
	owned_bytes := len(text) + len(command_id) + len(command_type)

	sync.mutex_lock(&bridge_dispatch_mu)
	claim_index := bridge_command_dispatch_claim_index_locked(command_id)
	if claim_index >= 0 {
		claim := bridge_dispatch_claims[claim_index]
		cached := strings.clone(claim.result_json, runtime.default_allocator())
		sync.mutex_unlock(&bridge_dispatch_mu)
		if cached != "" {
			defer delete(cached, runtime.default_allocator())
			_ = bridge_hub_send(conn, cached)
		} else {
			accepted := bridge_command_result_json(command_id, "accepted", "")
			defer delete(accepted)
			_ = bridge_hub_send(conn, accepted)
		}
		return true
	}

	scope := bridge_command_dispatch_admission_scope(class, bridge_command_dispatch_total_locked(), bridge_command_dispatch_queue_len_locked(class), bridge_dispatch_owned_bytes, bridge_dispatch_outbox_bytes, owned_bytes, bridge_command_is_recovery(command_type))
	if scope == "" && !bridge_command_dispatch_prune_claim_locked() do scope = "global"
	if scope != "" {
		sync.mutex_unlock(&bridge_dispatch_mu)
		busy := bridge_command_dispatch_busy_json(command_id, scope)
		defer delete(busy)
		_ = bridge_hub_send(conn, busy)
		return true
	}

	job := Bridge_Dispatch_Job{
		text = strings.clone(text, runtime.default_allocator()),
		command_id = strings.clone(command_id, runtime.default_allocator()),
		command_type = strings.clone(command_type, runtime.default_allocator()),
		ordering_key = strings.clone(ordering_key, runtime.default_allocator()),
		class = class,
		generation = generation,
		deadline_ns = deadline,
		owned_bytes = owned_bytes,
	}
	switch class {
	case .Lifecycle: append(&bridge_dispatch_lifecycle, job)
	case .Interactive: append(&bridge_dispatch_interactive, job)
	case .Background: append(&bridge_dispatch_background, job)
	case .Exclusive: append(&bridge_dispatch_exclusive, job)
	case .General_IO: append(&bridge_dispatch_general_io, job)
	case .Shell: append(&bridge_dispatch_shell, job)
	}
	append(&bridge_dispatch_claims, Bridge_Dispatch_Claim{command_id = strings.clone(command_id, runtime.default_allocator()), state = .Queued})
	bridge_dispatch_owned_bytes += owned_bytes
	sync.mutex_unlock(&bridge_dispatch_mu)

	accepted := bridge_command_result_json(command_id, "accepted", "")
	defer delete(accepted)
	_ = bridge_hub_send(conn, accepted)
	return true
}

bridge_command_dispatch_take :: proc(class: Bridge_Command_Class) -> (Bridge_Dispatch_Job, bool) {
	sync.mutex_lock(&bridge_dispatch_mu)
	defer sync.mutex_unlock(&bridge_dispatch_mu)
	job: Bridge_Dispatch_Job
	switch class {
	case .Lifecycle:
		job, ok := bridge_command_dispatch_take_queue_locked(&bridge_dispatch_lifecycle)
		if !ok do return job, false
	case .Interactive:
		job, ok := bridge_command_dispatch_take_queue_locked(&bridge_dispatch_interactive)
		if !ok do return job, false
	case .Background:
		job, ok := bridge_command_dispatch_take_queue_locked(&bridge_dispatch_background)
		if !ok do return job, false
	case .Exclusive:
		job, ok := bridge_command_dispatch_take_queue_locked(&bridge_dispatch_exclusive)
		if !ok do return job, false
	case .General_IO:
		job, ok := bridge_command_dispatch_take_queue_locked(&bridge_dispatch_general_io)
		if !ok do return job, false
	case .Shell:
		job, ok := bridge_command_dispatch_take_queue_locked(&bridge_dispatch_shell)
		if !ok do return job, false
	}
	if i := bridge_command_dispatch_claim_index_locked(job.command_id); i >= 0 do bridge_dispatch_claims[i].state = .Running
	return job, true
}

bridge_command_dispatch_take_queue_locked :: proc(queue: ^[dynamic]Bridge_Dispatch_Job) -> (Bridge_Dispatch_Job, bool) {
	for job, i in queue {
		blocked := false
		if job.ordering_key != "" {
			for key in bridge_dispatch_active_keys {
				if key == job.ordering_key { blocked = true; break }
			}
		}
		if blocked do continue
		selected := job
		ordered_remove(queue, i)
		if selected.ordering_key != "" do append(&bridge_dispatch_active_keys, strings.clone(selected.ordering_key, runtime.default_allocator()))
		return selected, true
	}
	return Bridge_Dispatch_Job{}, false
}

bridge_command_dispatch_finish :: proc(worker: ^Bridge_Dispatch_Worker, job: ^Bridge_Dispatch_Job) {
	sync.mutex_lock(&bridge_dispatch_mu)
	if job.ordering_key != "" {
		for key, i in bridge_dispatch_active_keys {
			if key != job.ordering_key do continue
			delete(key, runtime.default_allocator())
			ordered_remove(&bridge_dispatch_active_keys, i)
			break
		}
	}
	if i := bridge_command_dispatch_claim_index_locked(job.command_id); i >= 0 {
		bridge_dispatch_claims[i].state = .Completed
		delete(bridge_dispatch_claims[i].result_json, runtime.default_allocator())
		bridge_dispatch_claims[i].result_json = strings.clone(worker.last_result, runtime.default_allocator())
	}
	bridge_dispatch_owned_bytes -= job.owned_bytes
	delete(worker.current_command_id, runtime.default_allocator())
	worker.current_command_id = ""
	delete(worker.last_result, runtime.default_allocator())
	worker.last_result = ""
	worker.output_failed = false
	worker.current_generation = 0
	sync.mutex_unlock(&bridge_dispatch_mu)
	delete(job.text, runtime.default_allocator())
	delete(job.command_id, runtime.default_allocator())
	delete(job.command_type, runtime.default_allocator())
	delete(job.ordering_key, runtime.default_allocator())
}

bridge_command_dispatch_worker :: proc(data: rawptr) {
	worker := (^Bridge_Dispatch_Worker)(data)
	for {
		job, ok := bridge_command_dispatch_take(worker.class)
		if !ok {
			time.sleep(5 * time.Millisecond)
			continue
		}
		sync.mutex_lock(&bridge_dispatch_mu)
		worker.current_generation = job.generation
		worker.current_command_id = strings.clone(job.command_id, runtime.default_allocator())
		sync.mutex_unlock(&bridge_dispatch_mu)
		if time.to_unix_nanoseconds(time.now()) >= job.deadline_ns {
			result := bridge_command_dispatch_deadline_json(job.command_id)
			_ = bridge_command_worker_capture_send(&worker.sink_conn, result)
			delete(result)
		} else {
			bridge_hub_handle_command(&worker.sink_conn, job.text)
		}
		bridge_command_dispatch_finish(worker, &job)
	}
}

// bridge_hub_send calls this before touching the real socket. Worker handlers get
// a private sink connection, never the live Hub connection; results cross threads
// only as owned JSON in this bounded outbox.
bridge_command_worker_capture_send :: proc(conn: ^ws.Connection, text: string) -> bool {
	if conn == nil do return false
	sync.mutex_lock(&bridge_dispatch_mu)
	defer sync.mutex_unlock(&bridge_dispatch_mu)
	for &worker in bridge_dispatch_workers {
		if rawptr(conn) != rawptr(&worker.sink_conn) do continue
		if worker.output_failed do return false
		captured := text
		fallback := ""
		if len(text) > BRIDGE_DISPATCH_COMMAND_BYTES_LIMIT || bridge_dispatch_outbox_bytes + len(text) > BRIDGE_DISPATCH_OUTBOX_BYTES_LIMIT {
			// Reserve a bounded terminal answer even when a normal result cannot fit.
			// At most one such small over-cap frame exists per worker, so the byte
			// budget remains bounded and the Hub sees a failure instead of timing out.
			fallback = bridge_command_dispatch_protocol_error_json(worker.current_command_id, "response_backpressure")
			captured = fallback
			worker.output_failed = true
		}
		defer delete(fallback)
		append(&bridge_dispatch_outputs, Bridge_Dispatch_Output{text = strings.clone(captured, runtime.default_allocator()), generation = worker.current_generation})
		bridge_dispatch_outbox_bytes += len(captured)
		delete(worker.last_result, runtime.default_allocator())
		worker.last_result = strings.clone(captured, runtime.default_allocator())
		return true
	}
	return false
}

bridge_command_dispatch_drain :: proc(conn: ^ws.Connection, generation: i64) {
	for {
		output: Bridge_Dispatch_Output
		have := false
		sync.mutex_lock(&bridge_dispatch_mu)
		if len(bridge_dispatch_outputs) > 0 {
			output = bridge_dispatch_outputs[0]
			ordered_remove(&bridge_dispatch_outputs, 0)
			bridge_dispatch_outbox_bytes -= len(output.text)
			have = true
		}
		sync.mutex_unlock(&bridge_dispatch_mu)
		if !have do return
		if output.generation == generation {
			if !bridge_hub_send(conn, output.text) {
				delete(output.text, runtime.default_allocator())
				conn.connected = false
				return
			}
		}
		delete(output.text, runtime.default_allocator())
	}
}
