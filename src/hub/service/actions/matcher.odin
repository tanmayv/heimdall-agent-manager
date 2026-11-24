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
data_matches :: proc(filter_json:string,envelope:json.Object)->bool {
 if filter_json=="" do return true
 value:json.Value
 if json.unmarshal(transmute([]u8)filter_json,&value,allocator=context.temp_allocator)!=nil do return false
 defer json.destroy_value(value,allocator=context.temp_allocator)
 tree,e:=filter_compile(value,nil,FILTER_READ_LIMITS,context.temp_allocator)
 defer filter_destroy(&tree,context.temp_allocator)
 if e.reason!="" do return false
 result,_:=filter_evaluate(tree,envelope)
 return result
}
event_params :: proc(msg: Event_View, rev:int, nodes:string) -> string {
 params := make(json.Object, context.temp_allocator)
 data := make(json.Object, context.temp_allocator)
 params["entity"] = msg.envelope["entity"]
 params["entity_version"] = msg.envelope["entity_version"]
 params["class"] = msg.envelope["class"]
 for key in ([]string{"actor", "occurred_at"}) {
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
 trace:=make(json.Object,context.temp_allocator)
 trace["rev"]=json.Integer(rev);trace["nodes"]=nodes
 params["_match"]=trace
 params["_trigger_rev"]=json.Integer(rev)
 encoded, _ := json.marshal(params, allocator=context.temp_allocator)
 return string(encoded)
}
// Direct callers represent a one-event batch. The NATS runtime sweeps once
// before its whole fetched batch and disables this wrapper for each member.
handle_message :: proc(r: ^Runtime, msg: Event_View, sweep_before_match:=true) -> (acked: bool) {
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
 // Retained v1 catalog events are consumed without matching any rules.
 if (strings.has_prefix(msg.event_type, "chain.") || strings.has_prefix(msg.event_type, "task.")) {
  if _, present := msg.envelope["entity"].(json.Object); !present do return true
 }
 if sweep_before_match {if e:=expire_prompt_deliveries(&r.router);e.code!=.None do return false}
 uow, ok, _ := iface.unit_of_work_begin(r.svc.factory)
 if !ok do return false
 defer if uow.ctx != nil do iface.unit_of_work_rollback(&uow)
 if msg.event_type == "delivery.unread" {
  if len(tokens) != 5 || tokens[2] != "delivery" || tokens[4] != "unread" do return true
  data, _ := msg.envelope["data"].(json.Object)
  id, _ := data["delivery_id"].(string)
  if id == "" || id != tokens[3] do return true
  if r.router.pipeline.unread == nil do return false
  if err := r.router.pipeline.unread(r.router.pipeline.ctx, &uow, owner, id); err.code != .None do return false
  committed, _ := iface.unit_of_work_commit(&uow); uow.ctx = nil
  return committed
 }
 repo := &uow.repos.actions
 cached,err:=rule_index_owner(r,repo,owner)
 if err.code!=.None do return false
 bucket,exists:=cached.events[msg.event_type]
 if !exists {
  committed,_:=iface.unit_of_work_commit(&uow);uow.ctx=nil
  return committed
 }
 exact:=bucket.exact[msg.subject]
 wild:=bucket.wild
 now := platform.clock_now(r.svc.clock)
 retired:=false
 // Merge bucket positions to preserve the repository's deterministic order
 // when exact and wildcard rules of one action both match the same event.
 for a,b:=0,0;a<len(exact) || b<len(wild); {
  i:=0
  is_wild:=b<len(wild) && (a==len(exact) || wild[b]<exact[a])
  if is_wild {i=wild[b];b+=1} else {i=exact[a];a+=1}
  rule:=&cached.rules[i]
  trigger:=rule.trigger
  if is_wild && !rule_subject_matches(rule.subject_tokens,tokens) do continue
  if msg.stream_time_ms<rule.updated_at_ms do continue
  matched,_:=filter_evaluate(rule.tree,msg.envelope)
  if !matched do continue
  _,nodes:=filter_evaluate(rule.tree,msg.envelope,true,context.temp_allocator)
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
   event_params_json=event_params(msg,trigger.rev,nodes), state=domain.ACTION_RUN_QUEUED,
   created_at=now, rule_position=-1,
  }
  if !allowed {
   run.state=domain.ACTION_RUN_SKIPPED; run.reason=reason; run.finished_at=now
  }
  inserted: bool
  e: domain.Domain_Error
  if allowed && trigger.delay_s > 0 {
   inserted, e = settle_match(r, &uow, trigger, msg, run, now)
  } else if allowed {
   inserted,e=repo.run_enqueue(repo.ctx,run)
  } else {
   inserted, e = repo.run_insert(repo.ctx, run)
  }
  if e.code != .None do return false
  // A redelivery must not increment rev or append another purge.
  if inserted && retire {
   retired=true
   before := trigger
   after := trigger
   after.enabled=false; after.rev+=1; after.updated_at=now
   changed,e:=repo.trigger_retire(repo.ctx,trigger.trigger_id,trigger.rev,now)
   if e.code!=.None do return false
   if !changed {rule_index_clear(&r.rule_index);return false}
   if kind.on_change != nil {
    sc := Sync_Context{outbox=&uow.repos.event_outbox, clock=r.svc.clock, ids=r.svc.ids}
    if e := kind.on_change(&sc, &before, &after); e.code != .None do return false
   }
  }
 }
 if retired do sync.atomic_add(&r.svc.rule_epoch,1)
 committed, _ := iface.unit_of_work_commit(&uow)
 uow.ctx=nil
 return committed
}

// Occurrence receipts retain deduplication even after a pending run is updated
// to the latest event. A redelivery therefore cannot restart its timer.
settle_match :: proc(r: ^Runtime, uow: ^iface.Unit_Of_Work, trigger: domain.Action_Trigger, msg: Event_View, run: domain.Action_Run, now: string) -> (bool, domain.Domain_Error) {
 repo := &uow.repos.actions
 key := entity_settle_key(msg)
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
