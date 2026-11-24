package actions

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:strconv"
import iface "odin_test:hub/repository/iface"
import "core:strings"
import domain "odin_test:hub/domain"
import nats "odin_test:lib/nats"

event_kind := Trigger_Kind{kind="event",compile=event_compile}

event_compile :: proc(owner, action_id, trigger_id: string, config: json.Object, allocator: mem.Allocator) -> (Match_Spec,domain.Domain_Error) {
	if !config_keys_valid(config,{"event_type","chain_id","data"}) do return {},detail_error("invalid_config")
	event_type,valid:=config_string(config,"event_type")
	if !valid do return {},detail_error("unknown_event_type")
	descriptor:^Event_Descriptor
	for &entry in EVENT_DESCRIPTORS do if entry.event_type==event_type {descriptor=&entry; break}
	if descriptor==nil do return {},detail_error("unknown_event_type")
	chain_id,chain_ok:=config_string(config,"chain_id")
	if !chain_ok || (chain_id!="" && !nats.subject_token(chain_id)) do return {},detail_error("unknown_chain")
	if !nats.subject_token(owner) do return {},detail_error("invalid_owner")
	data:json.Object
	if raw,present:=config["data"]; present {
		var_ok:bool
		data,var_ok=raw.(json.Object)
		if !var_ok do return {},detail_error("invalid_data_filter")
		for key,value in data {
			_,string_ok:=value.(string)
			allowed:=false
			for entry in descriptor.data_keys do if entry.key==key {allowed=true; break}
			if !allowed || !string_ok do return {},detail_error("invalid_data_filter")
		}
	}
	encoded:=strings.clone("{}",allocator)
	if data!=nil {
		delete(encoded,allocator)
		bytes,err:=json.marshal(data,allocator=allocator)
		if err!=nil do return {},detail_error("invalid_data_filter")
		encoded=string(bytes)
	}
	return {event_type=strings.clone(event_type,allocator),subject_filter=strings.clone(fmt.tprintf("ev.%s.chain.%s.%s",owner,chain_id if chain_id!="" else "*",event_type[len("chain."):]),allocator),data_filter_json=encoded},{}
}

Data_Key :: struct { key: string, values: []string } // values empty = free text
Preset   :: struct { id, label: string, data_json: string }
Event_Descriptor :: struct { event_type, label, scope, class: string, data_keys: []Data_Key, presets: []Preset,
 // The occurrence callback borrows inputs and performs one indexed repository
 // lookup and no network I/O. Returned reasons are static strings.
 still_valid: proc(ctx: ^iface.Repositories, run: domain.Action_Run) -> (ok: bool, reason: string),
}

EVENT_DESCRIPTORS := [?]Event_Descriptor{
	{event_type = "chain.state", class = "state", label = "Task chain state changed", scope = "chain",
	 data_keys = {{key = "state", values = {"active", "completed", "archived"}}},
	 presets   = {{id = "chain_completed", label = "Task chain completed", data_json = `{"state":"completed"}`}}},
	{event_type = "chain.work_finished", class = "occurrence", label = "Task chain work finished", scope = "chain", still_valid=chain_work_finished_still_valid,
	 data_keys = {{key = "outcome", values = {}}}, presets = {}},
}

event_descriptor_find :: proc(event_type: string) -> ^Event_Descriptor {
 for &entry in EVENT_DESCRIPTORS do if entry.event_type == event_type do return &entry
 return nil
}
entity_settle_key :: proc(msg: Event_View) -> string {
	entity, _ := msg.envelope["entity"].(json.Object)
	kind, _ := entity["kind"].(string)
	id, _ := entity["id"].(string)
	if kind == "" || id == "" do return ""
	return fmt.tprintf("%s:%s", kind, id)
}
// The router calls this only for delayed runs, before planning has side effects.
event_still_valid :: proc(repos: ^iface.Repositories, run: domain.Action_Run) -> (bool, string) {
	value: json.Value
	if json.unmarshal(transmute([]u8)run.event_params_json, &value, allocator=context.temp_allocator) != nil do return false, "superseded"
	defer json.destroy_value(value, allocator=context.temp_allocator)
	params, _ := value.(json.Object)
	class, _ := params["class"].(string)
	// Persisted snapshots can predate v2. The server's descriptor determines
	// known event classes; an absent or incorrect snapshot class cannot bypass validity.
	descriptor := event_descriptor_find(run.event_type)
	if descriptor != nil do class = descriptor.class
	if class == "state" {
		entity, _ := params["entity"].(json.Object)
		kind, _ := entity["kind"].(string)
		id, _ := entity["id"].(string)
		if kind == "" || id == "" || run.event_id == "" do return false, "superseded"
		repo := &repos.event_outbox
		valid, err := repo.state_head_matches(repo.ctx, string(run.owner_user_id), kind, id, run.event_type, run.event_id)
		if err.code != .None do return false, "validity_unavailable"
		if !valid do return false, "superseded"
		return true, ""
	}
	if descriptor != nil && descriptor.still_valid != nil do return descriptor.still_valid(repos, run)
	return true, ""
}
chain_work_finished_still_valid :: proc(repos: ^iface.Repositories, run: domain.Action_Run) -> (bool, string) {
 arena: virtual.Arena
 if virtual.arena_init_growing(&arena) != nil do return false, "validity_unavailable"
 defer virtual.arena_destroy(&arena)
 context.allocator = virtual.arena_allocator(&arena)
 context.temp_allocator = context.allocator
 value: json.Value
 if json.unmarshal(transmute([]u8)run.event_params_json, &value) != nil do return false, "superseded"
 params, _ := value.(json.Object)
 entity, _ := params["entity"].(json.Object)
 id, _ := entity["id"].(string)
 data, _ := params["data"].(json.Object)
 if id == "" do return false, "superseded"
 chain, found, err := iface.taskchain_get_chain(&repos.taskchains, domain.Task_Chain_ID(id))
 if err.code != .None do return false, "validity_unavailable"
 if !found || chain.owner_user_id != run.owner_user_id do return false, "superseded"
 // The catalog emits a JSON integer. Retain strings for matcher run snapshots,
 // but never coerce floats or missing values into a matching revision.
 rev: i64
 valid: bool
 #partial switch value in data["work_revision"] {
 case json.Integer:
  rev = i64(value)
  valid = true
 case string:
  rev, valid = strconv.parse_i64(value)
 case:
  return false, "superseded"
 }
 if !valid || rev != chain.work_revision do return false, "superseded"
 return true, ""
}
