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
 return event_compile_limits(owner,action_id,trigger_id,config,FILTER_DEFAULT_LIMITS,allocator)
}
event_compile_limits :: proc(owner, action_id, trigger_id: string, config: json.Object, limits:Filter_Limits, allocator: mem.Allocator) -> (Match_Spec,domain.Domain_Error) {
 if !config_keys_valid(config,{"event_type","entity_id","filter"}) do return {},detail_error("invalid_config")
 event_type,valid:=config_string(config,"event_type")
 descriptor:=event_descriptor_find(event_type)
 if !valid || descriptor==nil do return {},detail_error("unknown_event_type")
 entity_id,entity_ok:=config_string(config,"entity_id")
 if !entity_ok || (entity_id!="" && !nats.subject_token(entity_id)) do return {},detail_error("unknown_entity")
 if !nats.subject_token(owner) do return {},detail_error("invalid_owner")
 raw,present:=config["filter"]
 if !present do raw=json.Object{}
 tree,e:=filter_compile(raw,descriptor,limits,allocator)
 if e.reason!="" do return {},filter_error(e)
 defer filter_destroy(&tree,allocator)
 root,_:=raw.(json.Object)
 if _,check:=root["field"];check {
  wrapper:=make(json.Object,context.temp_allocator)
  children:=make(json.Array,1,context.temp_allocator)
  children[0]=raw
  wrapper["all"]=children
  raw=wrapper
  // The stored wrapper also consumes depth/node/byte limits. Check it now,
  // rather than saving a rule that cannot be read back with the same limits.
  normalized,normalized_error:=filter_compile(raw,descriptor,limits,allocator)
  filter_destroy(&normalized,allocator)
  if normalized_error.reason!="" do return {},filter_error({"",normalized_error.reason})
 }
 root,_=raw.(json.Object)
 // Preserve folded checks so conflicting entity pins remain unsatisfiable.
 if children,ok:=root["all"].(json.Array);ok {
  for child in children {
   check,valid:=child.(json.Object)
   if !valid do continue
   field,_:=check["field"].(string); op,_:=check["op"].(string)
   id,is_string:=check["value"].(string)
   if field=="entity.id" && op=="eq" && is_string && entity_id=="" && nats.subject_token(id) do entity_id=id
  }
 }
 bytes,err:=json.marshal(raw,opt={sort_maps_by_key=true},allocator=allocator)
 if err!=nil do return {},filter_error({"","unknown_node"})
 if len(bytes)>filter_limits(limits).max_bytes {delete(bytes,allocator);return {},filter_error({"","too_large"})}
 prefix:=fmt.tprintf("%s.",descriptor.scope)
 suffix:=event_type[len(prefix):]
 return {event_type=strings.clone(event_type,allocator),subject_filter=strings.clone(fmt.tprintf("ev.%s.%s.%s.%s",owner,descriptor.scope,entity_id if entity_id!="" else "*",suffix),allocator),data_filter_json=string(bytes)},{}
}

Data_Key :: struct { key: string, values: []string } // values empty = free text
Preset   :: struct { id, label: string, filter_json: string }
Event_Descriptor :: struct {
 event_type, label, scope, class: string,
 data_keys: []Data_Key,
 presets: []Preset,
 no_delay, free_data_paths: bool,
 // Sources added later (e.g. webhooks) supply their own repository check.
 validate_entity: proc(repos:^iface.Repositories,owner,id:string)->domain.Domain_Error,
 // The occurrence callback borrows inputs and performs one indexed repository
 // lookup and no network I/O. Returned reasons are static strings.
 still_valid: proc(ctx: ^iface.Repositories, run: domain.Action_Run) -> (ok: bool, reason: string),
}

EVENT_DESCRIPTORS := [?]Event_Descriptor{
	{event_type = "chain.state", class = "state", label = "Task chain state changed", scope = "chain",
	 data_keys = {{key = "state", values = {"active", "completed", "archived"}}},
	 presets   = {{id = "chain_completed", label = "Task chain completed", filter_json = `{"all":[{"field":"data.state","op":"eq","value":"completed"}]}`}}},
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
