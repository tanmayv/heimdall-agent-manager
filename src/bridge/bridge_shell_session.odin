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
import "core:strings"
import "core:sync"
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

bridge_shell_session_register :: proc(m: ^Bridge_Shell_Session_Map, s: Bridge_Shell_Session) {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	if m.sessions == nil do m.sessions = make(map[string]Bridge_Shell_Session, allocator = runtime.default_allocator())
	m.sessions[s.session_id] = s
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

// bridge_shell_session_reconcile loads persisted specs from disk, then for
// each spec checks whether the daemon still has it in daemon_list:
//   - found alive → re-register as Running
//   - not found   → mark Failed (died while bridge was offline), delete spec
// Sessions in daemon_list that have no matching spec are not ours; ignore them.
bridge_shell_session_reconcile :: proc(m: ^Bridge_Shell_Session_Map, daemon_list: []Pty_Host_Shell_Info, data_dir: string) {
	specs := bridge_shell_session_load_specs(data_dir)
	if specs == nil do return
	defer delete(specs)

	for s in specs {
		found := false
		match_shell_id := s.shell_id if s.shell_id != "" else s.session_id
		for d in daemon_list {
			if d.shell_id == match_shell_id {
				found = true
				updated := s
				updated.status = .Running
				updated.pid = int(d.pid)
				bridge_shell_session_register(m, updated)
				bridge_shell_session_save_spec(data_dir, updated)
				break
			}
		}
		if !found {
			updated := s
			updated.status = .Failed
			updated.exit_code_set = true
			bridge_shell_session_register(m, updated)
			bridge_shell_session_delete_spec(data_dir, s.session_id)
		}
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
