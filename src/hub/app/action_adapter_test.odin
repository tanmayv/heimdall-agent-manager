package app
import "core:mem"
import "core:mem/virtual"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"
import placement "odin_test:hub/service/placement"

@(test)
test_action_agent_adapter_reuses_any_runtime_state :: proc(t:^testing.T) {
 track:mem.Tracking_Allocator
 mem.tracking_allocator_init(&track,context.allocator);defer mem.tracking_allocator_destroy(&track)
 context.allocator=mem.tracking_allocator(&track)
 {
  arena:virtual.Arena
  if !testing.expect(t,virtual.arena_init_growing(&arena)==nil) do return
  defer virtual.arena_destroy(&arena)
  context.allocator=virtual.arena_allocator(&arena);context.temp_allocator=context.allocator
  db,opened,_:=sqlite.open(":memory:");if !testing.expect(t,opened) do return
  defer sqlite.close(&db)
  migrated,_:=sqlite.run_migrations(&db);if !testing.expect(t,migrated) do return
  testing.expect(t,sqlite.exec(&db,"PRAGMA foreign_keys=OFF;"))
  ai:sqlite.Agent_Repo_SQLite;ar:=sqlite.new_agent_repository(&ai,&db)
  ci:sqlite.Content_Repo_SQLite;cr:=sqlite.new_content_repository(&ci,&db)
  graph:App_Graph
  graph.agents.agents=&ar;graph.content.content=&cr;graph.clock=platform.real_clock()
  cases:=[3]struct{id,state,stop,created:string}{
   {"userstop","stopped","user","2026-01-01T00:00:00Z"},
   {"failed","failed","","2026-01-02T00:00:00Z"},
   {"unreachable","unreachable","","2026-01-03T00:00:00Z"}}
  for c in cases {
   _,saved,err:=ar.save_instance(ar.ctx,{agent_instance_id=c.id,agent_id="agent",owner_user_id="owner",bridge_id="bridge",provider="alpha",model="m1",
    project_id="project",runtime_transport="pty",runtime_status=c.state,stopped_by=c.stop,created_at=c.created})
   testing.expect(t,saved && err.code==.None)
   _,saved,err=cr.save_conversation(cr.ctx,{conversation_id=c.id,agent_instance_id=c.id,agent_id="agent",owner_user_id="owner",created_at=c.created})
   testing.expect(t,saved && err.code==.None)
  }
  candidate:=placement.Candidate{bridge_id="bridge",provider="alpha",model="m1"}
  for c in cases {
   id,cid,found:=action_agent_find(&graph,"owner","agent","project",c.id,candidate)
   testing.expect(t,found && id==c.id && cid==c.id)
  }
  id,_,found:=action_agent_find(&graph,"owner","agent","project","",candidate)
  testing.expect(t,found && id=="unreachable")
  _,_,found=action_agent_find(&graph,"other","agent","project","",candidate);testing.expect(t,!found)
  _,_,found=action_agent_find(&graph,"owner","agent","different","",candidate);testing.expect(t,!found)
  candidate.model="m2"
  _,_,found=action_agent_find(&graph,"owner","agent","project","",candidate);testing.expect(t,!found)
 }
 testing.expect_value(t,len(track.allocation_map),0)
}
