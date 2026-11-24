package sqlite
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:testing"
import domain "odin_test:hub/domain"

@(test)
test_action_adapter_lookups_ignore_unrelated_history :: proc(t:^testing.T) {
 track:mem.Tracking_Allocator
 mem.tracking_allocator_init(&track,context.allocator)
 defer mem.tracking_allocator_destroy(&track)
 context.allocator=mem.tracking_allocator(&track)
 {
  arena:virtual.Arena
  if !testing.expect(t,virtual.arena_init_growing(&arena)==nil) do return
  defer virtual.arena_destroy(&arena)
  context.allocator=virtual.arena_allocator(&arena);context.temp_allocator=context.allocator
  db,opened,_:=open(":memory:");if !testing.expect(t,opened) do return
  defer close(&db)
  migrated,_:=run_migrations(&db);if !testing.expect(t,migrated) do return
  testing.expect(t,exec(&db,"PRAGMA foreign_keys=OFF;"))
  ai:Agent_Repo_SQLite;ar:=new_agent_repository(&ai,&db)
  ci:Content_Repo_SQLite;cr:=new_content_repository(&ci,&db)
  _,saved,err:=ar.save_instance(ar.ctx,{agent_instance_id="target",owner_user_id="owner",agent_id="agent",bridge_id="bridge",kind="agent",runtime_transport="pty",created_at="2000-01-01T00:00:00Z"})
  testing.expect(t,saved && err.code==.None)
  _,saved,err=cr.save_conversation(cr.ctx,{conversation_id="target_conversation",owner_user_id="owner",agent_instance_id="target",agent_id="agent",created_at="2000-01-01T00:00:00Z"})
  testing.expect(t,saved && err.code==.None)
  for i in 0..<1200 {
   id:=fmt.tprintf("noise%d",i)
   _,written,e:=ar.save_instance(ar.ctx,{agent_instance_id=id,owner_user_id="owner",agent_id="other",bridge_id="bridge",kind="agent",runtime_transport="pty",created_at="2026-01-01T00:00:00Z"})
   if !testing.expect(t,written && e.code==.None) do return
   _,written,e=cr.save_conversation(cr.ctx,{conversation_id=id,owner_user_id="owner",agent_instance_id=id,agent_id="other",created_at="2026-01-01T00:00:00Z"})
   if !testing.expect(t,written && e.code==.None) do return
  }
  rows,e:=ar.list_action_instances(ar.ctx,"owner","agent","bridge")
  if testing.expect(t,e.code==.None && len(rows)==1) do testing.expect_value(t,rows[0].agent_instance_id,"target")
  other,oe:=ar.list_action_instances(ar.ctx,"other","agent","bridge")
  testing.expect(t,oe.code==.None && len(other)==0)
  conversation,found,ce:=cr.action_conversation(cr.ctx,"owner","target")
  testing.expect(t,found && ce.code==.None && conversation.conversation_id=="target_conversation")
  _,found,_=cr.action_conversation(cr.ctx,"other","target")
  testing.expect(t,!found)
 }
 testing.expect_value(t,len(track.allocation_map),0)
}
