package main

// Predecessor bridges (T4b, iss_18eab23e79e956c8).
//
// A same-account re-enrollment onto a NEW bridge id (the old one was revoked, or the
// approver chose "new bridge" instead of reusing it) moves this profile from bridge
// X to bridge Y. Nothing of this profile can run as X again, so X's local secrets
// (vault keyring, identity record, epoch floor, per-scope directory, its default
// credential) are wiped, but only after Y's enrollment succeeded: a failed
// enrollment leaves X untouched, and the live bridge is never wiped.
//
// X is first recorded in <profile state dir>/predecessor-bridges.json, then wiped;
// the entry goes once the wipe succeeded. What stays recorded (an enrollment whose
// commit the restarted service resolves, a wipe that failed, a predecessor under
// another hub) is swept again by the next enrollment or startup recovery, and
// `uninstall --purge` wipes it too.
//
// The other-account replace (enroll_account_replace.odin) wipes the old bridge
// BEFORE writing the new one, on purpose (it also revokes it); it is not recorded.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import bridgesvc "odin_test:lib/bridgesvc"

BRIDGE_PREDECESSORS_FILE :: "predecessor-bridges.json"

Bridge_Predecessor :: struct {
	bridge_id:  string `json:"bridge_id"`,
	hub:        string `json:"hub"`,
	// The predecessor's credential file when it is not inside its per-scope
	// directory and not the live bridge's file ("" otherwise).
	token_file: string `json:"token_file,omitempty"`,
}

Bridge_Predecessor_Record :: struct {
	v:       int                  `json:"v"`,
	bridges: []Bridge_Predecessor `json:"bridges"`,
}

// bridge_enroll_predecessor_to_wipe is the pure policy: after an enrollment that the
// account decision let through (account_ok) without replacing another account, a
// previous bridge id of this profile that differs from the newly enrolled one is a
// predecessor. The same id is a re-enrollment (nothing to wipe); an other-account
// replace already wiped it; a refusal wrote nothing.
bridge_enroll_predecessor_to_wipe :: proc(old_bridge_id, new_bridge_id: string, account_ok, replaced: bool) -> bool {
	old_id, new_id := strings.trim_space(old_bridge_id), strings.trim_space(new_bridge_id)
	if !account_ok || replaced do return false
	return old_id != "" && new_id != "" && old_id != new_id
}

// bridge_predecessors_path: next to the profile's config ("" without one).
bridge_predecessors_path :: proc(config_path: string) -> string {
	dir := bridge_reenroll_state_dir(config_path)
	if dir == "" do return ""
	return bridgesvc.pjoin(dir, BRIDGE_PREDECESSORS_FILE)
}

// bridge_predecessors_read returns the recorded predecessors. Temp-allocated.
bridge_predecessors_read :: proc(config_path: string) -> []Bridge_Predecessor {
	path := bridge_predecessors_path(config_path)
	if path == "" do return nil
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return nil
	rec: Bridge_Predecessor_Record
	if json.unmarshal_string(string(data), &rec, .JSON, context.temp_allocator) != nil do return nil
	out := make([dynamic]Bridge_Predecessor, 0, len(rec.bridges), context.temp_allocator)
	for p in rec.bridges {
		if keystore_bridge_id_is_enrolled(strings.trim_space(p.bridge_id)) do append(&out, p)
	}
	return out[:]
}

// bridge_predecessors_write replaces the record (owner-only, temp + rename); an
// empty list removes it.
bridge_predecessors_write :: proc(config_path: string, list: []Bridge_Predecessor) -> bool {
	path := bridge_predecessors_path(config_path)
	if path == "" do return false
	if len(list) == 0 {
		_ = os.remove(path)
		return !os.exists(path)
	}
	data, merr := json.marshal(Bridge_Predecessor_Record{v = 1, bridges = list}, allocator = context.temp_allocator)
	if merr != nil do return false
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	if os.write_entire_file_from_string(tmp, string(data), {.Read_User, .Write_User}) != nil do return false
	return os.rename(tmp, path) == nil
}

// bridge_predecessor_record adds p (once per bridge id and hub).
bridge_predecessor_record :: proc(config_path: string, p: Bridge_Predecessor) -> bool {
	if !keystore_bridge_id_is_enrolled(strings.trim_space(p.bridge_id)) do return false
	list := make([dynamic]Bridge_Predecessor, context.temp_allocator)
	for q in bridge_predecessors_read(config_path) {
		if q.bridge_id == p.bridge_id && bridge_predecessor_same_hub(q.hub, p.hub) do continue
		append(&list, q)
	}
	append(&list, p)
	return bridge_predecessors_write(config_path, list[:])
}

// bridge_predecessor_forget drops bridge_id from the record (an enrollment that
// failed after recording it: that bridge is still this profile's live one).
bridge_predecessor_forget :: proc(config_path, bridge_id: string) {
	list := make([dynamic]Bridge_Predecessor, context.temp_allocator)
	recorded := bridge_predecessors_read(config_path)
	for q in recorded do if q.bridge_id != bridge_id do append(&list, q)
	if len(list) != len(recorded) do _ = bridge_predecessors_write(config_path, list[:])
}

@(private = "file")
bridge_predecessor_same_hub :: proc(a, b: string) -> bool {
	ca, aok := bridge_hub_canonical_base(a, context.temp_allocator)
	cb, bok := bridge_hub_canonical_base(b, context.temp_allocator)
	return aok && bok && ca == cb
}

// bridge_enroll_predecessor_for builds the record of old_bridge_id (enrolled with
// old_hub, "" = the hub enrolling now). Its credential file is kept only when it is
// neither the live one (an explicit --bridge-token-file is shared by both) nor
// inside its per-scope directory, which the wipe removes as a whole.
bridge_enroll_predecessor_for :: proc(args: []string, api_base, old_hub, old_bridge_id, live_token_file: string) -> Bridge_Predecessor {
	hub := old_hub if strings.trim_space(old_hub) != "" else api_base
	p := Bridge_Predecessor{bridge_id = strings.trim_space(old_bridge_id), hub = strings.clone(hub, context.temp_allocator)}
	old_token := bridge_enroll_token_file_from_args(args, hub, p.bridge_id, context.temp_allocator)
	if old_token != "" && old_token != live_token_file && old_token != bridge_enroll_default_credential_path(hub, p.bridge_id, context.temp_allocator) {
		p.token_file = old_token
	}
	return p
}

// bridge_predecessors_sweep wipes the recorded predecessors of this profile, never
// live_bridge_id (an entry naming it is dropped: that bridge is live again) nor
// live_token_file. Only predecessors of the hub this process is bound to are wiped
// (keystore items are scoped per hub); the others stay recorded for the uninstall.
// The in-memory vault key (the live bridge's) is left alone. Returns what could not
// be removed; those entries stay recorded.
bridge_predecessors_sweep :: proc(config_path, live_bridge_id, live_token_file: string) -> (wiped, failed: [dynamic]string) {
	wiped = make([dynamic]string, context.temp_allocator)
	failed = make([dynamic]string, context.temp_allocator)
	// Without knowing the live bridge nothing is wiped: it might be one of them.
	if !keystore_bridge_id_is_enrolled(strings.trim_space(live_bridge_id)) do return
	recorded := bridge_predecessors_read(config_path)
	if len(recorded) == 0 do return
	bound := bridge_keystore_hub()
	keep := make([dynamic]Bridge_Predecessor, context.temp_allocator)
	for p in recorded {
		id := strings.trim_space(p.bridge_id)
		if id == strings.trim_space(live_bridge_id) do continue
		if bound == "" || !bridge_predecessor_same_hub(p.hub, bound) {
			append(&keep, p)
			continue
		}
		token_file := p.token_file if p.token_file != live_token_file else ""
		// config_path "" here: the profile's marker and re-enroll journal belong to
		// the live bridge now.
		left := bridge_enroll_wipe_bridge("", token_file, id, keep_in_memory_key = true)
		if len(left) > 0 {
			append(&failed, ..left[:])
			append(&keep, p)
			continue
		}
		append(&wiped, id)
	}
	if !bridge_predecessors_write(config_path, keep[:]) do append(&failed, bridge_predecessors_path(config_path))
	return
}

// bridge_enroll_sweep_predecessors_report runs the sweep after a successful
// enrollment and says what it did. Never fails the enrollment.
bridge_enroll_sweep_predecessors_report :: proc(config_path, live_bridge_id, live_token_file: string) {
	wiped, failed := bridge_predecessors_sweep(config_path, live_bridge_id, live_token_file)
	if len(wiped) > 0 {
		fmt.printfln("  deleted the previous bridge's vault key, identity and credential from this machine (%s)", strings.join(wiped[:], ", ", context.temp_allocator))
	}
	if len(failed) > 0 {
		fmt.eprintfln("  could not delete everything of the previous bridge (%s); `ham-bridge uninstall --purge` removes it", strings.join(failed[:], ", ", context.temp_allocator))
	}
}
