package service

// Intents (docs/specs/bridge-supervisor-engine.md §10): the files senders drop into
// <data>/supervisor/intents/inbox/<op_id>.json (write .tmp, fsync, rename). This file parses
// and validates one intent; inbox.odin scans the directory and applies them.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "../engine"
import "../resolver"

INTENT_SCHEMA :: 1
INTENT_HORIZON_S :: 30 * 24 * 3600 // expires_at / created_at horizon (§10, §19)
MAX_INTENT_BYTES :: 64 * 1024
MAX_OP_ID_LEN :: 64 // fetch.prepare_release limit (download / staging dir names)

Intent :: struct {
	op_id:        string,
	instance_id:  string,
	action:       string,
	channel:      string, // set_channel only
	version:      string, // install_version / retry_failed: a tag "v0.5.75" (or bare SemVer)
	target_op_id: string, // cancel only, optional
	// set_auto_update only, optional (additive field, §8): the new value; absent = toggle.
	auto_update:  Maybe(bool),
	expires_at:   i64,
	created_at:   i64,
	actor:        string,
}

// Actions a sender may request (§10). `uninstall` is reserved (rejected not_implemented).
INTENT_ACTIONS :: []string {
	"check_now",
	"update_now",
	"install_version",
	"rollback_to_previous",
	"set_channel",
	"set_auto_update",
	"cancel",
	"retry_failed",
	"repair",
	"uninstall",
}

// Actions that install (they go through the full diagram and are user-started, D6).
is_installing :: proc(action: string) -> bool {
	switch action {
	case "update_now", "install_version", "rollback_to_previous", "repair":
		return true
	}
	return false
}

// Short configuration ops that never install (§10 coalescing: applied immediately).
is_config_action :: proc(action: string) -> bool {
	switch action {
	case "set_channel", "set_auto_update", "retry_failed":
		return true
	}
	return false
}

// valid_op_id: op ids are file names and journal tokens. `op_` + [A-Za-z0-9_-], bounded.
valid_op_id :: proc(s: string) -> bool {
	if !strings.has_prefix(s, "op_") || len(s) <= 3 || len(s) > MAX_OP_ID_LEN do return false
	for c in transmute([]byte)s {
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_', '-':
		case:
			return false
		}
	}
	return true
}

@(private)
valid_actor :: proc(s: string) -> bool {
	switch s {
	case "installer", "cli":
		return true
	case "timer", "supervisor":
		// Written only by the supervisor itself (§10); never accepted from the inbox.
		return false
	}
	for prefix in ([]string{"app:", "hub:"}) {
		if strings.has_prefix(s, prefix) {
			rest := s[len(prefix):]
			if rest == "" || len(rest) > 128 do return false
			for c in transmute([]byte)rest {
				if c <= ' ' || c == '"' || c == '\\' || c >= 0x7f do return false
			}
			return true
		}
	}
	return false
}

// tag_version: "v0.5.75" or "0.5.75" -> ("v0.5.75", "0.5.75"); ok = false when not SemVer.
tag_version :: proc(s: string, allocator := context.temp_allocator) -> (tag, version: string, ok: bool) {
	v := strings.trim_prefix(s, "v")
	if _, good := resolver.semver_parse(v); !good do return
	return strings.concatenate({"v", v}, allocator), strings.clone(v, allocator), true
}

Parse_Status :: enum {
	Ok, // parsed and has a usable op_id (may still be rejected by validate)
	Bad, // does not parse or has no usable op_id: renamed to bad-<ts>.json, not journaled (J31)
}

// parse_intent: strict JSON (Odin's default is JSON5; release-chain rule: .JSON). Strings are
// allocated with `allocator`. `schema_ok` = false when `is` is not 1 or a field has the wrong
// type (rejected `schema_error` once the op_id is known).
parse_intent :: proc(data: []byte, allocator := context.temp_allocator) -> (it: Intent, status: Parse_Status, schema_ok: bool) {
	status = .Bad
	if len(data) == 0 || len(data) > MAX_INTENT_BYTES do return
	v, err := json.parse(data, .JSON, true, allocator)
	if err != nil do return
	obj, is_obj := v.(json.Object)
	if !is_obj do return
	op, op_ok := obj["op_id"].(json.String)
	if !op_ok || !valid_op_id(string(op)) do return
	it.op_id = string(op)
	status = .Ok
	schema_ok = true

	str :: proc(obj: json.Object, key: string, out: ^string, ok: ^bool) {
		val, present := obj[key]
		if !present do return
		#partial switch s in val {
		case json.Null:
		case json.String:
			out^ = string(s)
		case:
			ok^ = false
		}
	}
	num :: proc(obj: json.Object, key: string, out: ^i64, ok: ^bool) {
		val, present := obj[key]
		if !present {
			ok^ = false
			return
		}
		#partial switch n in val {
		case json.Integer:
			out^ = i64(n)
		case:
			ok^ = false
		}
	}
	schema: i64
	num(obj, "is", &schema, &schema_ok)
	if schema != INTENT_SCHEMA do schema_ok = false
	str(obj, "instance_id", &it.instance_id, &schema_ok)
	str(obj, "action", &it.action, &schema_ok)
	str(obj, "channel", &it.channel, &schema_ok)
	str(obj, "version", &it.version, &schema_ok)
	str(obj, "target_op_id", &it.target_op_id, &schema_ok)
	str(obj, "actor", &it.actor, &schema_ok)
	if val, present := obj["auto_update"]; present {
		#partial switch b in val {
		case json.Boolean:
			it.auto_update = bool(b)
		case json.Null:
		case:
			schema_ok = false
		}
	}
	num(obj, "expires_at", &it.expires_at, &schema_ok)
	num(obj, "created_at", &it.created_at, &schema_ok)
	return
}

// validate_intent: the J31 rejection reason, "" = accepted. Order: schema, instance,
// action, actor, time window, action-specific fields.
validate_intent :: proc(it: Intent, schema_ok: bool, instance_id: string, now: i64) -> string {
	if !schema_ok do return "schema_error"
	if it.instance_id != instance_id do return "wrong_instance"
	known := false
	for a in INTENT_ACTIONS do if a == it.action do known = true
	if !known do return "unknown_action"
	if !valid_actor(it.actor) do return "bad_actor"
	if now - it.created_at > INTENT_HORIZON_S do return "stale_intent"
	if it.expires_at <= now do return "expired"
	if it.expires_at - now > INTENT_HORIZON_S do return "bad_expiry"
	switch it.action {
	case "uninstall":
		return "not_implemented"
	case "set_channel":
		if it.channel != "stable" && it.channel != "fast" do return "bad_channel"
	case "install_version", "retry_failed":
		if _, _, ok := tag_version(it.version); !ok do return "bad_version"
	case "cancel":
		if it.target_op_id != "" && !valid_op_id(it.target_op_id) do return "schema_error"
	}
	return ""
}

// journal_action: the action string a rejected line carries (any plain token, else "invalid").
journal_action :: proc(action: string) -> string {
	if action == "" || len(action) > 32 do return "invalid"
	for c in transmute([]byte)action {
		if !(c >= 'a' && c <= 'z') && c != '_' do return "invalid"
	}
	return action
}

// journal_actor: same for the actor (a rejected intent may carry anything).
journal_actor :: proc(actor: string) -> string {
	return actor if valid_actor(actor) || actor == "timer" || actor == "supervisor" else "invalid"
}

// ---- Senders ----------------------------------------------------------------------------

// encode_intent renders the canonical intent file (§10): the field order and spelling the
// parser accepts, only the fields the action uses.
encode_intent :: proc(it: Intent) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"is":1,"op_id":`)
	json_str(&b, it.op_id)
	strings.write_string(&b, `,"instance_id":`)
	json_str(&b, it.instance_id)
	strings.write_string(&b, `,"action":`)
	json_str(&b, it.action)
	if it.channel != "" {
		strings.write_string(&b, `,"channel":`)
		json_str(&b, it.channel)
	}
	if it.version != "" {
		strings.write_string(&b, `,"version":`)
		json_str(&b, it.version)
	}
	if v, ok := it.auto_update.?; ok {
		strings.write_string(&b, `,"auto_update":`)
		strings.write_string(&b, "true" if v else "false")
	}
	strings.write_string(&b, `,"actor":`)
	json_str(&b, it.actor)
	fmt.sbprintf(&b, `,"expires_at":%d,"created_at":%d}`, it.expires_at, it.created_at)
	return strings.to_string(b)
}

// submit_intent drops `it` into <data_root>/supervisor/intents/inbox/<op_id>.json
// (write .tmp, fsync, rename; engine.replace_durable). Idempotent per op_id: a second call
// replaces the not yet handled file with identical content, and one already handled is
// answered by the supervisor's op index (§10). Returns "" or the failure.
submit_intent :: proc(data_root: string, it: Intent) -> string {
	if !valid_op_id(it.op_id) do return "invalid op_id"
	dir := engine.join(data_root, "supervisor", INBOX_DIR)
	if err := os.make_directory_all(dir, engine.PRIVATE_DIR_PERMS); err != nil && !os.is_dir(dir) {
		return fmt.tprintf("cannot create %s: %v", dir, err)
	}
	data := encode_intent(it)
	if err := engine.replace_durable(nil, engine.DEFAULT_RETRY, engine.join(dir, strings.concatenate({it.op_id, ".json"}, context.temp_allocator)), transmute([]byte)data, it.op_id, engine.PRIVATE_FILE_PERMS); err != nil {
		return fmt.tprintf("cannot write intent: %s", engine.error_detail(err))
	}
	return ""
}
