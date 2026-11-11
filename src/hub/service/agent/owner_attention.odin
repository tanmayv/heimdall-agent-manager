package agent

import "base:runtime"
import "core:encoding/json"
import "core:strings"
import "core:sync"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import events "odin_test:hub/service/events"

// Owner-chain attention: tasks on Bridge-owned chains that need the user
// (blocked on the user/human, agent_not_running, review awaiting the user's
// approval). Like agent blockers, NOTHING IS PERSISTED: each owner Bridge
// sends an `owner_attention` snapshot {items:[{chain_id, task_id, attention,
// badge, state, attempt}]} that replaces its entry wholesale; a disconnected
// Bridge's entry is dropped and comes back with its connect snapshot. The
// snapshot carries ids and flags only (no titles, reasons or other task
// content). The card service merges it into GET /api/v1/attention as kind
// owner_task at read time.

OWNER_ATTENTION_KIND :: "owner_task"
// The attention_changed hint kind: the deck treats owner tasks as tasks.
OWNER_ATTENTION_EVENT_KIND :: "task"
OWNER_ATTENTION_MAX_ITEMS :: 200
OWNER_ATTENTION_ID_MAX :: 128

Owner_Attention_Item :: struct {
	chain_id, task_id, attention, badge, state, attempt: string,
	since: string, // when the Hub first saw this item in this attention (RFC 3339)
}

Owner_Attention_Entry :: struct {
	owner_user_id: string,
	items:         [dynamic]Owner_Attention_Item,
}

Owner_Attention_Store :: struct {
	mutex:   sync.Mutex,
	entries: map[string]Owner_Attention_Entry, // bridge_id -> its latest snapshot
}

@(private = "file")
owner_attention_allocator :: proc() -> runtime.Allocator {
	return runtime.heap_allocator()
}

@(private = "file")
owner_attention_valid_id :: proc(id: string) -> bool {
	if id == "" || len(id) > OWNER_ATTENTION_ID_MAX do return false
	for ch in id {
		ok := (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_' || ch == '-' || ch == '.' || ch == ':'
		if !ok do return false
	}
	return true
}

@(private = "file")
owner_attention_valid_item :: proc(it: Owner_Attention_Item) -> bool {
	if !owner_attention_valid_id(it.chain_id) || !owner_attention_valid_id(it.task_id) do return false
	switch it.attention {
	case "blocked": if it.badge != "question" && it.badge != "agent_not_running" do return false
	case "review":  if it.badge != "review" do return false
	case: return false
	}
	switch it.state {
	case "ready", "in_review", "merge_pending", "merge_blocked", "done":
	case: return false
	}
	if it.attempt == "" || len(it.attempt) > 10 do return false
	for ch in it.attempt do if ch < '0' || ch > '9' do return false
	return true
}

@(private = "file")
owner_attention_entry_destroy :: proc(e: ^Owner_Attention_Entry) {
	context.allocator = owner_attention_allocator()
	for it in e.items {
		delete(it.chain_id); delete(it.task_id); delete(it.attention); delete(it.badge); delete(it.state); delete(it.attempt); delete(it.since)
	}
	delete(e.items)
	delete(e.owner_user_id)
}

// apply_bridge_owner_attention replaces the authenticated Bridge's owner-chain
// attention snapshot. Only chains the owner registry routes to THIS Bridge are
// kept (a Bridge speaks only for the chains it owns). Returns whether the
// snapshot was accepted.
apply_bridge_owner_attention :: proc(service: ^Agent_Service, bridge_id, text: string) -> bool {
	if service == nil || bridge_id == "" || len(text) > 256 * 1024 do return false
	if service.bridges == nil || service.taskchains == nil || service.taskchains.owner_registry_routes == nil do return false
	value, err := json.parse_string(text, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	if err != .None do return false
	root, is_obj := value.(json.Object)
	if !is_obj do return false
	bridge, found, _ := iface.bridge_get_bridge(service.bridges, bridge_id)
	if !found do return false
	owner := strings.clone(string(bridge.owner_user_id), context.temp_allocator)
	domain.bridge_destroy(&bridge)
	if owner == "" do return false

	saved := context.allocator
	context.allocator = context.temp_allocator
	routes, rerr := service.taskchains.owner_registry_routes(service.taskchains.ctx, owner, "")
	context.allocator = saved
	if rerr.code != .None do return false
	owned := make(map[string]bool, 16, context.temp_allocator)
	for r in routes do if r.owner_bridge_id == bridge_id do owned[r.chain_id] = true

	text_of :: proc(obj: json.Object, key: string) -> string {
		s, _ := obj[key].(json.String)
		return string(s)
	}
	fresh := make([dynamic]Owner_Attention_Item, context.temp_allocator)
	if arr, is_arr := root["items"].(json.Array); is_arr {
		for v in arr {
			if len(fresh) >= OWNER_ATTENTION_MAX_ITEMS do break
			obj, ok := v.(json.Object)
			if !ok do continue
			it := Owner_Attention_Item{
				chain_id = text_of(obj, "chain_id"), task_id = text_of(obj, "task_id"),
				attention = text_of(obj, "attention"), badge = text_of(obj, "badge"),
				state = text_of(obj, "state"), attempt = text_of(obj, "attempt"),
			}
			if !owner_attention_valid_item(it) || !owned[it.chain_id] do continue
			append(&fresh, it)
		}
	}

	now := platform.clock_now(service.clock)
	sync.mutex_lock(&service.owner_attention.mutex)
	store := &service.owner_attention
	if store.entries == nil do store.entries = make(map[string]Owner_Attention_Entry, 8, owner_attention_allocator())
	old, had := store.entries[bridge_id]
	changed := (len(old.items) if had else 0) != len(fresh)
	fresh_count, fresh_chain := 0, ""
	next := make([dynamic]Owner_Attention_Item, 0, len(fresh), owner_attention_allocator())
	for it in fresh {
		since := now
		matched := false
		if had {
			for o in old.items {
				if o.chain_id != it.chain_id || o.task_id != it.task_id do continue
				if o.attention == it.attention && o.badge == it.badge && o.attempt == it.attempt {
					since = o.since
					matched = true
				}
				break
			}
		}
		if !matched {
			changed = true
			if fresh_count == 0 do fresh_chain = strings.clone(it.chain_id, context.temp_allocator)
			fresh_count += 1
		}
		a := owner_attention_allocator()
		append(&next, Owner_Attention_Item{
			chain_id = strings.clone(it.chain_id, a), task_id = strings.clone(it.task_id, a),
			attention = strings.clone(it.attention, a), badge = strings.clone(it.badge, a),
			state = strings.clone(it.state, a), attempt = strings.clone(it.attempt, a),
			since = strings.clone(since, a),
		})
	}
	if had {
		key, _ := delete_key(&store.entries, bridge_id)
		owner_attention_entry_destroy(&old)
		delete(key, owner_attention_allocator())
	}
	if len(next) > 0 {
		store.entries[strings.clone(bridge_id, owner_attention_allocator())] = Owner_Attention_Entry{
			owner_user_id = strings.clone(owner, owner_attention_allocator()),
			items = next,
		}
	} else {
		delete(next)
	}
	sync.mutex_unlock(&service.owner_attention.mutex)
	if changed do owner_attention_changed(service, owner)
	// Notify only for items that newly need the user, never for a resolution.
	if fresh_count > 0 && service.owner_attention_hook != nil do service.owner_attention_hook(service.owner_attention_hook_ctx, owner, fresh_count, fresh_chain)
	return true
}

@(private = "file")
owner_attention_changed :: proc(service: ^Agent_Service, owner: string) {
	if service.blockers.attention != nil do events.attention_debouncer_note(service.blockers.attention, owner, OWNER_ATTENTION_EVENT_KIND)
}

// clear_bridge_owner_attention drops a Bridge's snapshot (it went offline).
clear_bridge_owner_attention :: proc(service: ^Agent_Service, bridge_id: string) -> bool {
	if service == nil || bridge_id == "" do return false
	sync.mutex_lock(&service.owner_attention.mutex)
	entry, had := service.owner_attention.entries[bridge_id]
	owner := ""
	if had {
		owner = strings.clone(entry.owner_user_id, context.temp_allocator)
		key, _ := delete_key(&service.owner_attention.entries, bridge_id)
		owner_attention_entry_destroy(&entry)
		delete(key, owner_attention_allocator())
	}
	sync.mutex_unlock(&service.owner_attention.mutex)
	if had do owner_attention_changed(service, owner)
	return had
}

// list_owner_attention copies every owner-chain attention item of the owner
// into the temp allocator, ordered by Bridge snapshot order. Read-time only.
list_owner_attention :: proc(service: ^Agent_Service, owner_user_id: string) -> []Owner_Attention_Item {
	if service == nil || owner_user_id == "" do return nil
	out := make([dynamic]Owner_Attention_Item, context.temp_allocator)
	a := context.temp_allocator
	sync.mutex_lock(&service.owner_attention.mutex)
	for _, e in service.owner_attention.entries {
		if e.owner_user_id != owner_user_id do continue
		for it in e.items {
			append(&out, Owner_Attention_Item{
				chain_id = strings.clone(it.chain_id, a), task_id = strings.clone(it.task_id, a),
				attention = strings.clone(it.attention, a), badge = strings.clone(it.badge, a),
				state = strings.clone(it.state, a), attempt = strings.clone(it.attempt, a),
				since = strings.clone(it.since, a),
			})
		}
	}
	sync.mutex_unlock(&service.owner_attention.mutex)
	return out[:]
}
