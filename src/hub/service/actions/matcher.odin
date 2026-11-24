#+feature dynamic-literals
package actions

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

subject_matches :: proc(filter, subject: string) -> bool {
 filters := strings.split(filter, ".", context.temp_allocator)
 tokens := strings.split(subject, ".", context.temp_allocator)
 if len(filters) != len(tokens) do return false
 for token, i in filters do if token != "*" && token != tokens[i] do return false
 return true
}
// JSON strings compare as their contents; other scalar values compare as JSON text.
scalar_text :: proc(value: json.Value) -> (string, bool) {
 switch v in value {
 case string: return v, true
 case json.Object, json.Array: return "", false
 case json.Null, json.Integer, json.Float, bool:
  bytes, err := json.marshal(value, allocator=context.temp_allocator)
  return string(bytes), err == nil
 }
 return "", false
}
data_matches :: proc(filter_json: string, data: json.Object) -> bool {
 if filter_json == "" do return true
 value: json.Value
 if json.unmarshal(transmute([]u8)filter_json, &value, allocator=context.temp_allocator) != nil do return false
 defer json.destroy_value(value, allocator=context.temp_allocator)
 filters, valid := value.(json.Object)
 if !valid do return false
 for key, expected in filters {
  actual, found := data[key]
  if !found do return false
  a, a_ok := scalar_text(actual)
  b, b_ok := scalar_text(expected)
  if !a_ok || !b_ok || a != b do return false
 }
 return true
}
event_params :: proc(msg: Event_View) -> string {
 params := make(json.Object, context.temp_allocator)
 data := make(json.Object, context.temp_allocator)
 for key in ([]string{"chain_id", "task_id", "actor", "occurred_at"}) {
  text, _ := msg.envelope[key].(string)
  params[key] = text
 }
 params["type"] = msg.event_type
 params["id"] = msg.event_id
 params["fired_at"] = platform.format_rfc3339_utc(time.Time{_nsec=msg.stream_time_ms*1_000_000})
 source, _ := msg.envelope["data"].(json.Object)
 for key, value in source {
  text, ok := scalar_text(value)
  if ok do data[key] = text
 }
 params["data"] = data
 encoded, _ := json.marshal(params, allocator=context.temp_allocator)
 return string(encoded)
}
handle_message :: proc(r: ^Runtime, msg: Event_View) -> (acked: bool) {
 tokens := strings.split(msg.subject, ".", context.temp_allocator)
 if len(tokens) < 3 || tokens[0] != "ev" || tokens[1] == "" || tokens[1] == "dlq" do return true
 owner := tokens[1]
 if value, present := msg.envelope["owner_user_id"]; present {
  claimed, valid := value.(string)
  if !valid || claimed != owner {
   sync.atomic_add(&r.skipped_owner_mismatch, 1)
   return true
  }
 }
 uow, ok, _ := iface.unit_of_work_begin(r.svc.factory)
 if !ok do return false
 defer if uow.ctx != nil do iface.unit_of_work_rollback(&uow)
 repo := &uow.repos.actions
 triggers, err := repo.triggers_match(repo.ctx, owner, msg.event_type, msg.subject)
 defer domain.action_triggers_destroy(triggers)
 if err.code != .None do return false
 now := platform.clock_now(r.svc.clock)
 data, _ := msg.envelope["data"].(json.Object)
 for trigger in triggers {
  if string(trigger.owner_user_id) != owner || !trigger.enabled do continue
  if !subject_matches(trigger.subject_filter, msg.subject) || !data_matches(trigger.data_filter_json, data) do continue
  updated, valid := platform.rfc3339_to_unix_ms(trigger.updated_at)
  if !valid || msg.stream_time_ms < updated do continue
  kind, found := trigger_kind_find(trigger.kind)
  if !found do continue
  allowed, reason, retire := true, "", false
  if kind.guard != nil do allowed, reason, retire = kind.guard(trigger, msg)
  key := msg.event_id
  if kind.event_key != nil do key = kind.event_key(msg, context.temp_allocator)
  run := domain.Action_Run{
   run_id=platform.generate_id(r.svc.ids, "arun_"), action_id=trigger.action_id,
   trigger_id=trigger.trigger_id, owner_user_id=trigger.owner_user_id,
   occurrence_key=fmt.tprintf("%s:%s", trigger.trigger_id, key),
   event_type=msg.event_type, event_id=msg.event_id, stream_sequence=i64(msg.stream_sequence),
   event_params_json=event_params(msg), state=domain.ACTION_RUN_QUEUED,
   created_at=now, rule_position=-1,
  }
  if !allowed {
   run.state=domain.ACTION_RUN_SKIPPED; run.reason=reason; run.finished_at=now
  } else if trigger.delay_s == 0 {
   if _,expiry_err:=expire_open_run(&r.router, &uow, trigger.action_id);expiry_err.code!=.None do return false
   open, exists, e := repo.run_open(repo.ctx, trigger.action_id)
   defer domain.action_run_destroy(&open)
   if e.code != .None do return false
   if exists { run.state=domain.ACTION_RUN_JOINED; run.joined_run_id=strings.clone(open.run_id,context.temp_allocator); run.finished_at=now }
  }
  inserted: bool
  e: domain.Domain_Error
  if allowed && trigger.delay_s > 0 {
   inserted, e = settle_match(r, &uow, trigger, msg, run, now)
  } else {
   inserted, e = repo.run_insert(repo.ctx, run)
  }
  if e.code != .None do return false
  if inserted && run.finished_at != "" {
   if e := repo.runs_prune(repo.ctx, trigger.action_id, 200, history_cutoff(now)); e.code != .None do return false
  }
  // A redelivery must not increment rev or append another purge.
  if inserted && retire {
   before := trigger
   after := trigger
   after.enabled=false; after.rev+=1; after.updated_at=now
   if e := repo.trigger_save(repo.ctx, after); e.code != .None do return false
   if kind.on_change != nil {
    sc := Sync_Context{outbox=&uow.repos.event_outbox, clock=r.svc.clock, ids=r.svc.ids}
    if e := kind.on_change(&sc, &before, &after); e.code != .None do return false
   }
  }
 }
 committed, _ := iface.unit_of_work_commit(&uow)
 uow.ctx=nil
 return committed
}

// Occurrence receipts retain deduplication even after a pending run is updated
// to the latest event. A redelivery therefore cannot restart its timer.
settle_match :: proc(r: ^Runtime, uow: ^iface.Unit_Of_Work, trigger: domain.Action_Trigger, msg: Event_View, run: domain.Action_Run, now: string) -> (bool, domain.Domain_Error) {
 repo := &uow.repos.actions
 descriptor := event_descriptor_find(msg.event_type)
 key := ""
 if descriptor != nil && descriptor.settle_key != nil do key = descriptor.settle_key(msg)
 pending, found, err := repo.run_settle_pending(repo.ctx, trigger.trigger_id, key)
 defer domain.action_run_destroy(&pending)
 if err.code != .None do return false, err
 next := run
 snapshot: json.Value
 if json.unmarshal(transmute([]u8)run.event_params_json, &snapshot, allocator=context.temp_allocator) != nil do return false, detail_error("invalid_event")
 object, _ := snapshot.(json.Object)
 object["_trigger_rev"] = json.Integer(trigger.rev)
 encoded, _ := json.marshal(object, allocator=context.temp_allocator)
 next.event_params_json = string(encoded)
 next.delay_s = trigger.delay_s
 next.settle_key = key
 next.settle_pending = true
 next.state = domain.ACTION_RUN_DEFERRED
 ms, _ := platform.rfc3339_to_unix_ms(now)
 next.not_before = platform.format_rfc3339_utc(time.Time{_nsec=(ms+i64(trigger.delay_s)*1000)*1_000_000})
 receipt := next
 if found {
  receipt.state = domain.ACTION_RUN_JOINED
  receipt.settle_pending = false
  receipt.joined_run_id = pending.run_id
  receipt.finished_at = now
 }
 inserted, insert_err := repo.run_insert(repo.ctx, receipt)
 if insert_err.code != .None || !inserted do return inserted, insert_err
 if found {
  // Ordered stream delivery normally guarantees this; stale redeliveries must
  // never replace a newer occurrence or move its timer.
  if run.stream_sequence <= pending.stream_sequence do return true, {}
  next.run_id = pending.run_id
  next.occurrence_key = pending.occurrence_key
  next.created_at = pending.created_at
  changed, update_err := repo.run_transition(repo.ctx, next, domain.ACTION_RUN_DEFERRED)
  if update_err.code != .None do return false, update_err
  if !changed do return false, domain.domain_error(.Conflict, "settle run changed")
 }
 sc := Sync_Context{outbox=&uow.repos.event_outbox, clock=r.svc.clock, ids=r.svc.ids}
 row, schedule_err := settle_deferral_row(&sc, next)
 if schedule_err.code != .None do return false, schedule_err
 defer domain.event_outbox_row_destroy(&row)
 return true, sc.outbox.append(sc.outbox.ctx, row)
}
