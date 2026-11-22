package actions

import "core:encoding/json"
import "core:mem"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

// src/hub/service/actions/triggers.odin
Match_Spec :: struct { event_type, subject_filter, data_filter_json: string } // allocated in the allocator passed to compile

Event_View :: struct { // all strings borrowed from the fetched batch or the pass arena
	subject, owner, event_type, event_id: string,
	stream_sequence: u64,
	stream_time_ms:  i64,
	envelope:        json.Object,
	schedule_next:   string, // header Nats-Schedule-Next, "" when absent
	trigger_rev:     string, // header Heim-Trigger-Rev, "" when absent
}

Sync_Context :: struct { outbox: ^iface.Event_Outbox_Repository, clock: ^platform.Clock, ids: ^platform.ID_Generator }

Trigger_Kind :: struct {
	kind: string, // "schedule" | "event"
	// Validates config and derives the stored match columns. owner, action_id and trigger_id are final values.
	compile: proc(owner, action_id, trigger_id: string, config: json.Object, allocator: mem.Allocator) -> (Match_Spec, domain.Domain_Error),
	// Called inside the transaction that saves or deletes a trigger. Appends outbox rows only. nil = nothing to sync.
	// before == nil: the trigger is new. after == nil: it was deleted.
	// Both carry the EFFECTIVE enabled flag: trigger.enabled AND action.enabled.
	on_change: proc(sc: ^Sync_Context, before, after: ^domain.Action_Trigger) -> domain.Domain_Error,
	// The part of occurrence_key after '<trigger_id>:'. nil = the envelope's event_id.
	event_key: proc(msg: Event_View, allocator: mem.Allocator) -> string,
	// Per-occurrence check. run = false records the occurrence as skipped with this reason.
	// retire = true also disables the trigger for good (a one-shot that fired, or an ended window).
	// nil = always run.
	guard: proc(t: domain.Action_Trigger, msg: Event_View) -> (run: bool, reason: string, retire: bool),
}
TRIGGER_KINDS := [?]Trigger_Kind{schedule_kind, event_kind}

extra_trigger_kinds: [dynamic]Trigger_Kind
trigger_kind_find :: proc(kind: string) -> (^Trigger_Kind, bool) {
	for &entry in TRIGGER_KINDS do if entry.kind == kind do return &entry,true
	for &entry in extra_trigger_kinds do if entry.kind == kind do return &entry,true
	return nil,false
}


detail_error :: proc(code: string) -> domain.Domain_Error {
	details:=make(map[string]string)
	defer delete(details)
	details["code"]=code
	data,_ := json.marshal(details,allocator=context.temp_allocator)
	return domain.domain_error(.Validation_Failed,code,string(data))
}
config_string :: proc(config: json.Object, key: string, fallback := "") -> (string,bool) {
	value,present := config[key]
	if !present do return fallback,true
	text,ok := value.(string)
	return text,ok
}
config_keys_valid :: proc(config: json.Object, allowed: []string) -> bool {
	for key in config {
		found:=false
		for candidate in allowed do if key==candidate {found=true; break}
		if !found do return false
	}
	return true
}
match_key :: proc(filter: string) -> string {
	for token in strings.split(filter,".",context.temp_allocator) do if token=="*" do return ""
	return filter
}
match_spec_destroy :: proc(spec: ^Match_Spec) {
	delete(spec.event_type); delete(spec.subject_filter); delete(spec.data_filter_json)
	spec^={}
}
