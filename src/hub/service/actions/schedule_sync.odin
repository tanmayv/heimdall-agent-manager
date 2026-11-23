#+feature dynamic-literals
package actions

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:time"
import iface "odin_test:hub/repository/iface"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import nats "odin_test:lib/nats"
import schedule "odin_test:lib/schedule"

SCHEDULE_FIRE_TTL :: "24h"
Stored_Definition :: struct {subject,trigger_id:string, rev:int}
Reconcile_Op :: struct {publish:bool, trigger:^domain.Action_Trigger, purge_subject:string}

encode_object :: proc(obj: json.Object) -> string {
	bytes,_:=json.marshal(obj)
	return string(bytes)
}
schedule_row :: proc(sc: ^Sync_Context, owner, subject, event_type, action_id, trigger_id, run_id: string, rev: int, headers: json.Object) -> domain.Event_Outbox_Row {
	id:=platform.generate_id(sc.ids,"evt_")
	data:=make(json.Object)
	defer delete(data)
	if rev>0 do data["rev"]=json.Integer(rev)
	if run_id!="" do data["run_id"]=run_id
	body:=json.Object{"event_id"=id,"type"=event_type,"class"=string("occurrence"),"owner_user_id"=owner,"data"=data}
	defer delete(body)
	if action_id!="" do body["action_id"]=action_id
	if trigger_id!="" do body["trigger_id"]=trigger_id
	return {
		event_id=strings.clone(id),owner_user_id=strings.clone(owner),subject=strings.clone(subject),
		envelope_json=encode_object(body),headers_json=encode_object(headers),
		created_at=strings.clone(platform.clock_now(sc.clock)),
	}
}
schedule_definition_row :: proc(sc: ^Sync_Context, t: domain.Action_Trigger) -> (domain.Event_Outbox_Row,domain.Domain_Error) {
	value:json.Value
	if json.unmarshal(transmute([]u8)t.config_json,&value,allocator=context.temp_allocator)!=nil do return {},detail_error("invalid_config")
	defer json.destroy_value(value,allocator=context.temp_allocator)
	config,_:=value.(json.Object)
	spec,err:=schedule_compile(string(t.owner_user_id),string(t.action_id),t.trigger_id,config,context.allocator)
	if err.code!=.None do return {},err
	defer match_spec_destroy(&spec)
	mode,_:=config_string(config,"mode")
	expr:string
	switch mode {
	case "cron":
		cron,_:=config_string(config,"cron_expr")
		expr,_=schedule.nats_cron(cron,context.temp_allocator)
	case "interval":
		seconds,_:=config["interval_s"].(json.Integer)
		expr=fmt.tprintf("@every %ds",seconds)
	case "once":
		at,_:=config_string(config,"run_at")
		ms,_:=schedule_time(at)
		expr=fmt.tprintf("@at %s",platform.format_rfc3339_utc(time.unix(ms/1000,(ms%1000)*1_000_000)))
	}
	headers:=json.Object{"Nats-Schedule"=expr,"Nats-Schedule-Target"=spec.subject_filter,"Nats-TTL"=string("never"),"Nats-Schedule-TTL"=string(SCHEDULE_FIRE_TTL),"Heim-Trigger-Rev"=fmt.tprintf("%d",t.rev)}
	defer delete(headers)
	zone,_:=config_string(config,"timezone","UTC")
	if mode=="cron" && zone!="" && zone!="UTC" do headers["Nats-Schedule-Time-Zone"]=zone
	return schedule_row(sc,string(t.owner_user_id),fmt.tprintf("sched.def.%s",t.trigger_id),"schedule.fired",string(t.action_id),t.trigger_id,"",t.rev,headers),{}
}
schedule_purge_row :: proc(sc: ^Sync_Context, owner, trigger_id: string) -> domain.Event_Outbox_Row {
	headers:=json.Object{"Heim-Op"=string("purge")}
	defer delete(headers)
	return schedule_row(sc,owner,fmt.tprintf("sched.def.%s",trigger_id),"schedule.purge","",trigger_id,"",0,headers)
}
deferral_row :: proc(sc: ^Sync_Context, owner, action_id, run_id, not_before: string) -> (domain.Event_Outbox_Row,domain.Domain_Error) {
	if !nats.subject_token(owner) || !nats.subject_token(action_id) do return {},detail_error("invalid_subject_token")
	ms,ok:=schedule_time(not_before)
	if !ok do return {},detail_error("invalid_run_at")
	at:=platform.format_rfc3339_utc(time.unix(ms/1000,(ms%1000)*1_000_000))
	headers:=json.Object{"Nats-Schedule"=fmt.tprintf("@at %s",at),"Nats-Schedule-Target"=fmt.tprintf("ev.%s.action.%s.resume",owner,action_id),"Nats-Schedule-TTL"=string(SCHEDULE_FIRE_TTL)}
	defer delete(headers)
	return schedule_row(sc,owner,fmt.tprintf("sched.def.defer.%s",action_id),"action.resume",action_id,"",run_id,0,headers),{}
}
schedule_on_change :: proc(sc: ^Sync_Context, before, after: ^domain.Action_Trigger) -> domain.Domain_Error {
	row:domain.Event_Outbox_Row
	if after==nil || !after.enabled {
		if before==nil || !before.enabled do return {}
		row=schedule_purge_row(sc,string(before.owner_user_id),before.trigger_id)
	} else {
		if before!=nil && before.enabled && before.rev==after.rev do return {}
		err:domain.Domain_Error
		row,err=schedule_definition_row(sc,after^)
		if err.code!=.None do return err
	}
	defer domain.event_outbox_row_destroy(&row)
	return sc.outbox.append(sc.outbox.ctx,row)
}
// No I/O: callers hold the trigger slice until all planned operations finish.
reconcile_plan :: proc(stored: []Stored_Definition, triggers: []domain.Action_Trigger, allocator: mem.Allocator) -> []Reconcile_Op {
	ops: [dynamic]Reconcile_Op
	defer delete(ops)
	for &trigger in triggers {
		present:=false
		for definition in stored {
			if definition.subject==fmt.tprintf("sched.def.%s",trigger.trigger_id) {
				present=true
				if definition.trigger_id!=trigger.trigger_id || definition.rev!=trigger.rev do append(&ops,Reconcile_Op{publish=true,trigger=&trigger})
				break
			}
		}
		if !present do append(&ops,Reconcile_Op{publish=true,trigger=&trigger})
	}
	for definition in stored {
		found:=false
		for trigger in triggers do if definition.subject==fmt.tprintf("sched.def.%s",trigger.trigger_id) {found=true; break}
		if !found do append(&ops,Reconcile_Op{purge_subject=strings.clone(definition.subject,allocator)})
	}
	result:=make([]Reconcile_Op,len(ops),allocator)
	copy(result,ops[:])
	return result
}
reconcile_ops_destroy :: proc(ops: []Reconcile_Op, allocator:=context.allocator) {
	for op in ops do delete(op.purge_subject,allocator)
	delete(ops,allocator)
}


reconcile :: proc(s: ^Service, conn: ^nats.Connection) -> (done: bool, err: domain.Domain_Error) {
	// Outbox reads require a UoW too. Release it before querying JetStream.
	check, ok, begin_err := iface.unit_of_work_begin(s.factory)
	if !ok do return false, begin_err
	backlog, backlog_err := check.repos.event_outbox.backlog(check.repos.event_outbox.ctx)
	iface.unit_of_work_rollback(&check)
	check.ctx = nil
	if backlog_err.code != .None do return false, backlog_err
	if backlog != 0 do return false, {}

	stored: [dynamic]Stored_Definition
	owners: [dynamic]string
	defer {
		for definition in stored { delete(definition.subject); delete(definition.trigger_id) }
		for owner in owners do delete(owner)
		delete(stored)
		delete(owners)
	}
	start: u64 = 1
	for {
		msg, sequence, nerr := nats.stream_next(conn, "HEIM_EVENTS", "sched.def.*", start)
		if nerr.status == 13 && msg == nil do break
		if nerr.status != 0 {
			if msg != nil do nats.message_destroy(msg)
			return false, domain.domain_error(.Internal_Error, "failed to list schedule definitions")
		}
		if msg == nil do return false, domain.domain_error(.Internal_Error, "missing schedule definition message")
		value: json.Value
		parse_err := json.unmarshal(nats.message_data(msg), &value)
		if parse_err != nil {
			nats.message_destroy(msg)
			return false, domain.domain_error(.Internal_Error, "invalid stored schedule definition")
		}
		body, object_ok := value.(json.Object)
		owner, owner_ok := config_string(body, "owner_user_id")
		trigger_id, id_ok := config_string(body, "trigger_id")
		data, _ := body["data"].(json.Object)
		rev, _ := data["rev"].(json.Integer)
		if !object_ok || !owner_ok || owner == "" || !id_ok {
			json.destroy_value(value)
			nats.message_destroy(msg)
			return false, domain.domain_error(.Internal_Error, "invalid stored schedule definition")
		}
		append(&stored, Stored_Definition{subject=strings.clone(nats.message_subject(msg)),trigger_id=strings.clone(trigger_id),rev=int(rev)})
		append(&owners, strings.clone(owner))
		json.destroy_value(value)
		nats.message_destroy(msg)
		start = sequence + 1
	}

	uow, opened, uow_err := iface.unit_of_work_begin(s.factory)
	if !opened do return false, uow_err
	defer if uow.ctx != nil do iface.unit_of_work_rollback(&uow)
	// A writer may have appended while definitions were being read.
	pending, pending_err := uow.repos.event_outbox.backlog(uow.repos.event_outbox.ctx)
	if pending_err.code != .None do return false, pending_err
	if pending != 0 do return false, {}
	triggers, read_err := uow.repos.actions.triggers_effective(uow.repos.actions.ctx, "schedule")
	if read_err.code != .None do return false, read_err
	defer domain.action_triggers_destroy(triggers)
	ops := reconcile_plan(stored[:], triggers, context.allocator)
	defer reconcile_ops_destroy(ops)
	sc := Sync_Context{outbox=&uow.repos.event_outbox,clock=s.clock,ids=s.ids}
	for op in ops {
		row: domain.Event_Outbox_Row
		if op.publish {
			definition, row_err := schedule_definition_row(&sc, op.trigger^)
			if row_err.code != .None do return false, row_err
			row = definition
		} else {
			for definition, i in stored {
				if definition.subject == op.purge_subject {
					// The subject is authoritative even for malformed/stale body ids.
					trigger_id := strings.trim_prefix(definition.subject, "sched.def.")
					row = schedule_purge_row(&sc, owners[i], trigger_id)
					break
				}
			}
		}
		append_err := sc.outbox.append(sc.outbox.ctx, row)
		domain.event_outbox_row_destroy(&row)
		if append_err.code != .None do return false, append_err
	}
	committed, commit_err := iface.unit_of_work_commit(&uow)
	uow.ctx = nil
	return committed, commit_err
}
