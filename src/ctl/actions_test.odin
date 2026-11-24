package main

import "core:encoding/json"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import "core:os"
import "core:fmt"

// Track ordinary allocations independently of command-scoped temporary storage.
// Releasing the temporary arena is the same ownership boundary as a CLI command.
ctl_actions_test_tracked :: proc(t: ^testing.T, scenario: proc(t: ^testing.T)) {
	heap, scratch: mem.Tracking_Allocator
	mem.tracking_allocator_init(&heap, context.allocator)
	defer mem.tracking_allocator_destroy(&heap)
	arena: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) do return
	defer virtual.arena_destroy(&arena)
	mem.tracking_allocator_init(&scratch, virtual.arena_allocator(&arena))
	defer mem.tracking_allocator_destroy(&scratch)
	{
		context.allocator = mem.tracking_allocator(&heap)
		context.temp_allocator = mem.tracking_allocator(&scratch)
		scenario(t)
		free_all(context.temp_allocator)
	}
	testing.expect_value(t, len(scratch.allocation_map), 0)
	testing.expect_value(t, len(heap.allocation_map), 0)
}

ctl_actions_test_json :: proc(t: ^testing.T, req: Ctl_Request, expected: string) {
	body, ok := ctl_request_body_text(req.body)
	if !testing.expect(t, ok, "JSON body encoded") do return
	got, gok := ctl_parse_json_document(body)
	want, wok := ctl_parse_json_document(expected)
	if !testing.expect(t, gok && wok, body) do return
	got_json, gerr := json.marshal(got, json.Marshal_Options{sort_maps_by_key = true}, context.temp_allocator)
	want_json, werr := json.marshal(want, json.Marshal_Options{sort_maps_by_key = true}, context.temp_allocator)
	testing.expect(t, gerr == nil && werr == nil)
	testing.expect_value(t, string(got_json), string(want_json))
}


@(test)
test_ctl_automations_verbs :: proc(t:^testing.T) {
 ctl_actions_test_tracked(t,proc(t:^testing.T) {
  for verb in ([]string{"list","show","delete","runs","trigger-types"}) {
   method,params,ok:=ctl_automation_call({verb,"act_1"},nil)
   testing.expect(t,ok,verb)
   testing.expect_value(t,method,strings.concatenate({"agent.automations.",verb},context.temp_allocator))
   testing.expect(t,strings.contains(ctl_automation_help(verb),"Example"),verb)
   if verb=="show" || verb=="delete" || verb=="runs" do testing.expect(t,strings.contains(params,"act_1"))
  }
  for verb in ([]string{"show","update","delete","runs"}) {
   _,_,ok:=ctl_automation_call({verb},nil);testing.expect(t,!ok,verb)
  }
  method,page,pok:=ctl_automation_call({"runs","act_1"},{"--limit","17","--before","2026-11-01T00:00:00Z","--before-id","run_1"})
  testing.expect(t,pok);testing.expect_value(t,method,"agent.automations.runs")
  testing.expect(t,strings.contains(page,`"limit":17`) && strings.contains(page,"run_1"))
  for verb in ([]string{"list","show","delete","trigger-types"}) {
   _,_,valid:=ctl_automation_call({verb,"act_1"},{"--prompt","unexpected"});testing.expect(t,!valid,verb)
  }
  _,_,bad:=ctl_automation_call({"run","act_1"},nil);testing.expect(t,!bad)
  _,_,bad=ctl_automation_call({"runs","act_1"},{"--limit","201"});testing.expect(t,!bad)
 })
}
@(test)
test_ctl_automations_create_update :: proc(t:^testing.T) {
 ctl_actions_test_tracked(t,proc(t:^testing.T) {
  req,ok:=ctl_automation_request({"create"},{"--prompt","Review","--agent-id","agt_1","--rule","*:claude","--disabled","--min-interval","60","--trigger","cron:0 9 * * 1-5@Asia/Kolkata"})
  testing.expect(t,ok)
  ctl_actions_test_json(t,req,`{"prompt_text":"Review","target":{"kind":"agent","agent_id":"agt_1","rules":[{"bridge_id":"*","provider":"claude","model":"*"}]},"enabled":false,"min_interval_s":60,"triggers":[{"kind":"schedule","config":{"mode":"cron","cron_expr":"0 9 * * 1-5","timezone":"Asia/Kolkata"}}]}`)
  for args in ([][]string{{"--instance","inst_1"},{"--bot","bot_1"},{"--target","bot"}}) {
   method,_,valid:=ctl_automation_call({"update","act_1"},args)
   testing.expect(t,valid);testing.expect_value(t,method,"agent.automations.update")
  }
  req,ok=ctl_automation_request({"update","act_1"},{"--enable","--prompt","New"})
  testing.expect(t,ok);ctl_actions_test_json(t,req,`{"enabled":true,"prompt_text":"New"}`)
  for args in ([][]string{{"--enable","--disable"},{"--prompt","P","--bot","b","--instance","i"},{"--wat","x"},{"--filter","state=eq:completed"}}) {
   _,valid:=ctl_automation_request({"create"},args);testing.expect(t,!valid)
  }
 })
}
@(test)
test_ctl_automations_filter_operators :: proc(t:^testing.T) {
 ctl_actions_test_tracked(t,proc(t:^testing.T) {
  for tc in ([]struct{spec,expected:string}{
   {"state=eq:completed",`{"field":"data.state","op":"eq","value":"completed"}`},
   {"state=ne:archived",`{"field":"data.state","op":"ne","value":"archived"}`},
   {"state=in:completed|archived",`{"field":"data.state","op":"in","value":["completed","archived"]}`},
   {"state=not_in:completed|archived",`{"field":"data.state","op":"not_in","value":["completed","archived"]}`},
   {"entity.id=exists:false",`{"field":"entity.id","op":"exists","value":false}`},
   {"state=exists:true",`{"field":"data.state","op":"exists","value":true}`},
   {"state=completed",`{"field":"data.state","op":"eq","value":"completed"}`},
  }) {
   req,ok:=ctl_automation_request({"update","act_1"},{"--trigger",strings.concatenate({"event:chain.state,",tc.spec},context.temp_allocator),"--entity","chain_1","--delay","30"})
   testing.expect(t,ok,tc.spec)
   expected:=strings.concatenate({`{"triggers":[{"kind":"event","config":{"event_type":"chain.state","entity_id":"chain_1","filter":{"all":[`,tc.expected,`]}},"delay_s":30}]}`},context.temp_allocator)
   ctl_actions_test_json(t,req,expected)
  }
  for bad in ([]string{"state=wat:x","state=exists:yes","state=in:a|","=eq:x"}) {
   _,ok:=ctl_automation_check(bad);testing.expect(t,!ok,bad)
  }
 })
}
@(test)
test_ctl_automations_filter_files :: proc(t:^testing.T) {
 ctl_actions_test_tracked(t,proc(t:^testing.T) {
  tree:=`{"any":[{"field":"data.state","op":"eq","value":"completed"},{"not":{"field":"data.state","op":"exists","value":true}}]}`
  // Unique files remain command-owned temporary resources.
  path:=fmt.tprintf("%s/.cache/heimdall-tests/automation-filter-%d.json",os.get_env_alloc("HOME",context.temp_allocator),os.get_pid())
  if !testing.expect(t,os.write_entire_file(path,transmute([]u8)tree)==nil) do return
  defer os.remove(path)
  method,params,ok:=ctl_automation_call({"update","act_1"},{"--trigger","event:chain.state","--filter-file",path,"--entity","chain_1","--delay","0"})
  testing.expect(t,ok);testing.expect_value(t,method,"agent.automations.update");testing.expect(t,strings.contains(params,"any"))
  method,_,ok=ctl_automation_call({"filter-test"},{"--event-type","chain.state","--filter-file",path,"--event-file",path})
  testing.expect(t,ok);testing.expect_value(t,method,"agent.automations.filter-test")
  _,_,ok=ctl_automation_call({"filter-test"},{"--event-type","chain.state"});testing.expect(t,!ok)
 })
}
