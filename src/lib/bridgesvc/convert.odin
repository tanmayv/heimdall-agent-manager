package bridgesvc

// Legacy -> supervisor conversion transaction (docs/specs/bridge-supervisor-conversion.md,
// REQ-CONV-1/2). This file is the pure core: the crash journal `conversion.json` (§4.1),
// the step order C0-C9 (§4.2), the rollback order R1-R6 (§6.2), the recovery decision
// (§6.3) and the Q3 agent gate decision (§9). Every side effect lives behind
// Convert_Ops (src/bridge/convert_cmd.odin), so tests inject a failure at every step on
// every OS.
//
// Invariants the runner enforces:
//   * `conversion.json` is written (state "begin") before a step's side effects and
//     (state "done") after, so a crash is recoverable from the record alone.
//   * A failure at or before C8 rolls back R1-R6; a failure in C9 never does (the
//     commit happened; finalize_conversion is idempotent and re-run later).
//   * A rollback step that fails stops the rollback: nothing further is deleted, the
//     record and backup stay, and the outcome is `rollback_failed` (exit 7).

import "core:crypto"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

CONVERSION_FILE :: "conversion.json"
CONVERSION_SCHEMA :: 1
CONVERT_BACKUP_PREFIX :: ".convert-"
CONVERT_NOW_REQUEST :: "convert-now.request"
CONVERT_STATUS_FILE :: "conversion-status.json"
// Q3 gate: wait this long for running agents, then force (engine §12).
CONVERT_GATE_WAIT_SECONDS :: i64(2 * 60 * 60)
// C8: T_commit (270 s) + 30 s (spec §4.2).
CONVERT_COMMIT_TIMEOUT_SECONDS :: 300

// Convert_Step is C1..C9 in execution order. C0 (lock, classify, recovery) is setup's
// Lock step and is not part of the journaled transaction.
Convert_Step :: enum {
	Gate, // C1
	Fetch, // C2
	Backup, // C3
	Quiesce, // C4 (+ C4a rescuer, C4b state snapshot)
	Tree, // C5 instance.json, repair, launcher, update.json
	Cutover, // C6 service definition
	Enroll, // C6b
	Extensions, // C6c
	Start, // C7
	Verify, // C8 journal committed (+ connected)
	Finalize, // C9
}

CONVERT_STEP_NAMES := [Convert_Step]string {
	.Gate       = "C1",
	.Fetch      = "C2",
	.Backup     = "C3",
	.Quiesce    = "C4",
	.Tree       = "C5",
	.Cutover    = "C6",
	.Enroll     = "C6b",
	.Extensions = "C6c",
	.Start      = "C7",
	.Verify     = "C8",
	.Finalize   = "C9",
}

// --json-progress ids (docs/bridge-setup-progress.md).
CONVERT_STEP_EVENT := [Convert_Step]string {
	.Gate       = "convert_gate",
	.Fetch      = "convert_fetch",
	.Backup     = "convert_backup",
	.Quiesce    = "convert_quiesce",
	.Tree       = "convert_tree",
	.Cutover    = "service",
	.Enroll     = "enroll",
	.Extensions = "extensions",
	.Start      = "start",
	.Verify     = "convert_commit",
	.Finalize   = "convert_finalize",
}

convert_step_from_name :: proc(name: string) -> (Convert_Step, bool) {
	for n, s in CONVERT_STEP_NAMES do if n == name do return s, true
	return {}, false
}

// Conversion_Record is <data>/conversion.json.
Conversion_Record :: struct {
	schema:        int      `json:"schema"`,
	txn:           string   `json:"txn"`,
	mode:          string   `json:"mode"`, // "convert" | "greenfield"
	service:       string   `json:"service"`,
	from_version:  string   `json:"from_version"`,
	to_version:    string   `json:"to_version"`,
	to_tree:       string   `json:"to_tree"`,
	instance_id:   string   `json:"instance_id"`,
	op_id:         string   `json:"op_id"`,
	backup:        string   `json:"backup"`,
	was_running:   bool     `json:"was_running"`,
	was_connected: bool     `json:"was_connected"`,
	started_at:    i64      `json:"started_at"`,
	force_at:      i64      `json:"force_at"`, // Q3 gate deadline; never reset by a re-run
	step:          string   `json:"step"`,
	state:         string   `json:"state"`, // "begin" | "done"
	done:          []string `json:"done"`,
	phase:         string   `json:"phase"`, // "forward" | "rolling_back"
}

CONVERT_MODE_CONVERT :: "convert"
CONVERT_MODE_GREENFIELD :: "greenfield"
CONVERT_PHASE_FORWARD :: "forward"
CONVERT_PHASE_ROLLING_BACK :: "rolling_back"

valid_txn :: proc(txn: string) -> bool {
	if len(txn) != 19 || !strings.has_prefix(txn, "cv_") do return false
	for c in transmute([]byte)txn[3:] {
		switch c {
		case '0' ..= '9', 'a' ..= 'f':
		case:
			return false
		}
	}
	return true
}

// new_txn_id: "cv_" + 16 lowercase hex from the OS CSPRNG.
new_txn_id :: proc(allocator := context.temp_allocator) -> string {
	raw: [8]byte
	crypto.rand_bytes(raw[:])
	return strings.concatenate({"cv_", string(hex.encode(raw[:], context.temp_allocator))}, allocator)
}

// new_instance_id: "ins_" + 32 lowercase hex (engine §3).
new_instance_id :: proc(allocator := context.temp_allocator) -> string {
	raw: [16]byte
	crypto.rand_bytes(raw[:])
	return strings.concatenate({"ins_", string(hex.encode(raw[:], context.temp_allocator))}, allocator)
}

conversion_path :: proc(l: Layout) -> string {return pjoin(l.data_dir, CONVERSION_FILE)}
convert_backup_dir :: proc(l: Layout, txn: string) -> string {
	return pjoin(l.data_dir, strings.concatenate({CONVERT_BACKUP_PREFIX, txn}, context.temp_allocator))
}
convert_download_dir :: proc(l: Layout, txn: string) -> string {
	return pjoin(l.data_dir, "updates", strings.concatenate({"convert-", txn}, context.temp_allocator))
}
convert_status_path :: proc(l: Layout) -> string {return pjoin(l.state_dir, CONVERT_STATUS_FILE)}
convert_now_path :: proc(l: Layout) -> string {return pjoin(l.state_dir, CONVERT_NOW_REQUEST)}

encode_conversion :: proc(r: Conversion_Record, allocator := context.temp_allocator) -> string {
	rec := r
	rec.schema = CONVERSION_SCHEMA
	if rec.done == nil do rec.done = []string{}
	data, err := json.marshal(rec, {spec = .JSON}, allocator)
	if err != nil do return ""
	return strings.concatenate({string(data), "\n"}, allocator)
}

// parse_conversion reads a record strictly: schema 1, a valid txn, known step names.
// A record that fails is "unreadable" (spec §6.3 case 4).
parse_conversion :: proc(text: string, allocator := context.temp_allocator) -> (r: Conversion_Record, ok: bool) {
	if err := json.unmarshal(transmute([]byte)text, &r, .JSON, allocator); err != nil do return {}, false
	if r.schema != CONVERSION_SCHEMA || !valid_txn(r.txn) do return {}, false
	if r.mode != CONVERT_MODE_CONVERT && r.mode != CONVERT_MODE_GREENFIELD do return {}, false
	if r.phase != CONVERT_PHASE_FORWARD && r.phase != CONVERT_PHASE_ROLLING_BACK do return {}, false
	if r.step != "" {
		if _, known := convert_step_from_name(r.step); !known do return {}, false
	}
	for d in r.done do if _, known := convert_step_from_name(d); !known do return {}, false
	return r, true
}

record_done :: proc(r: Conversion_Record, step: Convert_Step) -> bool {
	name := CONVERT_STEP_NAMES[step]
	for d in r.done do if d == name do return true
	return false
}

// Recovery_Action is what the next setup run (or the rescuer) does with a leftover
// conversion.json (spec §6.3).
Recovery_Action :: enum {
	Continue_Rollback, // phase rolling_back: continue R1-R6
	Finalize, // C8 done: only C9 remains (roll forward)
	Roll_Forward, // C6 done and the layout verifies: continue at C7
	Roll_Back, // anything else
}

// recovery_action decides from the record alone; `layout_ok` is the caller's cheap
// check that tree, launcher and instance.json verify (the C5(c) checks).
recovery_action :: proc(r: Conversion_Record, layout_ok: bool) -> Recovery_Action {
	switch {
	case r.phase == CONVERT_PHASE_ROLLING_BACK:
		return .Continue_Rollback
	case record_done(r, .Verify):
		return .Finalize
	case record_done(r, .Cutover) && layout_ok:
		return .Roll_Forward
	}
	return .Roll_Back
}

// ---- rollback ----------------------------------------------------------------

// Rollback_Step is R1-R6 of spec §6.2.
Rollback_Step :: enum {
	Stop_New, // R1
	Restore_Service, // R2
	Restore_Settings, // R3
	Remove_Layout, // R4
	Restart_Old, // R5
	Close, // R6
}

ROLLBACK_STEP_NAMES := [Rollback_Step]string {
	.Stop_New         = "R1",
	.Restore_Service  = "R2",
	.Restore_Settings = "R3",
	.Remove_Layout    = "R4",
	.Restart_Old      = "R5",
	.Close            = "R6",
}

Convert_Ops :: struct {
	data:     rawptr,
	// Runs one forward step. rec is the live record (mutable by the implementation:
	// it fills to_tree, instance_id, backup, ... and the runner persists it).
	run:      proc(data: rawptr, step: Convert_Step, rec: ^Conversion_Record) -> Step_Result,
	// Atomically writes the record. Called before (begin) and after (done) each step
	// and when the phase changes. A failure here fails the step.
	persist:  proc(data: rawptr, rec: Conversion_Record) -> bool,
	// Runs one rollback step; the implementation reads rec.done to skip what never ran.
	rollback: proc(data: rawptr, step: Rollback_Step, rec: Conversion_Record) -> (ok: bool, message: string),
	emit:     proc(data: rawptr, ev: Event),
	// Polled between steps: SIGTERM/SIGINT/SIGHUP/console close (spec §6.2). nil = never.
	cancelled: proc(data: rawptr) -> bool,
}

Convert_Result :: struct {
	ok:              bool,
	failed_step:     Convert_Step,
	message:         string, // the failing step's message
	rolled_back:     bool, // the previous install was restored
	rollback_failed: bool, // exit 7: the record and backup are kept
	rollback_message: string,
	finalize_warning: string, // C9 failed after the commit: rolled forward later
	cancelled:       bool,
}

// run_conversion runs the forward steps from `first`, skipping steps rec already lists
// as done (recovery roll-forward). On failure it rolls back R1-R6.
run_conversion :: proc(ops: Convert_Ops, rec: ^Conversion_Record, first := Convert_Step.Gate) -> (res: Convert_Result) {
	for step in Convert_Step {
		if step < first || record_done(rec^, step) do continue
		name := CONVERT_STEP_EVENT[step]
		if ops.cancelled != nil && ops.cancelled(ops.data) {
			res.cancelled, res.failed_step, res.message = true, step, "cancelled by a signal"
			return convert_rollback(ops, rec, res)
		}
		rec.step, rec.state = CONVERT_STEP_NAMES[step], "begin"
		ops.emit(ops.data, Event{step = name, state = "start", pct = convert_pct(step, false), attempt = 1})
		persisted := ops.persist(ops.data, rec^)
		r: Step_Result
		if persisted {
			r = ops.run(ops.data, step, rec)
		} else {
			r = Step_Result{failure = .Fatal, message = "cannot write conversion.json"}
		}
		if r.ok || (step == .Gate && r.message == "skipped") {
			rec.state = "done"
			rec.done = append_done(rec.done, step)
			if !ops.persist(ops.data, rec^) && step != .Finalize {
				r = Step_Result{failure = .Fatal, message = "cannot write conversion.json"}
			} else {
				state := "skipped" if r.message == "skipped" else "ok"
				ops.emit(ops.data, Event{step = name, state = state, pct = convert_pct(step, true), message = r.message, log = r.log, attempt = 1})
				continue
			}
		}
		if step == .Finalize {
			// Committed: never roll back. finalize_conversion is idempotent and is run
			// again by the runtime, status and the next setup (spec §6.5).
			res.finalize_warning = r.message
			ops.emit(ops.data, Event{step = name, state = "warning", pct = convert_pct(step, true), message = r.message, attempt = 1})
			res.ok = true
			return
		}
		ops.emit(ops.data, Event{step = name, state = "failed", pct = convert_pct(step, false), message = r.message, log = r.log, attempt = 1, failure = FAILURE_NAMES[r.failure]})
		res.failed_step, res.message = step, r.message
		return convert_rollback(ops, rec, res)
	}
	res.ok = true
	return
}

@(private = "file")
append_done :: proc(done: []string, step: Convert_Step) -> []string {
	out := make([]string, len(done) + 1, context.temp_allocator)
	copy(out, done)
	out[len(done)] = CONVERT_STEP_NAMES[step]
	return out
}

convert_pct :: proc(step: Convert_Step, done: bool) -> int {
	return (int(step) + (1 if done else 0)) * 100 / len(Convert_Step)
}

// convert_rollback runs R1-R6 (also called by recovery with a Continue_Rollback or
// Roll_Back decision).
convert_rollback :: proc(ops: Convert_Ops, rec: ^Conversion_Record, in_: Convert_Result) -> (res: Convert_Result) {
	res = in_
	if rec.phase != CONVERT_PHASE_ROLLING_BACK {
		rec.phase = CONVERT_PHASE_ROLLING_BACK
		// Before C3 there is no record on disk to update; persist is best effort then.
		_ = ops.persist(ops.data, rec^)
	}
	for rs in Rollback_Step {
		ok, msg := ops.rollback(ops.data, rs, rec^)
		if !ok {
			res.rollback_failed = true
			res.rollback_message = fmt.tprintf("%s: %s", ROLLBACK_STEP_NAMES[rs], msg)
			ops.emit(ops.data, Event{step = "setup", state = "warning", message = fmt.tprintf("rollback incomplete: %s", res.rollback_message)})
			return
		}
		ops.emit(ops.data, Event{step = CONVERT_STEP_EVENT[res.failed_step], state = "rollback", message = ROLLBACK_STEP_NAMES[rs]})
	}
	res.rolled_back = true
	return
}

// recover_conversion applies recovery_action to a leftover record (spec §6.3).
recover_conversion :: proc(ops: Convert_Ops, rec: ^Conversion_Record, layout_ok: bool) -> (action: Recovery_Action, res: Convert_Result) {
	action = recovery_action(rec^, layout_ok)
	switch action {
	case .Continue_Rollback, .Roll_Back:
		res = convert_rollback(ops, rec, Convert_Result{failed_step = .Start, message = "interrupted conversion"})
	case .Roll_Forward:
		res = run_conversion(ops, rec, .Start)
	case .Finalize:
		res = run_conversion(ops, rec, .Finalize)
	}
	return
}

// ---- Q3 agent gate (spec §9) -------------------------------------------------

Gate_Verdict :: enum {
	Proceed, // no agents, or an "update now" request
	Wait, // agents running and before force_at
	Force, // force_at reached: stop this instance's agents and go on
}

// gate_decide: `agents` < 0 means "could not be counted" and counts as busy (fail
// closed, engine §12.1). `now_requested` is a convert-now request newer than the
// gate's own start.
gate_decide :: proc(now, force_at: i64, agents: int, now_requested: bool) -> Gate_Verdict {
	if now_requested do return .Proceed
	if agents == 0 do return .Proceed
	if now >= force_at do return .Force
	return .Wait
}

// gate_message is the countdown line: "Converting to the supervisor in 1 h 12 min; 3 agents will be stopped".
gate_message :: proc(remaining_s: i64, agents: int) -> string {
	r := max(remaining_s, 0)
	when_text: string
	switch {
	case r >= 3600:
		when_text = fmt.tprintf("%d h %d min", r / 3600, (r % 3600) / 60)
	case r >= 60:
		when_text = fmt.tprintf("%d min", r / 60)
	case:
		when_text = fmt.tprintf("%d s", r)
	}
	if agents < 0 do return fmt.tprintf("Converting to the supervisor in %s; running agents (not countable) will be stopped", when_text)
	return fmt.tprintf("Converting to the supervisor in %s; %d agent%s will be stopped", when_text, agents, "" if agents == 1 else "s")
}

Gate_Status :: struct {
	state:       string `json:"state"`,
	message:     string `json:"message"`,
	force_at:    i64    `json:"force_at"`,
	remaining_s: i64    `json:"remaining_s"`,
	agents:      int    `json:"agents"`,
}

// ---- classification helpers --------------------------------------------------

// Credentials and keystore items are never copied into a backup or restored
// (engine §11.1, spec §6.6).
is_credential_name :: proc(name: string) -> bool {
	n := strings.to_lower(name, context.temp_allocator)
	return strings.has_prefix(n, TOKEN_FILE) || strings.has_prefix(n, "identity_key") || strings.has_prefix(n, "epoch_floor") || strings.contains(n, "keystore")
}

// convert_backup_files lists the files C3 copies (full paths, existing or not):
// the service definition, config, hub-url, profile, ports and the ctl wrapper.
// `bin/` and credentials are never in it.
convert_backup_files :: proc(host: Host, l: Layout) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	#partial switch l.backend {
	case .Schtasks:
		append(&out, windows_run_cmd_path(l), windows_launcher_path(l), pjoin(l.data_dir, "task.xml"))
	case:
		append(&out, l.service_file)
	}
	append(&out, pjoin(l.state_dir, CONFIG_FILE), pjoin(l.state_dir, HUB_URL_FILE), pjoin(l.state_dir, PROFILE_FILE), pjoin(l.state_dir, PORTS_FILE), ctl_wrapper_path(host, l))
	return out[:]
}

// Layout entries the transaction creates and rollback R4 removes, in removal order
// (instance.json first: a stray supervisor then refuses with ownership_mismatch).
CONVERT_CREATED_ENTRIES :: [?]string{"instance.json", "current", "current.json", "previous", "previous.json", "known-good.json", "launcher", "releases", "supervisor"}

// encode_instance_record renders <data>/instance.json (engine §3). `owner_json` is
// `{"uid":N}` or `{"sid":"S-1-..."}`; data_root and state_root are the textual
// layout_for strings (no realpath).
encode_instance_record :: proc(instance_id, service, hub_url, profile, owner_json, data_root, state_root: string, created_at: i64) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"schema":1,"instance_id":%s,"service_name":%s,"hub_url":%s,"profile":%s,"owner":%s,"data_root":%s,"state_root":%s,"layout":1,"created_at":%d}}`,
		json_quote(instance_id), json_quote(service), json_quote(hub_url), json_quote(profile), owner_json, json_quote(data_root), json_quote(state_root), created_at)
	strings.write_byte(&b, '\n')
	return strings.to_string(b)
}

json_quote :: proc(s: string) -> string {
	data, err := json.marshal(s, {spec = .JSON}, context.temp_allocator)
	if err != nil do return `""`
	return string(data)
}

// remove_created_layout deletes the entries a conversion created (R4). Missing entries
// are fine; the first failure is returned so the caller can retry/rename aside.
remove_created_layout :: proc(data_dir: string) -> (failed: string) {
	for name in CONVERT_CREATED_ENTRIES {
		p := pjoin(data_dir, name)
		if _, lerr := os.lstat(p, context.temp_allocator); lerr != nil do continue
		// A pointer symlink is unlinked, never followed.
		if os.remove(p) == nil do continue
		if err := os.remove_all(p); err != nil && os.exists(p) do return p
	}
	return ""
}
