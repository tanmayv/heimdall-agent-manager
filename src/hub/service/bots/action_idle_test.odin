package bots
import "core:fmt"
import "core:testing"
import virtual "core:mem/virtual"
import sqlite "odin_test:hub/repository/sqlite"
import domain "odin_test:hub/domain"

idle_stop_guards_action_prompts :: proc(t:^testing.T) {
 for state in ([]string{"routed","forwarded","delivered"}) {
  f:=delivery_fixture(t)
  f.instance.runtime_status="running"
  f.ms+=f.pair.service.timers.bot_idle_stop_ms+60_000
  // T0 adds delivered-awaiting-read. Simulate that state on older schemas too.
  testing.expect(t,sqlite.exec(&f.pair.conn,"PRAGMA ignore_check_constraints=ON;"))
  testing.expect(t,sqlite.exec(&f.pair.conn,fmt.tprintf(`INSERT INTO pipeline_deliveries(delivery_id,owner_user_id,kind,bridge_id,agent_instance_id,ref,state,expires_at,created_at,updated_at) VALUES('action-delivery','alice','prompt','b1','inst_a','run:action-run','%s','later','old','old');`,state)))
  bots_supervisor_tick(&f.pair.service)
  testing.expect(t,f.instance.runtime_status=="running",state)
  testing.expect_value(t,len(f.frames),0)
  // Completed prompts and prompts for other instances do not keep this bot awake.
  testing.expect(t,sqlite.exec(&f.pair.conn,"UPDATE pipeline_deliveries SET state='done';"))
  testing.expect(t,sqlite.exec(&f.pair.conn,"INSERT INTO pipeline_deliveries SELECT 'other-delivery',owner_user_id,kind,bridge_id,'other',ref,message_id,'routed',outcome,reason,round,excluded_bridges,attempt,ack_reply,stream_sequence,retry_at,expires_at,created_at,forwarded_at,updated_at FROM pipeline_deliveries;"))
  bots_idle_stop(&f.pair.service,delivery_clock(f),f.ms)
  testing.expect_value(t,f.instance.runtime_status,"stopping")
  delivery_destroy(f)
 }
}
idle_stop_guards_recent_delivered_action :: proc(t:^testing.T) {
 f:=delivery_fixture(t);defer delivery_destroy(f)
 f.instance.runtime_status="running"
 f.ms+=f.pair.service.timers.bot_idle_stop_ms+60_000
 testing.expect(t,sqlite.exec(&f.pair.conn,`INSERT INTO actions(action_id,owner_user_id,prompt_text,target_kind,created_at,updated_at) VALUES('action','alice','hello','bot','old','old');`))
 testing.expect(t,sqlite.exec(&f.pair.conn,fmt.tprintf(`INSERT INTO action_runs(run_id,action_id,trigger_id,owner_user_id,occurrence_key,event_type,state,target_instance_id,created_at,started_at) VALUES('run','action','trigger','alice','once','chain.state','delivered','inst_a','old','%s');`,delivery_clock(f))))
 // Completed injection must retain the recent-action idle window.
 testing.expect(t,sqlite.exec(&f.pair.conn,`INSERT INTO pipeline_deliveries(delivery_id,owner_user_id,kind,bridge_id,agent_instance_id,ref,state,expires_at,created_at,updated_at) VALUES('finished-action','alice','prompt','b1','inst_a','run:run','done','later','old','old');`))
 bots_supervisor_tick(&f.pair.service)
 testing.expect_value(t,f.instance.runtime_status,"running")
 f.ms+=f.pair.service.timers.bot_idle_stop_ms+1000
 bots_idle_stop(&f.pair.service,delivery_clock(f),f.ms)
 testing.expect_value(t,f.instance.runtime_status,"stopping")
}
action_idle_failure :: proc(_:rawptr,instance_id,cutoff:string)->(bool,domain.Domain_Error) {return false,domain.domain_error(.Internal_Error,"lookup failed")}
idle_stop_preserves_bot_on_action_lookup_failure :: proc(t:^testing.T) {
 f:=delivery_fixture(t);defer delivery_destroy(f)
 f.instance.runtime_status="running"
 f.ms+=f.pair.service.timers.bot_idle_stop_ms+60_000
 f.pair.repo.action_activity=action_idle_failure
 bots_supervisor_tick(&f.pair.service)
 testing.expect_value(t,f.instance.runtime_status,"running")
}

action_idle_arena :: proc(t:^testing.T,scenario:proc(^testing.T)) {
 arena:virtual.Arena
 assert(virtual.arena_init_growing(&arena)==nil)
 defer virtual.arena_destroy(&arena)
 context.allocator=virtual.arena_allocator(&arena)
 context.temp_allocator=context.allocator
 scenario(t)
}
@(test) test_idle_stop_guards_action_prompts :: proc(t:^testing.T) {action_idle_arena(t,idle_stop_guards_action_prompts)}
@(test) test_idle_stop_guards_recent_delivered_action :: proc(t:^testing.T) {action_idle_arena(t,idle_stop_guards_recent_delivered_action)}
@(test) test_idle_stop_preserves_bot_on_action_lookup_failure :: proc(t:^testing.T) {action_idle_arena(t,idle_stop_preserves_bot_on_action_lookup_failure)}
