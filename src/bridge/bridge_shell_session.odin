package main

// REQ-SH-CONTRACT §3: bridge-side session management.
//
// Bridge_Shell_Session_Map owns the live session registry, mints session IDs,
// persists spawn specs to disk for crash-recovery, and reconciles with the
// daemon on reconnect. shell_cmd.odin uses this as the backing store for
// shell-cmd exec/read (kind=Command); T4 WS handlers will add Agent/Interactive/
// Server kinds on top.

import json "core:encoding/json"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:sys/posix"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// ---- session kind / status enums ----------------------------------------

Bridge_Shell_Session_Kind :: enum {
	Agent,
	Interactive,
	Server,
	Command,
}

Bridge_Shell_Session_Status :: enum {
	Starting,
	Running,
	Exited,
	Killed,
	Failed,
}

// ---- session struct ------------------------------------------------------

// Bridge_Shell_Session is the durable record for one bridge-managed shell
// session. All string fields are owned (cloned) so they outlive the request
// that created them.
//
// started_unix_ms / finished_unix_ms are implementation-only timing fields
// used by the shell-cmd exec response (execution_time_ms). They are NOT
// persisted in the spec JSON; they default to 0 after a crash-recovery load.
Bridge_Shell_Session :: struct {
	session_id:        string, // "shl_<unixnano>_<seq>" or agent_instance_id for kind=Agent
	kind:              Bridge_Shell_Session_Kind,
	label:             string,
	cmd:               string,
	cwd:               string,
	bridge_id:         string,
	project_id:        string,
	chain_id:          string,
	agent_instance_id: string,
	owner_user_id:     string,
	pid:               int,
	server_port:       int, // 0 unless kind=Server
	status:            Bridge_Shell_Session_Status,
	exit_code:         int,
	exit_code_set:     bool,
	started_at:        string, // RFC3339 UTC
	finished_at:       string, // RFC3339 UTC; "" while running
	shell_id:          string, // daemon shell_id (== session_id for non-agent)
	// implementation-only (not in spec JSON):
	started_unix_ms:   i64,
	finished_unix_ms:  i64,
}

// ---- session map ---------------------------------------------------------

Bridge_Shell_Session_Map :: struct {
	mu:       sync.Mutex,
	sessions: map[string]Bridge_Shell_Session, // keyed by session_id
}

// ---- ID generator --------------------------------------------------------

@(private = "file")
_bridge_shell_session_seq:    i64
@(private = "file")
_bridge_shell_session_seq_mu: sync.Mutex

// bridge_shell_session_next_id mints a unique "shl_<unixnano>_<seq>" session
// id. The seq is a monotonically increasing counter guarded by a mutex,
// matching the pattern of the old bridge_shell_next_exec_id in shell_cmd.odin.
bridge_shell_session_next_id :: proc() -> string {
	sync.mutex_lock(&_bridge_shell_session_seq_mu)
	_bridge_shell_session_seq += 1
	seq := _bridge_shell_session_seq
	sync.mutex_unlock(&_bridge_shell_session_seq_mu)
	return strings.clone(fmt.tprintf("shl_%x_%d", time.to_unix_nanoseconds(time.now()), seq))
}

// ---- CRUD ----------------------------------------------------------------

// bridge_shell_session_register inserts (or replaces) a session, taking
// ownership of every string field in s.
//
// Replacing an entry deliberately does NOT free the strings the previous entry
// owned. bridge_shell_session_get returns the struct BY VALUE, so every caller
// walks away with borrowed pointers into the stored allocation, and the map
// mutex is released the moment it returns. Freeing the superseded strings here
// would therefore race with any concurrent holder — e.g. the shell signal/kill
// handlers in hub_runtime_client.odin read sess.shell_id across a
// bridge_pty_host_ensure_daemon call that can block for up to 5s, while
// reconcile re-registers the same session from a background thread with
// freshly-cloned spec strings. That is a use-after-free with a seconds-wide
// window.
//
// The cost is a bounded leak: one string set per session per hub WS reconnect
// on the reconcile survivor path. That is the deliberate lesser evil until
// session string ownership is redesigned (get would have to deep-clone, or
// entries be refcounted) — a change touching every call site, out of scope here.
bridge_shell_session_register :: proc(m: ^Bridge_Shell_Session_Map, s: Bridge_Shell_Session) {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	if m.sessions == nil do m.sessions = make(map[string]Bridge_Shell_Session, allocator = runtime.default_allocator())
	m.sessions[s.session_id] = s
}

// bridge_shell_session_free_fields frees every owned string of a session that
// was never handed to the map — specifically a spec loaded by
// bridge_shell_session_load_specs and then skipped by reconcile. Safe only for
// that case: nothing else can hold pointers into those allocations. Never call
// it on a session that is (or ever was) stored in the map; see
// bridge_shell_session_register for why.
bridge_shell_session_free_fields :: proc(s: Bridge_Shell_Session) {
	free_owned :: proc(str: string) {
		if str != "" do delete(str)
	}
	free_owned(s.session_id)
	free_owned(s.label)
	free_owned(s.cmd)
	free_owned(s.cwd)
	free_owned(s.bridge_id)
	free_owned(s.project_id)
	free_owned(s.chain_id)
	free_owned(s.agent_instance_id)
	free_owned(s.owner_user_id)
	free_owned(s.started_at)
	free_owned(s.finished_at)
	free_owned(s.shell_id)
}

bridge_shell_session_get :: proc(m: ^Bridge_Shell_Session_Map, session_id: string) -> (Bridge_Shell_Session, bool) {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	if s, ok := m.sessions[session_id]; ok do return s, true
	return {}, false
}

// bridge_shell_session_get_by_shell_id looks up a session whose shell_id field
// matches the given id. Falls back to session_id equality for kind=Command
// sessions (where shell_id == session_id). Returns the first match.
bridge_shell_session_get_by_shell_id :: proc(m: ^Bridge_Shell_Session_Map, shell_id: string) -> (Bridge_Shell_Session, bool) {
	if shell_id == "" do return {}, false
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	for _, s in m.sessions {
		if s.shell_id == shell_id do return s, true
		if s.shell_id == "" && s.session_id == shell_id do return s, true
	}
	return {}, false
}

// bridge_shell_session_update_status updates the status, exit_code, and
// exit_code_set of an existing session under the map lock. Use
// bridge_shell_session_finish for the async-worker path (also sets timing).
bridge_shell_session_update_status :: proc(m: ^Bridge_Shell_Session_Map, session_id: string, status: Bridge_Shell_Session_Status, exit_code: int, exit_code_set: bool) {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	if s, ok := &m.sessions[session_id]; ok {
		s.status = status
		s.exit_code = exit_code
		s.exit_code_set = exit_code_set
	}
}

// bridge_shell_session_finish is the async-worker variant: updates status,
// exit_code, and the millisecond-precision finish timestamp.
bridge_shell_session_finish :: proc(m: ^Bridge_Shell_Session_Map, session_id: string, status: Bridge_Shell_Session_Status, exit_code: int, finished_unix_ms: i64) {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	if s, ok := &m.sessions[session_id]; ok {
		s.status = status
		s.exit_code = exit_code
		s.exit_code_set = true
		s.finished_unix_ms = finished_unix_ms
	}
}

bridge_shell_session_list :: proc(m: ^Bridge_Shell_Session_Map) -> []Bridge_Shell_Session {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	result := make([]Bridge_Shell_Session, len(m.sessions))
	i := 0
	for _, s in m.sessions {
		result[i] = s
		i += 1
	}
	return result
}

// bridge_shell_session_map_reset clears all sessions (for tests).
bridge_shell_session_map_reset :: proc(m: ^Bridge_Shell_Session_Map) {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	clear(&m.sessions)
}

// ---- durable JSON spec store --------------------------------------------

bridge_shell_session_spec_dir :: proc(data_dir: string) -> string {
	return strings.concatenate({strings.trim_right(data_dir, "/"), "/shell_sessions"})
}

// bridge_shell_session_save_spec writes the session spec to disk atomically
// (write to a .tmp file then rename). Callers pass the expanded data_dir.
bridge_shell_session_save_spec :: proc(data_dir: string, s: Bridge_Shell_Session) {
	dir := bridge_shell_session_spec_dir(data_dir)
	_ = os.make_directory_all(dir)

	path := strings.concatenate({dir, "/", s.session_id, ".json"})
	defer delete(path)
	tmp := strings.concatenate({path, ".tmp"})
	defer delete(tmp)

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "{\"session_id\":\"")
	bridge_local_write_json_string(&b, s.session_id)
	strings.write_string(&b, "\",\"kind\":\"")
	bridge_local_write_json_string(&b, bridge_shell_session_kind_str(s.kind))
	strings.write_string(&b, "\",\"label\":\"")
	bridge_local_write_json_string(&b, s.label)
	strings.write_string(&b, "\",\"cmd\":\"")
	bridge_local_write_json_string(&b, s.cmd)
	strings.write_string(&b, "\",\"cwd\":\"")
	bridge_local_write_json_string(&b, s.cwd)
	strings.write_string(&b, "\",\"bridge_id\":\"")
	bridge_local_write_json_string(&b, s.bridge_id)
	strings.write_string(&b, "\",\"project_id\":\"")
	bridge_local_write_json_string(&b, s.project_id)
	strings.write_string(&b, "\",\"chain_id\":\"")
	bridge_local_write_json_string(&b, s.chain_id)
	strings.write_string(&b, "\",\"agent_instance_id\":\"")
	bridge_local_write_json_string(&b, s.agent_instance_id)
	strings.write_string(&b, "\",\"owner_user_id\":\"")
	bridge_local_write_json_string(&b, s.owner_user_id)
	strings.write_string(&b, "\",\"pid\":")
	strings.write_string(&b, bridge_agent_itoa(s.pid))
	strings.write_string(&b, ",\"server_port\":")
	strings.write_string(&b, bridge_agent_itoa(s.server_port))
	strings.write_string(&b, ",\"status\":\"")
	bridge_local_write_json_string(&b, bridge_shell_session_status_str(s.status))
	strings.write_string(&b, "\",\"exit_code\":")
	strings.write_string(&b, bridge_agent_itoa(s.exit_code))
	strings.write_string(&b, ",\"exit_code_set\":")
	strings.write_string(&b, s.exit_code_set ? "true" : "false")
	strings.write_string(&b, ",\"started_at\":\"")
	bridge_local_write_json_string(&b, s.started_at)
	strings.write_string(&b, "\",\"finished_at\":\"")
	bridge_local_write_json_string(&b, s.finished_at)
	strings.write_string(&b, "\",\"shell_id\":\"")
	bridge_local_write_json_string(&b, s.shell_id)
	strings.write_byte(&b, '"')
	strings.write_byte(&b, '}')

	json_str := strings.to_string(b)
	if os.write_entire_file(tmp, transmute([]byte)json_str) == nil {
		_ = os.rename(tmp, path)
	}
}

// bridge_shell_session_load_specs reads all *.json spec files from the
// shell_sessions directory. Corrupt or unreadable files are logged and skipped.
// The caller owns the returned slice and each element's string fields.
bridge_shell_session_load_specs :: proc(data_dir: string) -> []Bridge_Shell_Session {
	dir := bridge_shell_session_spec_dir(data_dir)
	infos, rerr := os.read_directory_by_path(dir, -1, context.allocator)
	if rerr != nil do return nil
	defer os.file_info_slice_delete(infos, context.allocator)

	result := make([dynamic]Bridge_Shell_Session, allocator = runtime.default_allocator())
	for info in infos {
		if !strings.has_suffix(info.name, ".json") || strings.has_suffix(info.name, ".tmp.json") do continue
		// skip .tmp files (from an interrupted write)
		if strings.has_suffix(info.name, ".tmp") do continue

		path := strings.concatenate({dir, "/", info.name})
		raw, ferr := os.read_entire_file(path, context.allocator)
		delete(path)
		if ferr != nil do continue
		defer delete(raw)

		parsed, jerr := json.parse(raw)
		if jerr != nil {
			fmt.eprintln("bridge shell session: corrupt spec, skipping:", info.name)
			continue
		}
		defer json.destroy_value(parsed)

		obj, is_obj := parsed.(json.Object)
		if !is_obj do continue

		s: Bridge_Shell_Session
		if v, ok := obj["session_id"].(json.String); ok do s.session_id = strings.clone(string(v))
		if v, ok := obj["kind"].(json.String); ok do s.kind = bridge_shell_session_kind_from_str(string(v))
		if v, ok := obj["label"].(json.String); ok do s.label = strings.clone(string(v))
		if v, ok := obj["cmd"].(json.String); ok do s.cmd = strings.clone(string(v))
		if v, ok := obj["cwd"].(json.String); ok do s.cwd = strings.clone(string(v))
		if v, ok := obj["bridge_id"].(json.String); ok do s.bridge_id = strings.clone(string(v))
		if v, ok := obj["project_id"].(json.String); ok do s.project_id = strings.clone(string(v))
		if v, ok := obj["chain_id"].(json.String); ok do s.chain_id = strings.clone(string(v))
		if v, ok := obj["agent_instance_id"].(json.String); ok do s.agent_instance_id = strings.clone(string(v))
		if v, ok := obj["owner_user_id"].(json.String); ok do s.owner_user_id = strings.clone(string(v))
		if v, ok := obj["pid"].(json.Float); ok do s.pid = int(v)
		if v, ok := obj["server_port"].(json.Float); ok do s.server_port = int(v)
		if v, ok := obj["status"].(json.String); ok do s.status = bridge_shell_session_status_from_str(string(v))
		if v, ok := obj["exit_code"].(json.Float); ok do s.exit_code = int(v)
		if v, ok := obj["exit_code_set"].(json.Boolean); ok do s.exit_code_set = bool(v)
		if v, ok := obj["started_at"].(json.String); ok do s.started_at = strings.clone(string(v))
		if v, ok := obj["finished_at"].(json.String); ok do s.finished_at = strings.clone(string(v))
		if v, ok := obj["shell_id"].(json.String); ok do s.shell_id = strings.clone(string(v))

		if s.session_id != "" do append(&result, s)
	}
	return result[:]
}

bridge_shell_session_delete_spec :: proc(data_dir: string, session_id: string) {
	dir := bridge_shell_session_spec_dir(data_dir)
	path := strings.concatenate({dir, "/", session_id, ".json"})
	defer delete(path)
	_ = os.remove(path)
}

// ---- reconcile on reconnect ----------------------------------------------

@(private = "file")
_bridge_shell_reconcile_running: bool
@(private = "file")
_bridge_shell_reconcile_mu: sync.Mutex

// bridge_shell_session_reconcile_now resolves the data dir and the live pty-host
// agent list, then runs a reconcile pass. Intended to be launched on a background
// thread from the hub-runtime-ready path (REQ-RECON-1).
//
// Single-flight: hub WS reconnects can arrive back-to-back, and two overlapping
// reconcile passes could each act on the same orphaned session (double kill,
// duplicate shell_exited). A running pass therefore makes any concurrent call a
// no-op; the next reconnect picks up whatever this pass did not.
//
// If the pty-host is unreachable we return without touching anything: without a
// daemon list we cannot distinguish a live session from a dead one, and guessing
// would mark healthy sessions dead.
bridge_shell_session_reconcile_now :: proc() {
	sync.mutex_lock(&_bridge_shell_reconcile_mu)
	if _bridge_shell_reconcile_running {
		sync.mutex_unlock(&_bridge_shell_reconcile_mu)
		return
	}
	_bridge_shell_reconcile_running = true
	sync.mutex_unlock(&_bridge_shell_reconcile_mu)
	defer {
		sync.mutex_lock(&_bridge_shell_reconcile_mu)
		_bridge_shell_reconcile_running = false
		sync.mutex_unlock(&_bridge_shell_reconcile_mu)
	}

	// bridge_expand_home allocates only when the path starts with "~/", so free
	// it only when it actually handed back a different allocation. This runs on
	// every reconnect, outside any arena.
	raw_dir := strings.trim_space(bridge_config.data_dir)
	if raw_dir == "" do raw_dir = "~/.local/share/heimdall"
	data_dir := bridge_expand_home(raw_dir)
	defer if raw_data(data_dir) != raw_data(raw_dir) do delete(data_dir)

	socket, sock_ok := bridge_pty_host_ensure_daemon()
	if !sock_ok do return
	reply, list_ok := bridge_pty_host_list(socket)
	if !list_ok do return
	defer pty_host_reply_delete(reply)

	bridge_shell_session_reconcile(&bridge_shell_session_map, reply.agents, data_dir)
}

// Bridge_Shell_Orphan_Kill_Ctx carries state for the orphan-kill background
// thread. It holds the session identity (not just the pid) because the escalation
// step has to re-verify the pid before SIGKILL — see the worker below. cmd and
// started_at are owned clones, freed by the worker.
Bridge_Shell_Orphan_Kill_Ctx :: struct {
	pid:        i32,
	cmd:        string,
	started_at: string,
}

// bridge_shell_session_orphan_kill_worker sends SIGTERM to a directly-tracked
// PID, waits 5s, then SIGKILLs if the pid is STILL OUR PROCESS. Used only for
// processes the pty-host no longer tracks (bridge_shell_kill_worker cannot kill
// them because it routes through the pty-host daemon, which has no handle on
// the session).
//
// The identity check is re-run before the SIGKILL rather than a bare liveness
// probe: the 5s grace period is exactly the window in which our SIGTERMed
// process exits and the OS is free to hand its pid to something else. A plain
// kill(pid, 0) would then report "alive" for an unrelated process and we would
// SIGKILL it — reintroducing, one step later, the PID-reuse hazard the guard
// before the SIGTERM exists to prevent. If the re-check fails for any reason we
// skip the SIGKILL: an orphan that outlives us is acceptable, a wrong kill is not.
bridge_shell_session_orphan_kill_worker :: proc(data: rawptr) {
	ctx := (^Bridge_Shell_Orphan_Kill_Ctx)(data)
	defer {
		delete(ctx.cmd)
		delete(ctx.started_at)
		free(ctx)
		free_all(context.temp_allocator)
	}

	_ = posix.kill(posix.pid_t(ctx.pid), .SIGTERM)
	time.sleep(5 * time.Second)
	// Re-verify identity, not just liveness, before escalating.
	if bridge_shell_session_pid_is_plausible(int(ctx.pid), ctx.cmd, ctx.started_at) {
		_ = posix.kill(posix.pid_t(ctx.pid), .SIGKILL)
	}
}

// bridge_shell_session_parse_lstart parses the C-locale lstart string produced
// by `LC_ALL=C ps -o lstart=`.  Format: "Www Mmm DD HH:MM:SS YYYY" (24 chars).
// Returns (unix_sec, true) on success, (0, false) on any parse failure.
bridge_shell_session_parse_lstart :: proc(s: string) -> (i64, bool) {
	if len(s) < 24 do return 0, false
	month_names := [12]string{"Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"}
	month_str := strings.trim_space(s[4:7])
	month := 0
	for m, i in month_names {
		if m == month_str { month = i + 1; break }
	}
	if month == 0 do return 0, false
	day, day_ok   := strconv.parse_int(strings.trim_space(s[8:10]))
	hour, hr_ok   := strconv.parse_int(s[11:13])
	min_, mn_ok   := strconv.parse_int(s[14:16])
	sec, sc_ok    := strconv.parse_int(s[17:19])
	year, yr_ok   := strconv.parse_int(s[20:24])
	if !day_ok || !hr_ok || !mn_ok || !sc_ok || !yr_ok do return 0, false
	t, ok := time.datetime_to_time(year, time.Month(month), day, hour, min_, sec, 0)
	if !ok do return 0, false
	return time.to_unix_seconds(t), true
}

// bridge_shell_session_pid_is_plausible checks whether pid is still alive and
// is plausibly the same process that produced the given session.
//
// Portably uses `LC_ALL=C ps -p <pid> -o lstart=,command=` — both keywords
// exist on procps (Linux) and BSD ps (macOS), giving one code path with no
// /proc dependency.  BOTH conditions must hold; there is no fallback:
//   (a) The base executable name (after last '/', before first space) extracted
//       from ps `command=` matches the same extraction from the spec cmd.
//       Exact match, not prefix — we have full names from `command=` so there
//       is no reason to accept a prefix match.
//   (b) The ps `lstart=` wall-clock start time matches the spec started_at
//       (RFC3339) within 5 s.  5 s absorbs the gap between process launch and
//       spec-write; it is far too small to be fooled by PID reuse (a recycled
//       PID from a dead process has a different start time by definition).
//
// If ps fails, the output is unparseable, started_at is absent, or either
// check does not match → returns false (skip the kill, still mark the session
// dead and emit shell_exited).  Killing the wrong process is worse than leaving
// a stale spec.
bridge_shell_session_pid_is_plausible :: proc(pid: int, cmd: string, started_at: string) -> bool {
	if pid <= 0 || cmd == "" || started_at == "" do return false

	// Force C locale so lstart format is predictable on both Linux and macOS.
	ps_cmd := fmt.tprintf("LC_ALL=C ps -p %d -o lstart=,command= 2>/dev/null", pid)
	c_ps_cmd := strings.clone_to_cstring(ps_cmd)
	defer delete(c_ps_cmd)
	f := posix.popen(c_ps_cmd, "r")
	if f == nil do return false
	defer posix.pclose(f)

	buf: [512]byte
	n := posix.fread(&buf, 1, size_of(buf) - 1, f)
	if n == 0 do return false
	output := strings.trim_space(string(buf[:n]))
	if len(output) < 25 do return false  // at minimum lstart (24) + space + 1 char

	// lstart is fixed 24 chars in C locale ("Www Mmm DD HH:MM:SS YYYY").
	lstart_str := output[:24]
	ps_command  := strings.trim_space(output[24:])

	// (a) Base executable name match.
	// Extract base from ps command: strip path prefix of first word.
	ps_exe := ps_command
	if i := strings.index_byte(ps_exe, ' '); i >= 0 do ps_exe = ps_exe[:i]
	if i := strings.last_index_byte(ps_exe, '/'); i >= 0 do ps_exe = ps_exe[i+1:]
	// Extract base from spec cmd.
	spec_exe := cmd
	if i := strings.index_byte(spec_exe, ' '); i >= 0 do spec_exe = spec_exe[:i]
	if i := strings.last_index_byte(spec_exe, '/'); i >= 0 do spec_exe = spec_exe[i+1:]
	if ps_exe != spec_exe do return false

	// (b) Start-time check: lstart vs started_at within 5 s.
	lstart_sec, lstart_ok := bridge_shell_session_parse_lstart(lstart_str)
	if !lstart_ok do return false
	started_time, consumed := time.rfc3339_to_time_utc(started_at)
	if consumed == 0 do return false
	started_sec := time.to_unix_seconds(started_time)
	diff := lstart_sec - started_sec
	if diff < 0 do diff = -diff
	return diff <= 5
}

// bridge_shell_session_reconcile loads persisted specs from disk, then for
// each spec checks whether the daemon still tracks it in daemon_agents:
//
//   - found AND alive   → re-register as Running (REQ-RECON-1)
//   - not found (or found-dead): idempotency guard skips if already terminal;
//       if the OS process is still alive and plausibly ours, kill it
//       asynchronously and report status "killed" (REQ-RECON-3);
//       otherwise report status "failed" (REQ-RECON-2).
//     In both cases emit a shell_exited event so the hub DB clears.
//
// All four session kinds (Agent/Interactive/Server/Command) are handled
// identically — the daemon key is always shell_id == Pty_Host_Agent_Info.instance_id
// (REQ-RECON-4).
//
// Idempotency: sessions already in a terminal state (Failed/Exited/Killed) in
// the in-memory map are skipped so re-connections don't double-process them.
bridge_shell_session_reconcile :: proc(m: ^Bridge_Shell_Session_Map, daemon_agents: []Pty_Host_Agent_Info, data_dir: string) {
	specs := bridge_shell_session_load_specs(data_dir)
	if specs == nil do return
	defer delete(specs)

	for s in specs {
		// Each spec's strings are freshly cloned by load_specs. Registering a
		// session hands them to the map; any spec we skip owns strings nothing
		// else will ever free, and reconcile re-reads the same on-disk specs on
		// every reconnect — so a skipped spec would otherwise leak its full
		// string set, forever, on a non-arena background thread.
		transferred := false
		defer if !transferred do bridge_shell_session_free_fields(s)

		// daemon key: shell_id when set, else session_id (kind=Command parity)
		match_id := s.shell_id if s.shell_id != "" else s.session_id

		found_alive := false
		for d in daemon_agents {
			if d.instance_id == match_id {
				if d.alive {
					found_alive = true
					updated      := s
					updated.status = .Running
					updated.pid    = int(d.pid)
					bridge_shell_session_register(m, updated)
					transferred = true
					bridge_shell_session_save_spec(data_dir, updated)
				}
				// found-dead: treat same as not-found (session exited in daemon)
				break
			}
		}
		if found_alive do continue

		// Idempotency: skip sessions already in a terminal state.
		if existing, has := bridge_shell_session_get(m, s.session_id); has {
			switch existing.status {
			case .Failed, .Exited, .Killed:
				continue
			case .Running, .Starting:
				// fall through to reconcile
			}
		}

		// REQ-RECON-3: kill the OS process if still alive and verifiably ours.
		status_str := "failed"
		final_status := Bridge_Shell_Session_Status.Failed
		if s.pid > 0 && bridge_shell_session_pid_is_plausible(s.pid, s.cmd, s.started_at) {
			status_str   = "killed"
			final_status = .Killed
			kctx            := new(Bridge_Shell_Orphan_Kill_Ctx)
			kctx.pid         = i32(s.pid)
			kctx.cmd         = strings.clone(s.cmd)
			kctx.started_at  = strings.clone(s.started_at)
			thread.run_with_data(rawptr(kctx), bridge_shell_session_orphan_kill_worker)
		}

		// REQ-RECON-2: mark dead in the local map, remove spec, notify hub.
		updated              := s
		updated.status        = final_status
		updated.exit_code_set = true
		updated.exit_code     = 1
		bridge_shell_session_register(m, updated)
		transferred = true
		bridge_shell_session_delete_spec(data_dir, s.session_id)
		event := bridge_shell_exited_event_json(s.session_id, 1, true, status_str)
		bridge_shell_exited_enqueue(event)
		delete(event)
	}
}

// ---- string helpers ------------------------------------------------------

bridge_shell_session_kind_str :: proc(k: Bridge_Shell_Session_Kind) -> string {
	switch k {
	case .Agent:       return "agent"
	case .Interactive: return "interactive"
	case .Server:      return "server"
	case .Command:     return "command"
	}
	return "command"
}

bridge_shell_session_kind_from_str :: proc(s: string) -> Bridge_Shell_Session_Kind {
	switch s {
	case "agent":       return .Agent
	case "interactive": return .Interactive
	case "server":      return .Server
	}
	return .Command
}

bridge_shell_session_status_str :: proc(s: Bridge_Shell_Session_Status) -> string {
	switch s {
	case .Starting: return "starting"
	case .Running:  return "running"
	case .Exited:   return "exited"
	case .Killed:   return "killed"
	case .Failed:   return "failed"
	}
	return "failed"
}

bridge_shell_session_status_from_str :: proc(s: string) -> Bridge_Shell_Session_Status {
	switch s {
	case "starting": return .Starting
	case "running":  return .Running
	case "exited":   return .Exited
	case "killed":   return .Killed
	}
	return .Failed
}

// bridge_shell_session_exec_status_str maps the internal session status to the
// "running" | "completed" | "failed" vocabulary the shell-cmd exec/read API
// exposes (backward-compatible with the old Bridge_Shell_Job.status strings).
bridge_shell_session_exec_status_str :: proc(s: ^Bridge_Shell_Session) -> string {
	switch s.status {
	case .Starting, .Running: return "running"
	case .Exited:             return "completed"
	case .Killed, .Failed:    return "failed"
	}
	return "failed"
}
