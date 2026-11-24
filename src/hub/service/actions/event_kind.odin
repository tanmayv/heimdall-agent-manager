package actions

import "core:encoding/json"
import "core:fmt"
import "core:mem"
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
Event_Descriptor :: struct { event_type, label, scope: string, data_keys: []Data_Key, presets: []Preset }

EVENT_DESCRIPTORS := [?]Event_Descriptor{
	{event_type = "chain.state", label = "Task chain state changed", scope = "chain",
	 data_keys = {{key = "state", values = {"active", "completed", "archived"}}},
	 presets   = {{id = "chain_completed", label = "Task chain completed", data_json = `{"state":"completed"}`}}},
	{event_type = "chain.work_finished", label = "Task chain work finished", scope = "chain",
	 data_keys = {{key = "outcome", values = {}}}, presets = {}},
}
