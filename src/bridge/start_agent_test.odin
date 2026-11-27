package main

import "base:runtime"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:testing"
import contracts "odin_test:contracts"
import ws "odin_test:lib/ws"

// origin/main 60c3af8b launch/wake serializer bytes (before production edits).
START_TEST_OLD_LAUNCH :: `{"type":"launch_agent","protocol_version":1,"message_id":"msg_old","command_id":"old","payload":{"agent_instance_id":"i1","agent_id":"","agent_name":"","display_name":"","role":"worker","coordinator_agent_instance_id":"","chain_title":"","project_id":"","project_path":"","chain_id":"","conversation_id":"","provider":"codex","provider_profile":"codex","effective_transport":"pty","catalog_etag":"","model":"","launch_epoch":"","run_count":4,"permission_mode":"yolo","instance_token":"hit_i1","bootstrap_url":"/api/v1/bridge/agent-instances/i1/bootstrap"}}`
START_TEST_OLD_WAKE :: `{"type":"wake_agent","protocol_version":1,"command_id":"batch","chain_id":"chain","payload":{"run":[{"agent_instance_id":"i1","task_id":"t1","role":"worker","provider":"codex","effective_transport":"pty","catalog_etag":"etag","launch_epoch":"epoch","provider_profile":"codex","model":"model","agent_id":"agent","agent_name":"Name","chain_id":"chain","chain_title":"Title","coordinator_agent_instance_id":"coord","project_id":"project","project_path":"/project","lease_id":"l1","permission_mode":"ask","run_count":4,"pack":{"task_id":"t1"}},{"agent_instance_id":"i2","task_id":"t2","role":"reviewer","effective_transport":"pty","catalog_etag":"","launch_epoch":"","lease_id":"l2","run_count":5,"deliver":"nudge","pack":{}}],"stop":["stopped"]}}`
START_TEST_WAKE_LAUNCH :: `{"type":"launch_agent","command_id":"SYN","payload":{"agent_instance_id":"i1","task_id":"t1","role":"worker","provider":"codex","provider_profile":"codex","effective_transport":"pty","catalog_etag":"etag","launch_epoch":"epoch","instance_token":"hit_i1~epoch","model":"model","agent_id":"agent","agent_name":"Name","chain_id":"chain","chain_title":"Title","coordinator_agent_instance_id":"coord","project_id":"project","project_path":"/project","run_count":4,"lease_id":"l1","permission_mode":"ask","pack":{"task_id":"t1"}}}`

Start_Bridge_Test :: struct {
	t:^testing.T,
	allocator:mem.Allocator,
	caller_allocator, caller_temp_allocator:mem.Allocator,
	check_context, capture:bool,
	captures:int,
	launches, frames, statuses, stops:[dynamic]string,
	nudges:int,
	live, fail, nudge_fails:bool,
	live_instance_id: string,
}
start_bridge_expect_json :: proc(t:^testing.T,text,key,expected:string) {
    value:=extract_json_string(text,key,"")
    defer delete(value)
    testing.expect_value(t,value,expected)
}
start_bridge_test:^Start_Bridge_Test
start_bridge_check_context :: proc() {
	h := start_bridge_test
	if !h.check_context do return
	testing.expect(h.t,context.allocator.procedure == h.caller_allocator.procedure && context.allocator.data == h.caller_allocator.data,"side effect must use caller allocator before the hook changes it")
	testing.expect(h.t,context.temp_allocator.procedure == h.caller_temp_allocator.procedure && context.temp_allocator.data == h.caller_temp_allocator.data,"side effect must use caller temporary allocator")
}
start_bridge_launch :: proc(id,text:string,deadline:i64)->(bool,string,Bridge_Error) {
	h:=start_bridge_test
	start_bridge_check_context()
	context.allocator=h.allocator
	append(&h.launches,strings.clone(text))
	start_bridge_expect_json(h.t,text,"command_id",id)
	if h.fail && len(h.launches)==1 do return false,"denied by fixture",bridge_error(.agent_launch_failed,.denied)
	return true,"",{}
}
start_bridge_nudge :: proc(id,task,role,lease:string,generation:int,pack:string)->Bridge_Wake_Nudge {
	h:=start_bridge_test
	start_bridge_check_context()
	h.nudges+=1
	testing.expect(h.t,generation>0)
	testing.expect(h.t,lease!="")
	testing.expect(h.t,strings.has_prefix(pack,"{"))
	if h.nudge_fails do return .Delivery_Failed
	return .Delivered if h.live && (h.live_instance_id == "" || h.live_instance_id == id) else .Unavailable
}
start_bridge_stop :: proc(id:string,force:bool=false)->bool {
	start_bridge_check_context()
	context.allocator=start_bridge_test.allocator
	append(&start_bridge_test.stops,strings.clone(id))
	return start_bridge_test.capture
}
start_bridge_send :: proc(conn:^ws.Connection,text:string)->bool {
	start_bridge_check_context()
	context.allocator=start_bridge_test.allocator
	append(&start_bridge_test.frames,strings.clone(text))
	return true
}
start_bridge_status :: proc(conn:^ws.Connection,id:string) {
	start_bridge_check_context()
	context.allocator=start_bridge_test.allocator
	append(&start_bridge_test.statuses,strings.clone(id))
}
start_bridge_capture :: proc(id:string,generation:int,reset_live:bool=false,now:i64=0)->bool {
	start_bridge_check_context()
	start_bridge_test.captures+=1
	return true
}

start_bridge_run :: proc(t:^testing.T,scenario:proc(t:^testing.T,h:^Start_Bridge_Test)) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	track:mem.Tracking_Allocator
	mem.tracking_allocator_init(&track,runtime.heap_allocator())
	defer mem.tracking_allocator_destroy(&track)
	context.allocator=mem.tracking_allocator(&track)
	{
		h:=Start_Bridge_Test{t=t,allocator=context.allocator,caller_allocator=context.allocator,caller_temp_allocator=context.temp_allocator}
		start_bridge_test=&h
		launch,nudge,stop,send,status:=bridge_start_launch_proc,bridge_start_nudge_proc,bridge_start_stop_proc,bridge_start_send_proc,bridge_start_status_proc
		bridge_start_launch_proc,bridge_start_nudge_proc,bridge_start_stop_proc,bridge_start_send_proc,bridge_start_status_proc=start_bridge_launch,start_bridge_nudge,start_bridge_stop,start_bridge_send,start_bridge_status
		defer {bridge_start_launch_proc,bridge_start_nudge_proc,bridge_start_stop_proc,bridge_start_send_proc,bridge_start_status_proc=launch,nudge,stop,send,status;start_bridge_test=nil}
		capture:=bridge_start_capture_proc
		bridge_start_capture_proc=start_bridge_capture
		defer bridge_start_capture_proc=capture
		// Isolate the legacy cache and launch registry from other bridge tests.
		saved_results,saved_launches:=bridge_runtime_results,bridge_runtime_launches
		bridge_runtime_results=nil
		bridge_runtime_launches=nil
		defer {
			for result in bridge_runtime_results {delete(result.command_id,runtime.default_allocator());delete(result.result_json,runtime.default_allocator())}
			delete(bridge_runtime_results)
			delete(bridge_runtime_launches)
			bridge_runtime_results,bridge_runtime_launches=saved_results,saved_launches
		}
		scenario(t,&h)
		for s in h.launches do delete(s)
		for s in h.frames do delete(s)
		for s in h.statuses do delete(s)
		for s in h.stops do delete(s)
		delete(h.launches);delete(h.frames);delete(h.statuses);delete(h.stops)
	}
	testing.expect_value(t,len(track.allocation_map),0)
}

start_bridge_bytes :: proc(t:^testing.T,h:^Start_Bridge_Test) {
	// Intentional whitespace, key order and escapes make reserialization visible.
	launch:=`{ "command_id" : "entry", "payload": {"agent_instance_id":"i1", "role":"worker", "text":"braces } [ and quote \""} }`
	text:=bridge_start_wrap_launch(launch)
	defer delete(text)
	ok,err:=bridge_start_agent_apply(nil,text,123)
	testing.expect(t,ok,bridge_error_string(err))
	if testing.expect_value(t,len(h.launches),1) do testing.expect_value(t,h.launches[0],launch)
	testing.expect_value(t,len(h.frames),0)
}
start_bridge_nudges :: proc(t:^testing.T,h:^Start_Bridge_Test) {
	text:=`{"command_id":"batch","payload":{"run":[{"deliver":"nudge","launch":{"command_id":"entry","payload":{"agent_instance_id":"i1","task_id":"task","role":"worker","lease_id":"lease","run_count":4,"pack":{"task_id":"task"}}}}],"stop":[]}}`
	h.live=true
	ok,_:=bridge_start_agent_apply(nil,text,0)
	testing.expect(t,ok)
	testing.expect_value(t,h.nudges,1)
	testing.expect_value(t,len(h.launches),0)
	h.live=false
	ok,_=bridge_start_agent_apply(nil,text,0)
	testing.expect(t,ok)
	testing.expect_value(t,h.nudges,2)
	testing.expect_value(t,len(h.launches),1)
}
start_bridge_stops :: proc(t:^testing.T,h:^Start_Bridge_Test) {
	bridge_runtime_record_launch({agent_instance_id="local_coord",role="coordinator"})
	text:=`{"payload":{"run":[{"deliver":"launch","launch":{"command_id":"entry","payload":{"agent_instance_id":"run_coord","role":"coordinator"}}}],"stop":["run_coord","local_coord","ordinary",""]}}`
	ok,_:=bridge_start_agent_apply(nil,text,0)
	testing.expect(t,ok)
	testing.expect_value(t,len(h.launches),1) // plain starts may start coordinators
	if testing.expect_value(t,len(h.stops),1) do testing.expect_value(t,h.stops[0],"ordinary")
}
start_bridge_failure :: proc(t:^testing.T,h:^Start_Bridge_Test) {
	h.fail=true
	text:=`{"command_id":"batch","payload":{"run":[{"deliver":"launch","launch":{"command_id":"one","payload":{"agent_instance_id":"i1"}}},{"deliver":"launch","launch":{"command_id":"two","payload":{"agent_instance_id":"i2"}}}],"stop":["ordinary"]}}`
	bridge_hub_handle_start_agent(nil,text)
	testing.expect_value(t,len(h.launches),2)
	testing.expect_value(t,len(h.stops),1)
	if testing.expect_value(t,len(h.statuses),1) do testing.expect_value(t,h.statuses[0],"i1")
	if testing.expect_value(t,len(h.frames),1) {
		start_bridge_expect_json(t,h.frames[0],"status","failed")
		start_bridge_expect_json(t,h.frames[0],"class","recoverable")
		start_bridge_expect_json(t,h.frames[0],"code","internal_error")
		start_bridge_expect_json(t,h.frames[0],"cause","agent_launch_failed")
	}
}
start_bridge_old_launch :: proc(t:^testing.T,h:^Start_Bridge_Test) {
	bridge_hub_handle_command(nil,START_TEST_OLD_LAUNCH)
	if testing.expect_value(t,len(h.launches),1) do testing.expect_value(t,h.launches[0],START_TEST_OLD_LAUNCH)
	testing.expect_value(t,len(h.statuses),1)
	if testing.expect_value(t,len(h.frames),2) {
		accepted:=bridge_command_result_json("old","accepted","");defer delete(accepted)
		final:=bridge_command_result_json("old","succeeded","starting");defer delete(final)
		testing.expect_value(t,h.frames[0],accepted)
		testing.expect_value(t,h.frames[1],final)
	}
	// A retry retains the legacy cached final, with no extra launch/status.
	bridge_hub_handle_command(nil,START_TEST_OLD_LAUNCH)
	testing.expect_value(t,len(h.launches),1)
	testing.expect_value(t,len(h.statuses),1)
	// Preserve the old failed result's detail and its single status frame too.
	for s in h.launches do delete(s,h.allocator)
	clear(&h.launches)
	h.fail=true
	failure_text,_:=strings.replace_all(START_TEST_OLD_LAUNCH,`"command_id":"old"`,`"command_id":"failure"`)
	defer delete(failure_text)
	bridge_hub_handle_command(nil,failure_text)
	testing.expect_value(t,len(h.launches),1)
	testing.expect_value(t,len(h.statuses),2)
	if testing.expect_value(t,len(h.frames),5) {
		expected:=bridge_command_failed_json("failure",bridge_error_wire(bridge_error(.agent_launch_failed,.denied),"denied by fixture"),"failed")
		defer delete(expected)
		testing.expect_value(t,h.frames[4],expected)
	}
}
start_bridge_old_wake :: proc(t:^testing.T,h:^Start_Bridge_Test) {
	h.live=true
	h.live_instance_id="i2"
	bridge_hub_handle_wake_agent(nil,START_TEST_OLD_WAKE)
	if testing.expect_value(t,len(h.launches),1) {
		id:=extract_json_string(h.launches[0],"command_id","");defer delete(id)
		testing.expect(t,strings.has_prefix(id,"wake_launch_i1_"))
		normalized,_:=strings.replace_all(h.launches[0],id,"SYN");defer delete(normalized)
		testing.expect_value(t,normalized,START_TEST_WAKE_LAUNCH)
	}
	testing.expect_value(t,h.nudges,2)
	testing.expect_value(t,len(h.stops),1)
	if testing.expect_value(t,len(h.frames),1) {
		final:=bridge_command_result_json("batch","succeeded","");defer delete(final)
		testing.expect_value(t,h.frames[0],final)
	}
	// The legacy wire still accepts its payload, but its command result must
	// report a launch refusal as an action error.
	h.fail=true
	for s in h.launches do delete(s,h.allocator)
	clear(&h.launches)
	bridge_hub_handle_wake_agent(nil,START_TEST_OLD_WAKE)
	testing.expect_value(t,len(h.statuses),1)
	start_bridge_expect_json(t,h.frames[1],"status","failed")
	start_bridge_expect_json(t,h.frames[1],"cause","agent_launch_failed")
}
start_bridge_spec :: proc(t:^testing.T,h:^Start_Bridge_Test) {
	spec,known:=bridge_command_spec("start_agent")
	testing.expect(t,known && spec.queued && spec.requires_id && spec.class==.Lifecycle)
	key:=bridge_command_ordering_key("start_agent",`{"agent_instance_id":"one"}`);defer delete(key)
	testing.expect_value(t,key,"agent:one")
	key2:=bridge_command_ordering_key("start_agent",`{"payload":{"run":[{"launch":{"agent_instance_id":"nested"}}]}}`);defer delete(key2)
	testing.expect_value(t,key2,"agent-control")
	invalid := []string{`{}`,`{"request_id":"no"}`,`{"payload":{"command_id":"nested"}}`}
	for text in invalid {
		id,ok:=bridge_command_dispatch_resolve_id("start_agent",text);defer delete(id)
		testing.expect(t,!ok)
	}
	id,ok:=bridge_command_dispatch_resolve_id("start_agent",`{"command_id":"yes"}`);defer delete(id)
	testing.expect(t,ok)
}

@(test) test_start_agent_launch_entry_passes_launch_unchanged :: proc(t:^testing.T) {start_bridge_run(t,start_bridge_bytes)}
@(test) test_start_agent_nudge_live_child :: proc(t:^testing.T) {start_bridge_run(t,start_bridge_nudges)}
@(test) test_start_agent_stop_list :: proc(t:^testing.T) {start_bridge_run(t,start_bridge_stops)}
@(test) test_start_agent_failed_entry_reports_status :: proc(t:^testing.T) {start_bridge_run(t,start_bridge_failure)}
@(test) test_launch_agent_adapter_unchanged :: proc(t:^testing.T) {start_bridge_run(t,start_bridge_old_launch)}
@(test) test_wake_agent_adapter_unchanged :: proc(t:^testing.T) {start_bridge_run(t,start_bridge_old_wake)}
@(test) test_start_agent_spec_and_key :: proc(t:^testing.T) {start_bridge_run(t,start_bridge_spec)}

start_bridge_context_scenario :: proc(t:^testing.T,h:^Start_Bridge_Test) {
	h.check_context=true
	// Production dispatch callers use a heap allocator. Keep capture allocations
	// tracked separately, and assert the context before any hook switches it.
	context.allocator=runtime.heap_allocator()
	h.caller_allocator=context.allocator
	h.caller_temp_allocator=context.temp_allocator
	h.live,h.fail,h.capture=true,true,true
	text:=`{"command_id":"batch","payload":{"run":[{"deliver":"launch","launch":{"command_id":"one","payload":{"agent_instance_id":"i1"}}},{"deliver":"nudge","launch":{"command_id":"two","payload":{"agent_instance_id":"i2","role":"worker","task_id":"task","lease_id":"lease","run_count":4,"pack":{}}}},{"deliver":"launch","launch":{"command_id":"three","payload":{"agent_instance_id":"i3"}}}],"stop":["ordinary"]}}`
	bridge_hub_handle_start_agent(nil,text)
	testing.expect_value(t,len(h.launches),2)
	testing.expect_value(t,h.nudges,1)
	testing.expect_value(t,len(h.statuses),1)
	testing.expect_value(t,len(h.stops),1)
	testing.expect_value(t,h.captures,1)
	h.live=false
	bridge_hub_handle_start_agent(nil,text)
	testing.expect_value(t,len(h.launches),5) // nudge falls back to a launch
	testing.expect_value(t,h.nudges,2)
	testing.expect_value(t,h.captures,2)
}
start_bridge_launch_context_scenario :: proc(t:^testing.T,h:^Start_Bridge_Test) {
	h.check_context=true
	context.allocator=runtime.heap_allocator()
	h.caller_allocator=context.allocator
	start_bridge_old_launch(t,h)
}
start_bridge_wake_context_scenario :: proc(t:^testing.T,h:^Start_Bridge_Test) {
	h.check_context=true
	context.allocator=runtime.heap_allocator()
	h.caller_allocator=context.allocator
	start_bridge_old_wake(t,h)
	bridge_hub_handle_wake_agent(nil,`{"command_id":"missing_payload"}`)
	testing.expect_value(t,len(h.frames),3)
}
@(test) test_start_agent_side_effects_use_caller_context :: proc(t:^testing.T) {start_bridge_run(t,start_bridge_context_scenario)}
@(test) test_launch_agent_adapter_uses_caller_context :: proc(t:^testing.T) {start_bridge_run(t,start_bridge_launch_context_scenario)}
@(test) test_wake_agent_adapter_uses_caller_context :: proc(t:^testing.T) {start_bridge_run(t,start_bridge_wake_context_scenario)}

@(test) test_features_list_has_start_agent :: proc(t:^testing.T) {
	track:mem.Tracking_Allocator
	mem.tracking_allocator_init(&track,runtime.heap_allocator())
	defer mem.tracking_allocator_destroy(&track)
	context.allocator=mem.tracking_allocator(&track)
	{
		features:=bridge_runtime_features_json(context.allocator)
		defer delete(features)
		testing.expect(t,strings.contains(features,contracts.BRIDGE_FEATURE_START_AGENT_V1))
	}
	testing.expect_value(t,len(track.allocation_map),0)
}

@(test)
test_start_wake_nudge_failure_reports_error_without_launch :: proc(t: ^testing.T) {
	start_bridge_run(t, proc(t: ^testing.T, h: ^Start_Bridge_Test) {
		h.nudge_fails = true
		text := `{"command_id":"failed-nudge","payload":{"run":[{"deliver":"nudge","launch":{"command_id":"n","payload":{"agent_instance_id":"i","role":"worker","lease_id":"l","run_count":4,"pack":{}}}}]}}`
		bridge_hub_handle_start_agent(nil, text)
		testing.expect_value(t, h.nudges, 1)
		testing.expect_value(t, len(h.launches), 0)
		testing.expect_value(t, len(h.stops), 0)
		if testing.expect_value(t, len(h.frames), 1) {
			start_bridge_expect_json(t, h.frames[0], "status", "failed")
		}
	})
}

@(test)
test_start_wake_checks_live_generation_despite_launch_hint :: proc(t: ^testing.T) {
	start_bridge_run(t, proc(t: ^testing.T, h: ^Start_Bridge_Test) {
		h.live = true
		text := `{"command_id":"lease-wake","payload":{"run":[{"deliver":"launch","launch":{"command_id":"n","payload":{"agent_instance_id":"i","role":"worker","lease_id":"l","run_count":4,"pack":{}}}}]}}`
		bridge_hub_handle_start_agent(nil, text)
		testing.expect_value(t, h.nudges, 1)
		testing.expect_value(t, len(h.launches), 0)
		testing.expect_value(t, len(h.stops), 0)
		if testing.expect_value(t, len(h.frames), 1) {
			start_bridge_expect_json(t, h.frames[0], "status", "succeeded")
		}
	})
}
