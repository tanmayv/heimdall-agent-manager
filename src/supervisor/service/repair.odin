package service

// Offline repair (spec §16, J29, D9):
//
//   ham-supervisor repair --instance-root <data> --state-root <state>
//                         --bundle <archive> --manifest <m> --signature <sig> [--op-id <op>]
//
// Run by `ham-bridge setup` with the service stopped and `.install.lock` held. Takes
// `engine.lock` (exit 6 when a live supervisor holds it: setup then queues a `repair`
// intent instead), runs J0, ends an op a crash left before the switch, verifies the bundle
// exactly as §14 (same manifest rules, pinned keys, archive safety, OS signatures,
// preflight), unpacks a tree (a `-r<n>` name when a damaged tree of the same release is
// live) and switches to it:
//
//   requested -> verifying -> verified -> activating/stopped -> snapshot -> pointers_begin
//   -> previous := current (if valid, else the new tree) -> current := new -> pointers_done
//   -> handover; exit 0
//
// It never writes known-good: the service's supervisor of the new tree finds `activating`
// with `current` = its tree and runs probation (J15/J16), committing or rolling back.
//
// Exit codes: 0 switched; 1 failed (journaled `failed <code>`; nothing switched); 2 usage;
// 6 busy (lock held); 78 refused (ownership, orphan survivor).

import "core:fmt"
import "core:os"
import "core:time"
import lc "../../launcher/core"
import "../engine"
import "../fetch"
import "../resolver"

REPAIR_EXIT_OK :: 0
REPAIR_EXIT_FAILED :: 1
REPAIR_EXIT_USAGE :: 2
REPAIR_EXIT_BUSY :: 6

Repair_Options :: struct {
	instance_root:  string,
	state_root:     string,
	bundle:         string,
	manifest:       string,
	signature:      string,
	op_id:          string, // "" = generated
	actor:          string, // "installer"
	key_pins:       []fetch.Public_Key,
	os_policy:      fetch.Os_Signature_Policy,
	log:            proc(msg: string),
}

// repair runs the offline repair; returns the process exit code.
repair :: proc(ro: Repair_Options) -> int {
	rlog :: proc(ro: Repair_Options, format: string, args: ..any) {
		if ro.log != nil do ro.log(fmt.tprintf(format, ..args))
	}
	rec, rreason := lc.read_instance_record(ro.instance_root, context.temp_allocator)
	if rreason != "" {
		rlog(ro, "refused: %s", rreason)
		return EXIT_REFUSE
	}
	if creason := lc.check_instance_record(rec, ro.instance_root, ro.state_root); creason != "" {
		rlog(ro, "refused: %s", creason)
		return EXIT_REFUSE
	}

	// The host does J0 only: the service is stopped, nothing is started here.
	h: Host_Ctx
	host_init(&h, ro.instance_root, ro.state_root, rec.instance_id)
	defer host_destroy(&h)
	eh := engine_host(&h)
	eh.start_runtime = proc(u: rawptr, tree: string) -> bool {return true}
	eh.stop_children = proc(u: rawptr, tree: string) -> bool {return true}

	e: engine.Engine
	if engine.open(&e, engine.default_config(ro.instance_root, ro.state_root), eh) != .Run {
		rlog(ro, "refused: %s", e.refuse_reason)
		if e.refuse_reason == "lock_held" do return REPAIR_EXIT_BUSY
		return EXIT_REFUSE
	}
	defer engine.close(&e)

	C := engine.current_valid(&e)
	// J29: an op a crash left before the switch ends `failed interrupted_before_switch`; an
	// op past the switch is superseded by this repair (the instance could not start).
	for l in engine.non_terminal_ops(&e) {
		t := terminal(l, "failed", "interrupted_before_switch")
		past := l.state == "probation" || l.state == "rolling_back" || (l.state == "activating" && (l.sub == "pointers_begin" || l.sub == "pointers_done" || l.sub == "handover"))
		if past do t = terminal(l, "failed", "superseded_by_repair")
		if err := engine.journal(&e, t); err != nil {
			rlog(ro, "journal: %s", engine.error_detail(err))
			return REPAIR_EXIT_FAILED
		}
	}

	op_id := ro.op_id if ro.op_id != "" else fmt.tprintf("op_repair_%d_%d", time.time_to_unix(time.now()), e.last_seq + 1)
	if !valid_op_id(op_id) {
		rlog(ro, "invalid op id %q", op_id)
		return REPAIR_EXIT_USAGE
	}
	actor := ro.actor if ro.actor != "" else "installer"
	op := engine.Line{op_id = op_id, action = "repair", actor = actor, state = "requested"}
	put_ :: proc(e: ^engine.Engine, l: engine.Line) -> bool {return engine.journal(e, l) == nil}
	if !put_(&e, op) do return REPAIR_EXIT_FAILED
	op = next_state(op, "verifying")
	if !put_(&e, op) do return REPAIR_EXIT_FAILED

	// §14 on local files; eligibility as a `repair` (rule 1 skipped, rule 2 still applies).
	from, from_ok := engine.ref_of_tree(&e, C)
	Elig :: struct {
		installed: resolver.Release_Id,
		e:         ^engine.Engine,
		code:      string,
	}
	el := Elig{installed = {version = from.version, sha256 = from.sha256}, e = &e}
	live := make([dynamic]string, context.temp_allocator)
	for t in ([]string{engine.read_pointer_raw(&e, lc.POINTER_CURRENT), engine.read_pointer_raw(&e, lc.POINTER_PREVIOUS), engine.read_known_good_raw(&e)}) {
		if t != "" do append(&live, t)
	}
	in_ := fetch.default_prepare_input()
	in_.instance_root = ro.instance_root
	in_.op_id = op_id
	in_.local = {manifest_path = ro.manifest, signature_path = ro.signature, bundle_path = ro.bundle}
	in_.verify.now = time.time_to_unix(time.now())
	in_.verify.check_expiry = true
	in_.verify.pins = ro.key_pins
	in_.os_policy = ro.os_policy
	in_.live = live[:]
	in_.eligible_user = &el
	in_.eligible = proc(user: rawptr, m: ^fetch.Manifest) -> fetch.Error {
		el := (^Elig)(user)
		pins := make([dynamic]resolver.Pin, context.temp_allocator)
		for p in engine.read_pins(el.e) do append(&pins, resolver.Pin{version = p.version, sha256 = p.sha256})
		installed := el.installed
		if installed.version == "" do installed.version = "0.0.0" // nothing valid installed
		offer := resolver.Offer{id = {version = m.version, sha256 = m.sha256}, min_engine = int(m.min_engine), min_launcher_abi = int(m.min_launcher_abi)}
		v, code := resolver.check_eligibility(.Repair, installed, offer, pins[:], engine.ENGINE_VERSION, lc.ABI)
		if v == .Proceed do return nil
		el.code = code
		return fetch.Failure{code = .None, detail = code}
	}
	// The manifest's tag is not known before verification: take it from the manifest.
	if data, err := os.read_entire_file(ro.manifest, context.temp_allocator); err == nil {
		if tag, ok := manifest_tag(data); ok do in_.tag = tag
	}
	prepared, perr := fetch.prepare_release(in_, context.temp_allocator)
	if perr != nil {
		code := el.code if el.code != "" else fetch.code_name(fetch.error_code(perr))
		rlog(ro, "verify failed: %s (%s)", code, fetch.error_detail(perr))
		_ = engine.journal(&e, terminal(op, "failed", code))
		return REPAIR_EXIT_FAILED
	}
	m := prepared.manifest
	to := engine.Ref{version = m.version, sha256 = m.sha256, tree = prepared.tree}
	if to.tree == C {
		// The bundle is the intact running tree: nothing to switch; the service starts it.
		_ = engine.journal(&e, terminal(op, "noop", "", "up_to_date"))
		if lt, ok := e.last_settled.?; ok && lt.state == "rollback_failed" && (lt.from.tree == C || lt.to.tree == C) {
			// J25 holds: only a real pointer switch ends rollback_failed, so say so instead
			// of letting "exit 0" read as "repaired" (T13b review note, T15).
			rlog(ro, "noop up_to_date: %s is intact and already current; the instance is STILL in rollback_failed (op %s) and will not start its runtime. Repair with a bundle of another release, or of this release once its tree is damaged, to switch and clear it.", C, lt.op_id)
		} else {
			rlog(ro, "noop up_to_date: %s is intact and already current; nothing to repair", C)
		}
		return REPAIR_EXIT_OK
	}
	op = next_state(op, "verified")
	op.to = to
	if from_ok do op.from = from
	if !put_(&e, op) do return REPAIR_EXIT_FAILED

	op.state = "activating"
	step :: proc(e: ^engine.Engine, op: ^engine.Line, sub: string) -> bool {
		op.sub = sub
		return engine.journal(e, op^) == nil
	}
	if !step(&e, &op, "stopped") do return REPAIR_EXIT_FAILED // J0 reap only: service stopped
	if !step(&e, &op, "snapshot") do return REPAIR_EXIT_FAILED
	if from_ok {
		if serr := engine.take_snapshot(&e, op_id, C, false); serr != nil do op.note = "snapshot_skipped"
	} else {
		op.note = "snapshot_skipped"
	}
	if !step(&e, &op, "pointers_begin") do return REPAIR_EXIT_FAILED
	prev := C if C != "" else to.tree
	if err := engine.write_pointer(&e, lc.POINTER_PREVIOUS, prev, op_id); err != nil {
		_ = engine.journal(&e, terminal(op, "failed", "pointer_write"))
		return REPAIR_EXIT_FAILED
	}
	if err := engine.write_pointer(&e, lc.POINTER_CURRENT, to.tree, op_id); err != nil {
		// `current` may or may not have landed; the next start decides (J14).
		rlog(ro, "current pointer: %s", engine.error_detail(err))
		return REPAIR_EXIT_FAILED
	}
	if !step(&e, &op, "pointers_done") do return REPAIR_EXIT_FAILED
	if !step(&e, &op, "handover") do return REPAIR_EXIT_FAILED
	rlog(ro, "repaired: current = %s (op %s); start the service to prove it", to.tree, op_id)
	return REPAIR_EXIT_OK
}

// manifest_tag: the `tag` member of a manifest (verified later; used only to tell
// prepare_release which tag to expect).
@(private)
manifest_tag :: proc(data: []byte) -> (string, bool) {
	return json_string_field(data, "tag")
}
