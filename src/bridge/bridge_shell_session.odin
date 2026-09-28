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

// The bridge's mirror of domain.Shell_Session_Kind (src/hub/domain/shell_session.odin)
// — the same three kinds, one lifecycle, and the same wire spellings. REQ-SHELL-1
// renamed Command->Run and Interactive->Shell and DELETED Agent outright; both
// sides were changed together and neither accepts the old spellings, since there
// is no back-compat requirement and a dual-accept parser would just keep the dead
// vocabulary alive.
Bridge_Shell_Session_Kind :: enum {
	Run,
	Shell,
	Server,
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
	session_id:        string, // hub-minted "sh_<...>", or bridge-minted "shl_<unixnano>_<seq>"
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
	server_port:       int, // 0 unless a port was declared at start (any kind — XM-8)
	status:            Bridge_Shell_Session_Status,
	exit_code:         int,
	exit_code_set:     bool,
	// run_seq — REQ-SHELL-4. The HUB-assigned run number this session is currently
	// on; the bridge echoes it back on every exit it reports so the hub can tell an
	// exit for the CURRENT run from one left over in the durable outbox from a
	// previous run of the same session_id. 0 is the first run, which is also what a
	// spec written before this field parses as.
	run_seq:           int,
	started_at:        string, // RFC3339 UTC
	finished_at:       string, // RFC3339 UTC; "" while running
	shell_id:          string, // daemon shell_id (== session_id for every kind since REQ-SHELL-1)
	// background — kind=run only, ONE-WAY, mirrors domain.Shell_Session.background.
	// REQ-SHELL-2 deleted the implicit 15s auto-background rule, so this is set by
	// an explicit --bg start or by a runtime conversion, never inferred from how
	// long the run has taken. Only a background run notifies on completion.
	background:        bool,
	// pty_host — HOW this session was spawned, which is what reconcile must branch
	// on. A session started through the hub path is spawned by the pty-host daemon
	// and therefore APPEARS IN ITS ROSTER; a session started by the legacy
	// shell-cmd path is a direct os.process_start child of the bridge and NEVER
	// appears there, however alive it is.
	//
	// This is deliberately not derived from `kind`. kind=run arrives by BOTH
	// mechanisms today (the hub create path, and shell-cmd exec which REQ-SHELL-7
	// retires later), so kind cannot answer "should the daemon roster know about
	// this?" — and reconcile asking the roster about a process that can never be
	// in it is exactly the bug that killed healthy runs.
	pty_host:          bool,
	// pty_host_provenance_known distinguishes "pty_host is false" from "nobody said".
	// A spec written BEFORE REQ-SHELL-2 has no pty_host key at all, and it may
	// describe a genuinely pty-host-spawned session; loading that as a plain false
	// would send it down the direct-child path and NEVER consult the roster that
	// actually tracks it. Not persisted — a spec this code writes always states the
	// flag, so anything loaded without one is legacy by definition.
	pty_host_provenance_known: bool,
	// implementation-only (not in spec JSON):
	started_unix_ms:   i64,
	finished_unix_ms:  i64,
}

// ---- session map ---------------------------------------------------------

// Bridge_Shell_Session_Map owns every string of every entry it holds; see the
// OWNERSHIP RULE on the CRUD section below for what that means for readers.
//
// allocator is the ONE allocator every entry's strings are allocated from and
// freed through, and it is carried on the map rather than taken from
// context.allocator for the reason lsp_session.odin's lsp_heap already states:
// this state crosses threads. A session is registered on the WS command thread,
// re-registered by reconcile on a background thread, and freed by whichever
// thread supersedes or removes the key — while context.allocator differs per
// thread (it is a per-test tracking allocator under `odin test`), so letting it
// decide means freeing through a different allocator than allocated from.
//
// A zero value means "not set yet" and resolves to runtime.default_allocator(),
// so the process-wide bridge_shell_session_map needs no initialisation. A test
// may set it to a mem.Tracking_Allocator before first use to assert the
// ownership rule holds (shell_session_ownership_test.odin does exactly that).
Bridge_Shell_Session_Map :: struct {
	mu:        sync.Mutex,
	sessions:  map[string]Bridge_Shell_Session, // keyed by session_id
	allocator: runtime.Allocator,
}

// bridge_shell_session_map_allocator resolves the map's allocator, defaulting to
// the process heap. Call it with the lock held (or before publishing the map) —
// it reads m.allocator.
bridge_shell_session_map_allocator :: proc(m: ^Bridge_Shell_Session_Map) -> runtime.Allocator {
	if m.allocator.procedure == nil do return runtime.default_allocator()
	return m.allocator
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
//
// OWNERSHIP RULE (REQ-SHELL-11). THE MAP OWNS every string of every entry it
// holds, and nothing outside the map may point into that allocation once the map
// mutex is released. There is therefore NO by-value getter: reading a session
// gives you memory whose ownership is unambiguous, in one of three shapes.
//
//   bridge_shell_session_scalars   — the string-free fields, copied under the
//                                    lock. No allocation, nothing to free.
//                                    PREFER THIS: a snapshot where scalars would
//                                    do is a needless clone.
//   bridge_shell_session_shell_id  — the daemon key, CLONED under the lock.
//                                    Release with bridge_shell_session_str_delete.
//   bridge_shell_session_snapshot  — the whole record, DEEP-CLONED under the
//                                    lock. Release with
//                                    bridge_shell_session_snapshot_destroy.
//
// That mirrors the hub side, where domain.shell_session_destroy /
// domain.shell_sessions_destroy already state the same rule for the same record.
//
// WHY, i.e. what this replaced. The old API returned Bridge_Shell_Session BY
// VALUE, so every caller walked away with borrowed pointers into the stored
// allocation while the mutex was already released. That forced register to LEAK
// the strings it superseded: freeing them would have raced any holder — the
// kill/signal handlers in hub_runtime_client.odin read sess.shell_id across a
// bridge_pty_host_ensure_daemon call that can block for up to 5s, while reconcile
// re-registers the same session from a background thread — a use-after-free with a
// seconds-wide window. With no borrowed pointers left, that free is correct, and
// bridge_shell_session_register performs it.
//
// The teardown discipline is AGENTS.md's "Socket lifetime across threads" applied
// to this map: whoever removes the key owns the free, it happens under the same
// lock that removed it, and a thread that loses that race never dereferences the
// pointer because it never held one.

// Bridge_Shell_Session_Scalars is every field of Bridge_Shell_Session that is NOT
// a string. Copying it out of the map is a plain value copy, so a caller that only
// needs status/pid/kind/port/exit/background allocates nothing and frees nothing.
Bridge_Shell_Session_Scalars :: struct {
	kind:             Bridge_Shell_Session_Kind,
	status:           Bridge_Shell_Session_Status,
	pid:              int,
	server_port:      int,
	exit_code:        int,
	exit_code_set:    bool,
	background:       bool,
	pty_host:         bool,
	pty_host_provenance_known: bool,
	started_unix_ms:  i64,
	finished_unix_ms: i64,
}

// bridge_shell_session_clone deep-clones every owned string of a session through
// `allocator`, so the result shares no allocation with `s`. Unset ("") fields stay
// unset rather than becoming an empty allocation, which is what lets
// bridge_shell_session_free_fields skip them.
bridge_shell_session_clone :: proc(s: Bridge_Shell_Session, allocator: runtime.Allocator) -> Bridge_Shell_Session {
	clone_owned :: proc(str: string, allocator: runtime.Allocator) -> string {
		if str == "" do return ""
		return strings.clone(str, allocator)
	}
	out                   := s
	out.session_id        = clone_owned(s.session_id, allocator)
	out.label             = clone_owned(s.label, allocator)
	out.cmd               = clone_owned(s.cmd, allocator)
	out.cwd               = clone_owned(s.cwd, allocator)
	out.bridge_id         = clone_owned(s.bridge_id, allocator)
	out.project_id        = clone_owned(s.project_id, allocator)
	out.chain_id          = clone_owned(s.chain_id, allocator)
	out.agent_instance_id = clone_owned(s.agent_instance_id, allocator)
	out.owner_user_id     = clone_owned(s.owner_user_id, allocator)
	out.started_at        = clone_owned(s.started_at, allocator)
	out.finished_at       = clone_owned(s.finished_at, allocator)
	out.shell_id          = clone_owned(s.shell_id, allocator)
	return out
}

// bridge_shell_session_register inserts (or replaces) a session, CONSUMING it: it
// takes ownership of every string field, and ZEROES `s` on the way out so the
// caller's copy cannot be read afterwards. Those strings MUST come from the map's
// allocator (bridge_shell_session_map_allocator) — this is the proc that will
// eventually free them.
//
// WHY IT TAKES A POINTER AND ZEROES (REQ-SHELL-11 review). Handing a struct to the
// map and then reading it again is the WRITE-SIDE version of the borrow this task
// removed from the read side, and it is the more dangerous half: the hazard is not
// this register freeing your strings, it is the NEXT register of the same session_id
// making your just-handed-over set the superseded one and freeing it while you are
// still reading. Five call sites did exactly that.
//   Odin has no move semantics, so "the caller's copy stops compiling" is not
// available. Taking `^Bridge_Shell_Session` is the closest thing: the call reads as a
// transfer at every site, and a post-register read now yields the ZERO VALUE — an
// empty id or a .Starting status that fails immediately and visibly — instead of a
// silent read of memory another thread may have freed.
//   THE ZEROING IS NOT SUFFICIENT ON ITS OWN, and callers must not treat it as a
// licence: a copy made BEFORE the call (`updated := s`, the reconcile shape) still
// aliases the same string data, and zeroing `updated` does nothing for `s`. Those
// sites clone what they need before registering. See the writer-side table in the
// task handoff.
//
// Replacing an entry FREES the strings the previous entry owned, which is only
// correct because no getter hands out a pointer into them (see the OWNERSHIP RULE
// above). Two non-obvious guards make it safe:
//
//  1. THE KEY ALIASES THE OLD ENTRY'S session_id. Odin keeps the EXISTING key when
//     you assign to a slot that is already occupied, so `m.sessions[s.session_id] = s`
//     would leave the map keyed by the old allocation and freeing it would dangle
//     the key. delete_key first, then insert, so the new key is the new allocation.
//  2. A RE-REGISTER MAY ALIAS. If a caller ever hands back a struct sharing a string
//     with the stored entry, freeing the old copy would free memory the new entry
//     still holds. Each field is therefore freed only when its data pointer DIFFERS
//     from the new entry's, which makes an aliasing re-register a no-op rather than a
//     double free.
bridge_shell_session_register :: proc(m: ^Bridge_Shell_Session_Map, s: ^Bridge_Shell_Session) {
	if s == nil do return
	// Zeroed on EVERY exit path, so a caller cannot read its copy back even when the
	// insert took the replace branch and returned early.
	defer s^ = {}
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	allocator := bridge_shell_session_map_allocator(m)
	if m.sessions == nil do m.sessions = make(map[string]Bridge_Shell_Session, allocator = allocator)
	if _, existed := m.sessions[s.session_id]; existed {
		// Guard 1: remove the key so the insert below stores the NEW session_id
		// allocation as the key, rather than keeping the old one we are about to free.
		_, superseded := delete_key(&m.sessions, s.session_id)
		m.sessions[s.session_id] = s^
		bridge_shell_session_free_superseded(superseded, s^, allocator)
		return
	}
	m.sessions[s.session_id] = s^
}

// bridge_shell_session_free_superseded frees the strings of an entry that has just
// been replaced, skipping any field the replacement shares (guard 2 on
// bridge_shell_session_register). Called with the map lock held.
@(private = "file")
bridge_shell_session_free_superseded :: proc(old, new: Bridge_Shell_Session, allocator: runtime.Allocator) {
	free_superseded :: proc(old_str, new_str: string, allocator: runtime.Allocator) {
		if old_str == "" do return
		if raw_data(old_str) == raw_data(new_str) do return // aliased: the new entry owns it
		delete(old_str, allocator)
	}
	free_superseded(old.session_id, new.session_id, allocator)
	free_superseded(old.label, new.label, allocator)
	free_superseded(old.cmd, new.cmd, allocator)
	free_superseded(old.cwd, new.cwd, allocator)
	free_superseded(old.bridge_id, new.bridge_id, allocator)
	free_superseded(old.project_id, new.project_id, allocator)
	free_superseded(old.chain_id, new.chain_id, allocator)
	free_superseded(old.agent_instance_id, new.agent_instance_id, allocator)
	free_superseded(old.owner_user_id, new.owner_user_id, allocator)
	free_superseded(old.started_at, new.started_at, allocator)
	free_superseded(old.finished_at, new.finished_at, allocator)
	free_superseded(old.shell_id, new.shell_id, allocator)
}

// bridge_shell_session_free_fields frees every owned string of a session,
// through the allocator those strings were cloned from.
//
// Two callers, and both own the memory outright: a spec loaded by
// bridge_shell_session_load_specs that reconcile then SKIPPED (never handed to the
// map), and bridge_shell_session_snapshot_destroy freeing a caller's deep clone.
// Never call it on a session the map currently holds — that entry's strings are
// freed by the map, when the key is replaced or removed.
bridge_shell_session_free_fields :: proc(s: Bridge_Shell_Session, allocator: runtime.Allocator) {
	free_owned :: proc(str: string, allocator: runtime.Allocator) {
		if str != "" do delete(str, allocator)
	}
	free_owned(s.session_id, allocator)
	free_owned(s.label, allocator)
	free_owned(s.cmd, allocator)
	free_owned(s.cwd, allocator)
	free_owned(s.bridge_id, allocator)
	free_owned(s.project_id, allocator)
	free_owned(s.chain_id, allocator)
	free_owned(s.agent_instance_id, allocator)
	free_owned(s.owner_user_id, allocator)
	free_owned(s.started_at, allocator)
	free_owned(s.finished_at, allocator)
	free_owned(s.shell_id, allocator)
}

// bridge_shell_session_exists reports whether the map holds a session, without
// copying or cloning anything.
bridge_shell_session_exists :: proc(m: ^Bridge_Shell_Session_Map, session_id: string) -> bool {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	_, ok := m.sessions[session_id]
	return ok
}

// bridge_shell_session_scalars copies the string-free fields of a session out
// from under the lock. This is the narrowest read and the one to reach for first:
// status, pid, kind, server_port, exit_code and background answer most questions
// asked of this map, and none of them needs an allocation.
bridge_shell_session_scalars :: proc(m: ^Bridge_Shell_Session_Map, session_id: string) -> (Bridge_Shell_Session_Scalars, bool) {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	s, ok := m.sessions[session_id]
	if !ok do return {}, false
	return Bridge_Shell_Session_Scalars{
		kind             = s.kind,
		status           = s.status,
		pid              = s.pid,
		server_port      = s.server_port,
		exit_code        = s.exit_code,
		exit_code_set    = s.exit_code_set,
		background       = s.background,
		pty_host         = s.pty_host,
		pty_host_provenance_known = s.pty_host_provenance_known,
		started_unix_ms  = s.started_unix_ms,
		finished_unix_ms = s.finished_unix_ms,
	}, true
}

// bridge_shell_session_shell_id returns the DAEMON KEY for a session as an OWNED
// clone: shell_id when set, else session_id. Release it with
// bridge_shell_session_str_delete.
//
// This is the dominant read — the pty-host signal, kill, respawn, capture and pane
// paths all want exactly this one string, and each of them used to spell the
// `if shell_id == "" do shell_id = session_id` fallback itself. The fallback now
// lives here, once, next to the clone that makes holding the result safe across a
// blocking bridge_pty_host_ensure_daemon call.
bridge_shell_session_shell_id :: proc(m: ^Bridge_Shell_Session_Map, session_id: string) -> (string, bool) {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	s, ok := m.sessions[session_id]
	if !ok do return "", false
	key := s.shell_id if s.shell_id != "" else s.session_id
	return strings.clone(key, bridge_shell_session_map_allocator(m)), true
}

// bridge_shell_session_str_delete releases a string handed out by
// bridge_shell_session_shell_id, through the allocator it was cloned from.
bridge_shell_session_str_delete :: proc(m: ^Bridge_Shell_Session_Map, str: string) {
	if str == "" do return
	delete(str, bridge_shell_session_map_allocator(m))
}

// bridge_shell_session_snapshot returns a FULLY OWNED deep clone of a session, for
// the few callers that genuinely serialize or re-save the whole record. Release it
// with bridge_shell_session_snapshot_destroy. Prefer _scalars or _shell_id when
// they suffice; a snapshot clones twelve strings to answer a question about one.
bridge_shell_session_snapshot :: proc(m: ^Bridge_Shell_Session_Map, session_id: string) -> (Bridge_Shell_Session, bool) {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	s, ok := m.sessions[session_id]
	if !ok do return {}, false
	return bridge_shell_session_clone(s, bridge_shell_session_map_allocator(m)), true
}

// bridge_shell_session_snapshot_destroy releases a snapshot. Mirrors
// domain.shell_session_destroy hub-side.
bridge_shell_session_snapshot_destroy :: proc(m: ^Bridge_Shell_Session_Map, s: Bridge_Shell_Session) {
	bridge_shell_session_free_fields(s, bridge_shell_session_map_allocator(m))
}

// bridge_shell_session_snapshot_by_shell_id returns a fully owned deep clone of the
// session whose shell_id matches, falling back to session_id equality for a session
// that never recorded one. Returns the first match. Release it with
// bridge_shell_session_snapshot_destroy.
bridge_shell_session_snapshot_by_shell_id :: proc(m: ^Bridge_Shell_Session_Map, shell_id: string) -> (Bridge_Shell_Session, bool) {
	if shell_id == "" do return {}, false
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	for _, s in m.sessions {
		if s.shell_id == shell_id || (s.shell_id == "" && s.session_id == shell_id) {
			return bridge_shell_session_clone(s, bridge_shell_session_map_allocator(m)), true
		}
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

// bridge_shell_session_set_run_seq adopts a new hub-assigned run number for a live
// session (REQ-SHELL-4) and returns an OWNED SNAPSHOT of the updated record so the
// caller can re-save its spec — the same shape as bridge_shell_session_set_server_port
// and bridge_shell_session_mark_background, and for the same reason.
//
// THE SPEC RE-SAVE IS NOT OPTIONAL HERE. run_seq lives on the session AND in the
// on-disk spec, and the spec is what a restarted BRIDGE reloads. Set it only in
// memory and a bridge restart would reload the PREVIOUS run's number and stamp every
// subsequent exit with it — the hub's row would be ahead, those exits would be
// discarded as stale, and the session would report running forever. That is the exact
// failure this column was added to prevent, reintroduced one layer down.
//
// Called by the restart handler AFTER a successful respawn, so a restart that failed
// leaves the bridge on the run the hub's row still names.
bridge_shell_session_set_run_seq :: proc(m: ^Bridge_Shell_Session_Map, session_id: string, run_seq: int) -> (Bridge_Shell_Session, bool) {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	if s, ok := &m.sessions[session_id]; ok {
		s.run_seq = run_seq
		return bridge_shell_session_clone(s^, bridge_shell_session_map_allocator(m)), true
	}
	return {}, false
}

// bridge_shell_session_set_server_port sets server_port on an existing session
// under the map lock (XM-9) and returns an OWNED SNAPSHOT of the updated record so
// the caller can re-save its spec — destroy it with
// bridge_shell_session_snapshot_destroy. This is the bridge's OWN copy of the port
// — the one bridge_hub_handle_tunnel_open re-validates against — so a port declared
// after start has no effect until it lands here, however up to date the hub's row is.
bridge_shell_session_set_server_port :: proc(m: ^Bridge_Shell_Session_Map, session_id: string, port: int) -> (Bridge_Shell_Session, bool) {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	if s, ok := &m.sessions[session_id]; ok {
		s.server_port = port
		return bridge_shell_session_clone(s^, bridge_shell_session_map_allocator(m)), true
	}
	return {}, false
}

// bridge_shell_session_mark_background sets background=true on a live session
// under the map lock and returns an OWNED SNAPSHOT of the updated record so the
// caller can re-save its spec. Same shape as bridge_shell_session_set_server_port,
// and for the same reason: the bridge's own copy is what the local waiter and the
// reaper read, so a flag set only on the hub row would have no effect here.
//
// The one-way rule (domain.shell_session_run_may_background) is checked by the
// caller; this proc is the write.
bridge_shell_session_mark_background :: proc(m: ^Bridge_Shell_Session_Map, session_id: string) -> (Bridge_Shell_Session, bool) {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	if s, ok := &m.sessions[session_id]; ok {
		s.background = true
		return bridge_shell_session_clone(s^, bridge_shell_session_map_allocator(m)), true
	}
	return {}, false
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

// bridge_shell_session_list_snapshot returns a DEEP-CLONED snapshot of every
// session. The old bridge_shell_session_list copied the structs into a slice and
// therefore handed out twelve borrowed pointers per entry, which its one caller
// (bridge_hub_handle_shell_list) then read every one of while serializing.
// Release the result with bridge_shell_session_list_destroy.
bridge_shell_session_list_snapshot :: proc(m: ^Bridge_Shell_Session_Map) -> []Bridge_Shell_Session {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	allocator := bridge_shell_session_map_allocator(m)
	result := make([]Bridge_Shell_Session, len(m.sessions), allocator)
	i := 0
	for _, s in m.sessions {
		result[i] = bridge_shell_session_clone(s, allocator)
		i += 1
	}
	return result
}

// bridge_shell_session_list_destroy frees a slice from
// bridge_shell_session_list_snapshot, entries included.
bridge_shell_session_list_destroy :: proc(m: ^Bridge_Shell_Session_Map, sessions: []Bridge_Shell_Session) {
	allocator := bridge_shell_session_map_allocator(m)
	for s in sessions do bridge_shell_session_free_fields(s, allocator)
	delete(sessions, allocator)
}

// bridge_shell_session_map_reset removes every session (for tests), FREEING each
// entry's strings — it used to `clear()` and leak all of them. Under the ownership
// rule the map owns those strings, so reset is a removal and removal frees; it is
// also what makes a churn test measure real growth instead of watching the reset
// hide it.
bridge_shell_session_map_reset :: proc(m: ^Bridge_Shell_Session_Map) {
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	allocator := bridge_shell_session_map_allocator(m)
	for _, s in m.sessions do bridge_shell_session_free_fields(s, allocator)
	clear(&m.sessions)
}

// bridge_shell_session_map_destroy releases the map itself as well as its entries.
// Tests that stand up a local map on a tracking allocator need this to reach zero
// live allocations; the process-wide map lives for the life of the bridge.
bridge_shell_session_map_destroy :: proc(m: ^Bridge_Shell_Session_Map) {
	bridge_shell_session_map_reset(m)
	sync.mutex_lock(&m.mu)
	defer sync.mutex_unlock(&m.mu)
	delete(m.sessions)
	m.sessions = nil
}

// ---- pending kill intents (REQ-SHELL-3) ----------------------------------
//
// A kill can arrive for a session this bridge does not know yet. The hub creates the
// row and then sends shell_start, so a kill accepted in between is dispatched
// against a session_id that is not in the map: before this, that kill was dropped on
// the floor and the process leaked the moment it spawned (the task's edge case C).
// The intent is recorded here instead and applied by bridge_hub_handle_shell_start
// the moment the spawn produces a pid — a session that starts while carrying a kill
// intent is killed immediately, never left running.
//
// IN MEMORY, NOT ON DISK, and that is deliberate. The DURABLE store for a kill
// intent is the hub's shell_sessions.kill_requested_at column, and the hub re-issues
// every outstanding intent when this bridge's WS reconnects — which is exactly what
// happens after a bridge restart. Persisting the set here as well would be a second
// source of truth for the same fact, with its own staleness and its own clearing
// rule, to cover a window the hub already covers.
//
// The set is therefore SMALL and SHORT-LIVED: one entry between a kill and the start
// it raced, consumed by that start. An entry for a session that never starts (the
// start failed, or the hub gave up) is a bounded leak of one map key, cleared by a
// bridge restart; it cannot cause a wrong kill, because it is only ever consumed by
// a spawn of that same session_id.
@(private = "file")
_bridge_shell_pending_kills: map[string]bool
@(private = "file")
_bridge_shell_pending_kills_mu: sync.Mutex

// bridge_shell_kill_intent_record notes that a kill arrived for a session that is
// not in the map yet. Idempotent: the set holds an intent, not a count.
bridge_shell_kill_intent_record :: proc(session_id: string) {
	if session_id == "" do return
	sync.mutex_lock(&_bridge_shell_pending_kills_mu)
	defer sync.mutex_unlock(&_bridge_shell_pending_kills_mu)
	if _bridge_shell_pending_kills == nil {
		_bridge_shell_pending_kills = make(map[string]bool, allocator = runtime.default_allocator())
	}
	if session_id in _bridge_shell_pending_kills do return
	_bridge_shell_pending_kills[strings.clone(session_id, runtime.default_allocator())] = true
}

// bridge_shell_kill_intent_take consumes a pending intent, reporting whether one was
// there. CONSUMING rather than peeking is what makes applying it a one-shot: the
// spawn path acts on it exactly once, and a later redelivery from the hub goes
// through the normal kill path against a session that is now in the map.
bridge_shell_kill_intent_take :: proc(session_id: string) -> bool {
	if session_id == "" do return false
	sync.mutex_lock(&_bridge_shell_pending_kills_mu)
	defer sync.mutex_unlock(&_bridge_shell_pending_kills_mu)
	if _bridge_shell_pending_kills == nil do return false
	for k in _bridge_shell_pending_kills {
		if k == session_id {
			delete_key(&_bridge_shell_pending_kills, k)
			delete(k, runtime.default_allocator())
			return true
		}
	}
	return false
}

// bridge_shell_kill_intent_pending reports whether an intent is recorded WITHOUT
// consuming it. For assertions and diagnostics only — the spawn path must use
// bridge_shell_kill_intent_take so the intent is applied once.
bridge_shell_kill_intent_pending :: proc(session_id: string) -> bool {
	sync.mutex_lock(&_bridge_shell_pending_kills_mu)
	defer sync.mutex_unlock(&_bridge_shell_pending_kills_mu)
	if _bridge_shell_pending_kills == nil do return false
	for k in _bridge_shell_pending_kills {
		if k == session_id do return true
	}
	return false
}

// bridge_shell_kill_intent_reset clears the set (for tests), freeing its keys.
bridge_shell_kill_intent_reset :: proc() {
	sync.mutex_lock(&_bridge_shell_pending_kills_mu)
	defer sync.mutex_unlock(&_bridge_shell_pending_kills_mu)
	if _bridge_shell_pending_kills == nil do return
	for k in _bridge_shell_pending_kills do delete(k, runtime.default_allocator())
	clear(&_bridge_shell_pending_kills)
}

// bridge_shell_session_status_is_terminal is the bridge's mirror of
// domain.shell_session_status_is_terminal: the session is over and must not be
// signalled again. It is what makes a REDELIVERED kill a no-op — the kill path marks
// a session .Killed before its worker even starts, so a second delivery of the same
// kill sees a terminal session and does nothing, rather than arming a second
// SIGTERM/SIGKILL pair against a pid that may by then have been recycled.
bridge_shell_session_status_is_terminal :: proc(status: Bridge_Shell_Session_Status) -> bool {
	switch status {
	case .Exited, .Killed, .Failed: return true
	case .Starting, .Running:       return false
	}
	return false
}

// ---- durable JSON spec store --------------------------------------------

// The returned string is ALWAYS a fresh allocation (concatenate, never an alias of
// data_dir), so every caller owns it and must delete it. All three used to drop it:
// save_spec leaked one path per spec write — i.e. per start, per port change, per
// background conversion and per exit — and load_specs one per reconnect.
bridge_shell_session_spec_dir :: proc(data_dir: string) -> string {
	return strings.concatenate({strings.trim_right(data_dir, "/"), "/shell_sessions"})
}

// bridge_shell_session_save_spec writes the session spec to disk atomically
// (write to a .tmp file then rename). Callers pass the expanded data_dir.
bridge_shell_session_save_spec :: proc(data_dir: string, s: Bridge_Shell_Session) {
	dir := bridge_shell_session_spec_dir(data_dir)
	defer delete(dir)
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
	strings.write_string(&b, ",\"run_seq\":")
	strings.write_string(&b, bridge_agent_itoa(s.run_seq))
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
	strings.write_string(&b, "\",\"background\":")
	strings.write_string(&b, s.background ? "true" : "false")
	strings.write_string(&b, ",\"pty_host\":")
	strings.write_string(&b, s.pty_host ? "true" : "false")
	strings.write_byte(&b, '}')

	json_str := strings.to_string(b)
	if os.write_entire_file(tmp, transmute([]byte)json_str) == nil {
		_ = os.rename(tmp, path)
	}
}

// bridge_shell_session_load_specs reads all *.json spec files from the
// shell_sessions directory. Corrupt or unreadable files are logged and skipped.
//
// The caller owns the returned slice and each element's string fields, and they are
// cloned from `allocator` — which must be the SESSION MAP'S allocator whenever a
// spec may be registered, because register then takes ownership and the map's free
// must match this clone. Release a spec the caller keeps with
// bridge_shell_session_free_fields(s, allocator), and the slice with
// delete(specs, allocator).
bridge_shell_session_load_specs :: proc(data_dir: string, allocator: runtime.Allocator) -> []Bridge_Shell_Session {
	dir := bridge_shell_session_spec_dir(data_dir)
	defer delete(dir)
	infos, rerr := os.read_directory_by_path(dir, -1, context.allocator)
	if rerr != nil do return nil
	defer os.file_info_slice_delete(infos, context.allocator)

	result := make([dynamic]Bridge_Shell_Session, allocator = allocator)
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
		if v, ok := obj["session_id"].(json.String); ok do s.session_id = strings.clone(string(v), allocator)
		if v, ok := obj["kind"].(json.String); ok do s.kind = bridge_shell_session_kind_from_str(string(v))
		if v, ok := obj["label"].(json.String); ok do s.label = strings.clone(string(v), allocator)
		if v, ok := obj["cmd"].(json.String); ok do s.cmd = strings.clone(string(v), allocator)
		if v, ok := obj["cwd"].(json.String); ok do s.cwd = strings.clone(string(v), allocator)
		if v, ok := obj["bridge_id"].(json.String); ok do s.bridge_id = strings.clone(string(v), allocator)
		if v, ok := obj["project_id"].(json.String); ok do s.project_id = strings.clone(string(v), allocator)
		if v, ok := obj["chain_id"].(json.String); ok do s.chain_id = strings.clone(string(v), allocator)
		if v, ok := obj["agent_instance_id"].(json.String); ok do s.agent_instance_id = strings.clone(string(v), allocator)
		if v, ok := obj["owner_user_id"].(json.String); ok do s.owner_user_id = strings.clone(string(v), allocator)
		if v, ok := obj["pid"].(json.Float); ok do s.pid = int(v)
		if v, ok := obj["server_port"].(json.Float); ok do s.server_port = int(v)
		// A spec written before REQ-SHELL-4 has no run_seq key and loads as 0, the
		// first run — the same value the hub's row carries for a session that has
		// never been restarted, so the two sides agree with no backfill.
		if v, ok := obj["run_seq"].(json.Float); ok do s.run_seq = int(v)
		if v, ok := obj["status"].(json.String); ok do s.status = bridge_shell_session_status_from_str(string(v))
		if v, ok := obj["exit_code"].(json.Float); ok do s.exit_code = int(v)
		if v, ok := obj["exit_code_set"].(json.Boolean); ok do s.exit_code_set = bool(v)
		if v, ok := obj["started_at"].(json.String); ok do s.started_at = strings.clone(string(v), allocator)
		if v, ok := obj["finished_at"].(json.String); ok do s.finished_at = strings.clone(string(v), allocator)
		if v, ok := obj["shell_id"].(json.String); ok do s.shell_id = strings.clone(string(v), allocator)
		if v, ok := obj["background"].(json.Boolean); ok do s.background = bool(v)
		// A spec written before REQ-SHELL-2 has no pty_host key and loads as false,
		// i.e. "direct child". That is the SAFE default: the false branch proves
		// liveness with ps before acting, while defaulting to true would ask the
		// roster about a process that may never have been in it and reap it as dead.
		if v, ok := obj["pty_host"].(json.Boolean); ok {
			s.pty_host = bool(v)
			s.pty_host_provenance_known = true
		}

		if s.session_id != "" do append(&result, s)
	}
	return result[:]
}

bridge_shell_session_delete_spec :: proc(data_dir: string, session_id: string) {
	dir := bridge_shell_session_spec_dir(data_dir)
	defer delete(dir)
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

	// REQ-SHELL-10: hand the hub this bridge's WHOLE live truth, so it can diff its
	// rows against it instead of waiting for an event per divergence.
	//
	// AFTER the reconcile pass, never before, and that ordering is the first half of
	// the guarantee that the inventory and the REQ-SHELL-4 exit outbox cannot
	// disagree: the pass has by now moved every session it found dead to a terminal
	// status in the map and enqueued its exit, so those sessions are absent from the
	// snapshot rather than being reported live and dead at once. See the header of
	// shell_inventory.odin for the rest of it.
	//
	// It also inherits this proc's EARLY RETURNS, and that is deliberate rather than a
	// gap: if the pty-host daemon or its list is unreachable we return above without
	// sending anything. An inventory asserts "these and ONLY these are alive", and
	// asserting that on the strength of a roster we could not read would have the hub
	// mark healthy sessions terminal. No diff is better than a wrong diff; the next
	// reconnect sends one built on a roster we could read.
	frame := bridge_shell_inventory_build(&bridge_shell_session_map)
	defer delete(frame)
	bridge_shell_inventory_enqueue(frame)
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
// REQ-RECON-4 claimed all kinds are handled identically via the daemon roster.
// That is TRUE ONLY FOR PTY-HOST-SPAWNED SESSIONS, and REQ-SHELL-2 made the
// difference load-bearing by persisting specs for direct-child runs as well.
//
// THE BUG THIS BRANCH FIXES (C5). A run spawned by the legacy shell-cmd path is a
// direct os.process_start child. It is never in the pty-host roster, so
// `found_alive` can never be set for it, and it fell straight through to the
// "not found -> pid is plausible -> kill it" branch below — on every hub WS
// reconnect, against a run that was perfectly alive and still tracked in this
// bridge's own memory. Persisting run specs is what exposed it; before that,
// reconcile simply never saw these sessions.
//
// So the roster question is asked ONLY of sessions that can answer it
// (s.pty_host), and a direct child is resolved by the three-way rule in
// bridge_shell_session_reconcile_direct_child below.
//
// Idempotency: sessions already in a terminal state (Failed/Exited/Killed) in
// the in-memory map are skipped so re-connections don't double-process them.
bridge_shell_session_reconcile :: proc(m: ^Bridge_Shell_Session_Map, daemon_agents: []Pty_Host_Agent_Info, data_dir: string) {
	// THE MAP'S allocator, not context.allocator: a spec loaded here may be handed
	// straight to bridge_shell_session_register, which makes the map responsible for
	// freeing it later. Loading through a different allocator than the map frees
	// through is the mismatch this runs on a background thread to discover.
	allocator := bridge_shell_session_map_allocator(m)
	specs := bridge_shell_session_load_specs(data_dir, allocator)
	if specs == nil do return
	defer delete(specs, allocator)

	for s in specs {
		// Each spec's strings are freshly cloned by load_specs. Registering a
		// session hands them to the map; any spec we skip owns strings nothing
		// else will ever free, and reconcile re-reads the same on-disk specs on
		// every reconnect — so a skipped spec would otherwise leak its full
		// string set, forever, on a non-arena background thread.
		transferred := false
		defer if !transferred do bridge_shell_session_free_fields(s, allocator)

		// A KNOWN direct child is never in the roster; resolving it there would reap
		// a live process. It gets its own liveness rule instead.
		//
		// A spec of UNKNOWN provenance (pre-REQ-SHELL-2, no pty_host key) is NOT
		// treated as a direct child: it may be a genuinely pty-host-spawned session,
		// and a roster hit is strictly more information than ps can produce, so it
		// falls through to the roster below and only reaches the direct-child rule if
		// the roster does not know it. Trying the roster first costs one comparison
		// against a list already in hand.
		if !s.pty_host && s.pty_host_provenance_known {
			handled, took := bridge_shell_session_reconcile_direct_child(m, s, data_dir)
			if took do transferred = true
			if handled do continue
			// Not handled = not in the map = an orphan from a previous bridge life.
			// Fall through to the kill-and-report path below, which is unchanged.
		} else {
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
						// Re-saved with provenance now recorded, so a legacy spec becomes a
						// known-pty_host spec the first time reconcile reclaims it and never
						// takes the unknown path again.
						updated.pty_host = true
						updated.pty_host_provenance_known = true
						// SPEC FIRST, THEN REGISTER: save_spec reads every string of
						// `updated`, which the map owns the moment register takes it, and
						// this runs on the reconnect thread with the hub reissuing starts.
						bridge_shell_session_save_spec(data_dir, updated)
						bridge_shell_session_register(m, &updated) // CONSUMES updated
						transferred = true
					}
					// found-dead: treat same as not-found (session exited in daemon)
					break
				}
			}
			if found_alive do continue

			// Unknown provenance and the roster does not know it either: it may still
			// be a direct child from a legacy spec, so give it the ps-based rule before
			// falling through to the kill path. Without this, a legacy direct-child run
			// that is alive and owned by this process would be reaped.
			if !s.pty_host_provenance_known {
				handled, took := bridge_shell_session_reconcile_direct_child(m, s, data_dir)
				if took do transferred = true
				if handled do continue
			}
		}

		// Idempotency: skip sessions already in a terminal state. Only the status is
		// read, so this takes the scalar copy and allocates nothing.
		if existing, has := bridge_shell_session_scalars(m, s.session_id); has {
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
		//
		// THE ID IS CLONED FIRST (REQ-SHELL-11 review). `updated := s` SHARES every
		// string with the spec, so once register has it, s.session_id is map-owned too —
		// and the three reads below (delete_spec, wait_signal_exit, the event json) would
		// be reads of memory a concurrent re-register can free. Zeroing register's
		// argument does not help here: it zeroes `updated`, while `s` still aliases the
		// same data.
		//   Cloning rather than reordering, because the ORDER IS LOAD-BEARING: the map
		// must say terminal BEFORE wait_signal_exit releases a waiter, or the released
		// waiter re-reads the session, still sees Running, and reports a live run it was
		// just told had ended. One small allocation on a path that already pays a `ps`
		// popen per session.
		sid := strings.clone(s.session_id, allocator)
		defer delete(sid, allocator)

		updated              := s
		updated.status        = final_status
		updated.exit_code_set = true
		updated.exit_code     = 1
		bridge_shell_session_register(m, &updated) // CONSUMES updated; s now aliases map memory
		transferred = true
		bridge_shell_session_delete_spec(data_dir, sid)
		// Release any foreground caller parked on this session. Reachable for a
		// pty-host session found dead within THIS bridge's life; a true cross-restart
		// orphan has no waiter and the signal is a harmless no-op. Additive to the
		// hub event below, never a replacement for it (W3).
		bridge_shell_wait_signal_exit(sid, final_status, 1, true)
		// s.run_seq, read before register consumed `updated` — the run this orphaned
		// session belonged to, not whatever it may have been restarted into since.
		event := bridge_shell_exited_event_json(sid, 1, true, status_str, s.run_seq)
		bridge_shell_exited_enqueue(event)
		delete(event)
	}
}

// bridge_shell_session_reconcile_direct_child resolves ONE spec whose process is
// a direct os.process_start child of the bridge rather than a pty-host session.
//
// Returns (handled, transferred): `handled` is false only for the not-in-map case,
// which the CALLER must then resolve through its orphan kill-and-report path —
// returning false there rather than swallowing it is what keeps a cross-restart
// orphan from being silently dropped. `transferred` says the session was handed to
// the map, so the caller must not free its strings.
//
// Three outcomes, and the middle one is why map presence alone is not enough:
//
//   in map, non-terminal, AND pid plausible -> genuinely alive and THIS bridge
//       process owns it. SKIP: leave it running, leave its spec in place.
//
//   in map, non-terminal, NOT pid plausible -> it died and we missed the exit.
//       Report it terminal and clear the spec, but do NOT kill: there is nothing
//       left to kill. Trusting map presence alone here would be the real hazard —
//       if an exit event is ever missed the entry stays non-terminal FOREVER,
//       reconcile skips it on every pass, and the hub reports a dead run as
//       running with the very mechanism that would have corrected it now the one
//       suppressing it. That is a live-on-hub/dead-on-bridge divergence made
//       permanent and self-reinforcing.
//
//   not in map -> an orphan from a PREVIOUS bridge life (the map is empty after a
//       restart; the process survived because it was reparented to init). Fall
//       through to the caller's existing kill-and-report path, unchanged.
//
// COST, deliberately paid: one `ps -p` popen per non-terminal direct-child run per
// reconcile pass. Reconcile runs on hub WS reconnect, not in any hot path, and the
// kill branch below has always paid exactly this. DO NOT "optimise" it away — the
// popen IS the liveness proof, and replacing it with in-memory bookkeeping
// reintroduces the permanent-divergence case above.
bridge_shell_session_reconcile_direct_child :: proc(m: ^Bridge_Shell_Session_Map, s: Bridge_Shell_Session, data_dir: string) -> (handled: bool, transferred: bool) {
	// A SNAPSHOT, not a borrow: the pid-plausibility check below shells out to `ps`,
	// which is exactly the kind of blocking gap in which another thread can re-register
	// this session and free the strings a borrowed struct would still be pointing at.
	existing, in_map := bridge_shell_session_snapshot(m, s.session_id)
	if !in_map do return false, false // orphan from a previous life: caller's kill path
	defer bridge_shell_session_snapshot_destroy(m, existing)

	switch existing.status {
	case .Failed, .Exited, .Killed:
		// Already terminal: the exit path owns the spec deletion. Idempotent, as
		// before — repeated reconnects must not re-report a finished run.
		return true, false
	case .Running, .Starting:
		// fall through
	}

	if bridge_shell_session_pid_is_plausible(existing.pid, existing.cmd, existing.started_at) {
		return true, false // alive and ours: leave it entirely alone
	}

	// Died with the exit unobserved. Mark terminal, clear the spec, and tell the
	// hub — the same reporting the exit path would have done, just late.
	//
	// THE ID IS CLONED FIRST, for the same reason as the orphan path in
	// bridge_shell_session_reconcile: `updated := s` shares its strings with the spec,
	// so after register every s.session_id read would be a read of map-owned memory,
	// and the map must say terminal before wait_signal_exit releases anyone.
	allocator := bridge_shell_session_map_allocator(m)
	sid := strings.clone(s.session_id, allocator)
	defer delete(sid, allocator)

	updated              := s
	updated.status        = .Failed
	updated.exit_code_set = true
	updated.exit_code     = 1
	bridge_shell_session_register(m, &updated) // CONSUMES updated; s now aliases map memory
	bridge_shell_session_delete_spec(data_dir, sid)
	// Release any foreground caller still parked on it, or it would block until its
	// own ceiling on a run that ended long ago (W3: additive, alongside the hub event).
	bridge_shell_wait_signal_exit(sid, .Failed, 1, true)
	event := bridge_shell_exited_event_json(sid, 1, true, "failed", s.run_seq)
	bridge_shell_exited_enqueue(event)
	delete(event)
	return true, true
}

// ---- string helpers ------------------------------------------------------

bridge_shell_session_kind_str :: proc(k: Bridge_Shell_Session_Kind) -> string {
	switch k {
	case .Run:    return "run"
	case .Shell:  return "shell"
	case .Server: return "server"
	}
	return "run"
}

// An unrecognised spelling falls back to .Run, the kind with no scope
// prerequisites of its own. The hub validates kind before it ever reaches the
// wire (domain.shell_session_validate_scope), so this is a defensive default for
// a malformed frame rather than a parsing policy — in particular it does NOT
// accept any retired spelling, it merely
// does not crash on them.
bridge_shell_session_kind_from_str :: proc(s: string) -> Bridge_Shell_Session_Kind {
	switch s {
	case "shell":  return .Shell
	case "server": return .Server
	}
	return .Run
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
