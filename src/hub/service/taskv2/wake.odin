package taskv2

import "core:fmt"
import "core:strings"
import jsonx "odin_test:lib/jsonx"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import agent "odin_test:hub/service/agent"
import project "odin_test:hub/service/project"


// Wake delivery (plan §2.5 / §4). A UoW never talks to a bridge: it queues
// start entries and generation-scoped stop intents on the Effects list.
// flush_wakes sends them after COMMIT. For a LIVE holder the entry is a
// nudge (deliver="nudge"): the bridge keeps the process, refreshes TASK.md and
// tells the agent to run `lease next` (T8: no re-bootstrap per attempt or
// review round). Otherwise the bridge re-bootstraps an instance it has a launch
// record for, and does a full launch for one it has never seen (JIT) — one
// launch path for every restart reason (§4c).

// WAKE_DELIVER_NUDGE marks a run[] entry for a live child (see
// agent.Wake_Agent_Run_Entry.deliver).
WAKE_DELIVER_NUDGE :: "nudge"

// Lease_Wake holds a complete command entry and its generation ticket.
// A redelivery whose generation ended carries only a deferred dispatch failure.
Lease_Wake :: struct {
 agent_instance_id: string,
 entry: agent.Start_Run_Entry,
 ticket: ^agent.Start_Ticket,
 failure: string,
}

// A grant supplies its ticket. Every other caller is a read-only redelivery;
// it must never open another generation, even when the old child has ended.
effect_wake_lease :: proc(svc: ^Service, u: ^Uow, lease: domain.Task_Lease, task: domain.Task, ticket: ^agent.Start_Ticket = nil) {
 ticket := ticket
 if u == nil || svc.agent_service == nil do return
 if ticket == nil {
	current,found,_:=iface.agent_get_instance(svc.agents,lease.holder_instance_id)
	if found {
		blocked,ready_ref:=fleet_runtime_operation(svc,current)
		if blocked {domain.agent_instance_destroy(&current);return}
		if ready_ref!="" && instance_is_live(current) {
			ticket=new(agent.Start_Ticket)
			ticket^=agent.Start_Ticket{instance=domain.agent_instance_clone(current),command_id=strings.concatenate({"fleet_notice_",ready_ref}),kept_live=true,reused=true,allocator=context.allocator}
			append(&u.effects.tickets,ticket)
		}
		domain.agent_instance_destroy(&current)
	}
 }
 if ticket == nil {
  reused, ok, ended, err := agent.start_reuse(svc.agent_service, lease.holder_instance_id, lease.lease_id)
  if !ok && err.code == .None {
   // A kept-live grant intentionally leaves start_ref untouched. Its durable
   // event binds the nudge to the exact child, without opening a generation.
   current, found, _ := iface.agent_get_instance(svc.agents, lease.holder_instance_id)
   if found {
    held, has_claim, _ := iface.taskchain_get_lease_by_holder(svc.repo, lease.holder_instance_id)
    if has_claim && held.lease_id == lease.lease_id && agent.runtime_expected_active(current.runtime_status) {
     events, eerr := iface.taskchain_list_events_by_task(svc.repo, lease.task_id, lease.owner_user_id)
     if eerr.code == .None {
      for event in events {
       if event.kind != EV_LEASE_GRANTED || jsonx.extract_string(event.payload_json,"lease_id","",true,context.temp_allocator) != lease.lease_id do continue
       kept := jsonx.extract_bool(event.payload_json,"start_kept_live",false,true) && jsonx.extract_int(event.payload_json,"start_run_count",-1,true) == current.run_count
       // Pre-T25 grants opened this generation without start_ref or event
       // metadata. Preserve their pending wake across the deploy/restart.
       legacy := !jsonx.has_key(event.payload_json,"start_run_count",true) && current.start_ref == "" &&
        (instance_is_live(current) || instance_is_pending(current)) &&
        held.confirmed_at == "" && held.delivery == domain.LEASE_DELIVERY_WAKE && held.phase == domain.LEASE_PHASE_ACTIVE &&
        (current.current_task_id == "" || current.current_task_id == string(lease.task_id))
       if kept || legacy {
        reused = agent.Start_Ticket{instance=domain.agent_instance_clone(current),command_id=strings.concatenate({"sb_",lease.lease_id}),kept_live=kept || instance_is_live(current),reused=true}
        reused.allocator = context.allocator
        ok = true
       }
      }
     }
    }
    domain.agent_instance_destroy(&current)
   }
  }
  if !ok {
   if ended || err.code != .None {
    key := effects_key(&u.effects, lease.bridge_id, string(lease.chain_id))
    runs := u.effects.runs[key]
    detail := err.message
    if detail == "" do detail = "lease start generation has ended"
    detail = strings.clone(detail)
    append(&u.effects.owned_strings, detail)
    append(&runs, Lease_Wake{agent_instance_id=lease.holder_instance_id, entry={lease_id=lease.lease_id}, failure=detail})
    u.effects.runs[key] = runs
   }
   return
  }
  validation := agent.validate_frozen_runtime_transport(svc.agent_service, reused.instance)
  if validation.code != .None {
   agent.start_ticket_destroy(&reused)
   key := effects_key(&u.effects, lease.bridge_id, string(lease.chain_id))
   runs := u.effects.runs[key]
   detail := strings.clone(validation.message)
   append(&u.effects.owned_strings,detail)
   append(&runs,Lease_Wake{agent_instance_id=lease.holder_instance_id,entry={lease_id=lease.lease_id},failure=detail})
   u.effects.runs[key]=runs
   return
  }
  ticket = new(agent.Start_Ticket)
  ticket^ = reused
  append(&u.effects.tickets, ticket)
 }
 inst := ticket.instance
 chain, cok, _ := iface.taskchain_get_chain(svc.repo, task.chain_id)
 if !cok {
  key := effects_key(&u.effects, inst.bridge_id, string(lease.chain_id))
  entries := u.effects.runs[key]
  detail := strings.clone("lease chain lookup failed before dispatch")
  append(&u.effects.owned_strings,detail)
  append(&entries,Lease_Wake{agent_instance_id=inst.agent_instance_id,ticket=ticket,entry={lease_id=lease.lease_id},failure=detail})
  u.effects.runs[key]=entries
  return
 }
 role := "worker"
 if lease.kind == domain.LEASE_KIND_REVIEW do role = "reviewer"
 permission_mode := domain.agent_instance_effective_permission_mode(inst)
 if ag, found, _ := iface.agent_get(svc.agents, inst.agent_id); found {
  permission_mode = domain.effective_permission_mode(inst.permission_mode, ag.permission_mode)
 }
 pack := strings.clone(build_pack_json(svc, chain, task, lease, inst))
 append(&u.effects.owned_strings, pack)
 launch := agent.start_launch_json(svc.agent_service, ticket^, &agent.Start_Lease{
  task_id=string(task.task_id), role=role, lease_id=lease.lease_id, pack_json=pack,
  permission_mode=permission_mode,
 })
 append(&u.effects.owned_strings, launch)
 entry := Lease_Wake{
  agent_instance_id=inst.agent_instance_id, ticket=ticket,
  entry={bridge_id=inst.bridge_id, deliver="nudge" if ticket.kept_live else "launch", launch_json=launch, lease_id=lease.lease_id},
 }
 key := effects_key(&u.effects, inst.bridge_id, string(chain.chain_id))
 entries := u.effects.runs[key]
 replaced := false
 for &e in entries {
  if e.agent_instance_id == entry.agent_instance_id {
   if e.ticket != nil do agent.start_cancel(svc.agent_service, e.ticket)
   e = entry; replaced = true
  }
 }
 if !replaced do append(&entries, entry)
 u.effects.runs[key] = entries
 remove_stop(u, key, entry.agent_instance_id)
}

Lease_Stop :: struct { instance_id, reason: string, run_count: int }

// effect_stop queues a stop for this exact instance generation.
// Callers exclude coordinators before recording a stop intent.
effect_stop :: proc(u: ^Uow, inst: domain.Agent_Instance, chain_id, reason: string) {
	bridge_id, instance_id := inst.bridge_id, inst.agent_instance_id
	if u == nil || bridge_id == "" || instance_id == "" do return
	key := effects_key(&u.effects, bridge_id, chain_id)
	if entries, has := u.effects.runs[key]; has {
		for e in entries do if e.agent_instance_id == instance_id do return // being restarted in this UoW
	}
	stops := u.effects.stops[key]
	for s in stops do if s.instance_id == instance_id do return
	append(&stops, Lease_Stop{effect_owned_string(&u.effects, instance_id), reason, inst.run_count})
	u.effects.stops[key] = stops
}

effect_has_stop :: proc(u: ^Uow, bridge_id, chain_id, instance_id: string) -> bool {
	if u == nil || bridge_id == "" || instance_id == "" do return false
	key := effects_key(&u.effects, bridge_id, chain_id)
	if stops, has := u.effects.stops[key]; has {
		for s in stops do if s.instance_id == instance_id do return true
	}
	return false
}

@(private = "file")
remove_stop :: proc(u: ^Uow, key, instance_id: string) {
	stops, has := u.effects.stops[key]
	if !has do return
	for i := 0; i < len(stops); i += 1 {
		if stops[i].instance_id == instance_id {
			ordered_remove(&stops, i)
			i -= 1
		}
	}
	u.effects.stops[key] = stops
}

@(private = "file")
split_wake_key :: proc(key: string) -> (bridge_id, chain_id: string) {
	for i in 0..<len(key) {
		if key[i] == 0 do return key[:i], key[i+1:]
	}
	return key, ""
}

// Wake_Command is one wake_agent push as sent (test seam: svc.wake_observer).
Wake_Command :: struct {
	bridge_id: string,
	chain_id:  string,
	body_json: string,
}

// flush_wakes sends one start batch per (bridge × chain) and one confirmed
// operation per stop a committed UoW decided on. Called after COMMIT, never under the
// tx mutex.
flush_wakes :: proc(svc: ^Service, e: ^Effects) {
 keys := make(map[string]bool, context.temp_allocator)
 for k in e.runs do keys[k] = true
 for k in e.stops do keys[k] = true
 for key in keys {
  bridge_id, chain_id := split_wake_key(key)
  if bridge_id == "" do continue
  wakes := e.runs[key]
  runs := make([dynamic]agent.Start_Run_Entry, context.temp_allocator)
  for wake in wakes {
   if wake.failure != "" {
    if wake.ticket != nil do agent.start_settle(svc.agent_service,wake.ticket,false)
    on_dispatch_failed(svc, wake.entry.lease_id, wake.failure)
    continue
   }
   append(&runs, wake.entry)
  }
  for stop in e.stops[key] {
   command := agent.task_stop_command(bridge_id, stop.instance_id, stop.reason, stop.run_count)
   if svc.wake_observer != nil do svc.wake_observer(svc.wake_observer_ctx, Wake_Command{bridge_id, chain_id, command.body_json})
   if sent, err := project.bridge_command_send_runtime(svc.bridge_command_sink, command); !sent {
    fmt.eprintfln("agent_stop_dispatch component=hub instance=%q bridge=%q op=%q reason=%q error=%q",
     stop.instance_id, bridge_id, command.command_id, stop.reason, err.message)
   }
   delete(command.command_id)
   delete(command.body_json)
  }
  if len(runs) == 0 do continue
  cmd_id := platform.generate_id(svc.ids, "cmd_")
  // Observe the exact selected wire form while retaining the caller allocator
  // for all sends and settlement side effects.
  dispatch := Wake_Dispatch{svc=svc}
  sender := agent.Agent_Service{bridges=svc.bridges, bridge_command_sink={
   ctx=&dispatch, send_runtime_command=proc(ctx: rawptr, cmd: project.Runtime_Command) -> (bool, domain.Domain_Error) {
    d := (^Wake_Dispatch)(ctx)
    if d.svc.wake_observer != nil {
     d.svc.wake_observer(d.svc.wake_observer_ctx, {bridge_id=cmd.bridge_id, chain_id=d.chain_id, body_json=cmd.body_json})
    }
    return project.bridge_command_send_runtime(d.svc.bridge_command_sink, cmd)
   },
  }}
  dispatch.chain_id = chain_id
  sent, err := agent.start_command_send(&sender, bridge_id, cmd_id, chain_id, runs[:], nil)
  for wake in wakes {
   if wake.ticket == nil || wake.failure != "" do continue
   agent.start_settle(svc.agent_service, wake.ticket, sent)
   if !sent do on_dispatch_failed(svc, wake.entry.lease_id, err.message)
  }
 }
}

Wake_Dispatch :: struct { svc: ^Service, chain_id: string }

// Pending children await readiness; this is a read-only lifecycle predicate.
instance_is_pending :: proc(inst: domain.Agent_Instance) -> bool {
	return inst.runtime_status == "launching" || inst.runtime_status == "starting" || inst.runtime_status == "blocked"
}
