package agent

import "core:mem"
import "core:strings"
import "core:testing"
import jsonx "odin_test:lib/jsonx"

// Captured from origin/main 60c3af8b's unchanged wake serializer. Both a
// launching lease and a nudge plus a stop exercise its ordering/omission rules.
START_LEGACY_WAKE :: `{"type":"wake_agent","protocol_version":1,"command_id":"batch","chain_id":"chain","payload":{"run":[{"agent_instance_id":"i1","task_id":"t1","role":"worker","provider":"codex","effective_transport":"pty","catalog_etag":"etag","launch_epoch":"epoch","provider_profile":"codex","model":"model","agent_id":"agent","agent_name":"Name","chain_id":"chain","chain_title":"Title","coordinator_agent_instance_id":"coord","project_id":"project","project_path":"/project","lease_id":"l1","permission_mode":"ask","run_count":4,"pack":{"task_id":"t1"}},{"agent_instance_id":"i2","task_id":"t2","role":"reviewer","effective_transport":"pty","catalog_etag":"","launch_epoch":"","lease_id":"l2","run_count":5,"deliver":"nudge","pack":{}}],"stop":["stopped"]}}`

start_command_shape_scenario :: proc(t:^testing.T,h:^Start_Test) {
	inst := start_test_row(t,h)
	launch := start_launch_json(&h.service,{instance=inst,command_id="entry"})
	entry := Start_Run_Entry{deliver="launch",launch_json=launch}
	text := start_command_json("batch","chain",{entry},nil)
	testing.expect_value(t,jsonx.extract_string(text,"type"),"start_agent")
	testing.expect_value(t,jsonx.extract_string(text,"agent_instance_id","",true),"inst")
	testing.expect(t,strings.contains(text,strings.concatenate({"\"launch\":",launch})),"launch embedded byte-for-byte")
	text = start_command_json("batch","chain",{entry,entry},nil)
	testing.expect(t,!jsonx.has_key(text,"agent_instance_id",true))
	text = start_command_json("batch","chain",{entry},{"stop"})
	testing.expect(t,!jsonx.has_key(text,"agent_instance_id",true))
	lease := Start_Lease{task_id="task",role="reviewer",lease_id="lease",pack_json=`{"text":"quoted \"text\""}`,permission_mode="ask"}
	launch = start_launch_json(&h.service,{instance=inst,command_id="entry"},&lease)
	keys := []string{"agent_instance_id","agent_id","run_count","launch_epoch","instance_token","bootstrap_url","lease_id","task_id","pack","permission_mode"}
	for key in keys do testing.expect(t,jsonx.has_key(launch,key),key)
	testing.expect_value(t,jsonx.extract_string(launch,"role"),"reviewer")
	testing.expect_value(t,jsonx.extract_string(launch,"permission_mode"),"ask")
	testing.expect_value(t,jsonx.extract_string(launch,"command_id"),"entry")
}

start_command_new_scenario :: proc(t:^testing.T,h:^Start_Test) {
	start_test_sql(t,h,`UPDATE bridges SET capabilities_json='{"features":["start_agent_v1"]}' WHERE bridge_id='brg'`)
	// Exercise the manual start service, rather than only the wire helper.
	_, _, ok, err := start(&h.service,start_test_auth(),"inst",{reason=.User_Start})
	testing.expect(t,ok,err.message)
	if !testing.expect_value(t,len(h.commands),1) do return
	testing.expect_value(t,jsonx.extract_string(h.commands[0],"type"),"start_agent")
	testing.expect_value(t,jsonx.extract_string(h.commands[0],"agent_instance_id","",true),"inst")
}

start_command_old_launch_scenario :: proc(t:^testing.T,h:^Start_Test) {
	_, _, ok, err := start(&h.service,start_test_auth(),"inst",{reason=.User_Start})
	testing.expect(t,ok,err.message)
	if !testing.expect_value(t,len(h.commands),1) do return
	testing.expect_value(t,h.commands[0],start_test_expected(t,h,0))
}

start_command_old_wake_scenario :: proc(t:^testing.T,h:^Start_Test) {
	launches := [?]string{
		`{"type":"launch_agent","command_id":"entry1","payload":{"agent_instance_id":"i1","task_id":"t1","role":"worker","provider":"codex","effective_transport":"pty","catalog_etag":"etag","launch_epoch":"epoch","provider_profile":"codex","model":"model","agent_id":"agent","agent_name":"Name","chain_id":"chain","chain_title":"Title","coordinator_agent_instance_id":"coord","project_id":"project","project_path":"/project","lease_id":"l1","permission_mode":"ask","run_count":4,"pack":{"task_id":"t1"}}}`,
		`{"type":"launch_agent","command_id":"entry2","payload":{"agent_instance_id":"i2","task_id":"t2","role":"reviewer","lease_id":"l2","run_count":5,"pack":{}}}`,
	}
	run := [?]Start_Run_Entry{{deliver="launch",launch_json=launches[0],lease_id="l1"},{deliver="nudge",launch_json=launches[1],lease_id="l2"}}
	sent,err := start_command_send(&h.service,"brg","batch","chain",run[:],{"stopped"})
	testing.expect(t,sent,err.message)
	if testing.expect_value(t,len(h.commands),1) do testing.expect_value(t,h.commands[0],START_LEGACY_WAKE)
	// Pure stop remains an old wake, and an inner lease key defeats plain launch
	// fallback even when the redundant entry.lease_id was not populated.
	sent,err = start_command_send(&h.service,"brg","stop","chain",nil,{"stopped"})
	testing.expect(t,sent,err.message)
	testing.expect_value(t,jsonx.extract_string(h.commands[1],"type"),"wake_agent")
	run[0].lease_id=""
	sent,err = start_command_send(&h.service,"brg","lease","chain",run[:1],nil)
	testing.expect(t,sent,err.message)
	testing.expect_value(t,jsonx.extract_string(h.commands[2],"type"),"wake_agent")
}

@(test) test_start_command_json_shape :: proc(t:^testing.T) {start_test_run(t,start_command_shape_scenario)}
@(test) test_start_command_send_new_bridge :: proc(t:^testing.T) {start_test_run(t,start_command_new_scenario)}
@(test) test_start_command_old_bridge_launch_agent_bytes :: proc(t:^testing.T) {start_test_run(t,start_command_old_launch_scenario)}
@(test) test_start_command_old_bridge_wake_agent_bytes :: proc(t:^testing.T) {start_test_run(t,start_command_old_wake_scenario)}

start_command_pack_bytes_scenario :: proc(t:^testing.T,h:^Start_Test) {
	pack := `{ "z": 1, "a": "escaped \" quote", "nested": { "value": "}" } }`
	lease := Start_Lease{task_id="task",role="worker",lease_id="lease",pack_json=pack}
	inst := start_test_row(t,h)
	launch := start_launch_json(&h.service,{instance=inst,command_id="entry"},&lease)
	expected := strings.concatenate({`"pack":`,pack})
	testing.expect(t,strings.contains(launch,expected),"lease pack bytes survive launch serialization")
	sent,err := start_command_send(&h.service,"brg","batch","chain",{{deliver="launch",launch_json=launch,lease_id="lease"}},nil)
	testing.expect(t,sent,err.message)
	if testing.expect_value(t,len(h.commands),1) do testing.expect(t,strings.contains(h.commands[0],expected),"lease pack bytes survive legacy wake conversion")
}

@(test) test_start_lease_pack_bytes_survive_legacy_fallback :: proc(t:^testing.T) {start_test_run(t,start_command_pack_bytes_scenario)}

@(test) test_start_command_json_tracking :: proc(t:^testing.T) {
	track:mem.Tracking_Allocator
	mem.tracking_allocator_init(&track,context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator=mem.tracking_allocator(&track)
	{
		text:=start_command_json("cmd","chain",{{deliver="launch",launch_json=`{"payload":{"agent_instance_id":"id"}}`}},nil)
		delete(text)
	}
	testing.expect_value(t,len(track.allocation_map),0)
}
