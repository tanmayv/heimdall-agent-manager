package http

import "core:encoding/json"
import "core:strings"
import "core:testing"
import actions "odin_test:hub/service/actions"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"

@(test)
test_action_filter_test_and_limits_api :: proc(t:^testing.T) {action_api_test(t,action_filter_api)}
action_filter_api :: proc(t:^testing.T,f:^Action_API_Fixture) {
 f.service.filter_limits=actions.FILTER_DEFAULT_LIMITS
 f.service.filter_limits.max_checks=1
 meta:=action_api_data(t,action_trigger_types_handler(&f.handlers,action_api_request(f,"GET","/api/v1/actions/trigger-types","")))
 limits,_:=meta["limits"].(json.Object);filter,_:=limits["filter"].(json.Object)
 testing.expect_value(t,filter["max_checks"].(json.Integer),json.Integer(1))
 request:=action_api_request(f,"POST","/api/v1/actions/filter-test",`{"event_type":"chain.state","filter":{"any":[{"field":"data.state","op":"eq","value":"completed"}]},"event":{"data":{"state":"completed"}}}`)
 result:=action_api_data(t,action_filter_test_handler(&f.handlers,request))
 testing.expect_value(t,result["valid"].(bool),true)
 testing.expect_value(t,result["matched"].(bool),true)
 testing.expect_value(t,result["nodes"].(string),"TT")
 request.body=`{"event_type":"chain.state","event":{"data":{}}}`
 result=action_api_data(t,action_filter_test_handler(&f.handlers,request))
 testing.expect_value(t,result["valid"].(bool),true)
 testing.expect_value(t,result["matched"].(bool),true)
 request.body=`{"event_type":"chain.state","filter":{"all":[{"field":"actor","op":"eq","value":"a"},{"field":"actor","op":"eq","value":"b"}]},"event":{}}`
 result=action_api_data(t,action_filter_test_handler(&f.handlers,request))
 testing.expect_value(t,result["valid"].(bool),false)
 testing.expect_value(t,result["reason"].(string),"too_many_nodes")
 testing.expect_value(t,result["path"].(string),"/all/1")
 // The same effective override applies when saving a rule.
 body:=action_api_base_body(f,`[{"kind":"event","config":{"event_type":"chain.state","filter":{"all":[{"field":"actor","op":"eq","value":"a"},{"field":"actor","op":"eq","value":"b"}]}}}]`)
 response:=create_action_handler(&f.handlers,action_api_request(f,"POST","/api/v1/actions",body))
 testing.expect_value(t,response.status,422)
 testing.expect(t,strings.contains(response.body,"invalid_filter"))
 testing.expect_value(t,action_api_backlog(t,f),i64(0))
}

@(test)
test_action_filter_migrated_api_roundtrip :: proc(t:^testing.T) {action_api_test(t,action_filter_roundtrip)}
action_filter_roundtrip :: proc(t:^testing.T,f:^Action_API_Fixture) {
 _,saved,err:=iface.taskchain_save_chain(&f.repos.taskchains,domain.Task_Chain{chain_id="filter_chain",owner_user_id=f.wire.owner,title="Filter",kind=domain.CHAIN_KIND_MIXED_WORK,status=.Active})
 if !testing.expect(t,saved && err.code==.None) do return
 body:=action_api_base_body(f,`[{"kind":"event","config":{"event_type":"chain.state","entity_id":"filter_chain"}}]`)
 created:=action_api_data(t,create_action_handler(&f.handlers,action_api_request(f,"POST","/api/v1/actions",body)),201)
 id,_:=created["id"].(string)
 if !testing.expect(t,id!="") do return
 // Recreate a v1 stored trigger, then run the exact upgrade SQL.
 testing.expect(t,sqlite.exec(&f.wire.conn,`UPDATE action_triggers SET config='{"event_type":"chain.state","chain_id":"filter_chain","data":{"state":"completed"}}',data_filter='{"state":"completed"}';`))
 testing.expect(t,sqlite.exec(&f.wire.conn,#load("../../repository/sqlite/migrations/actions_007_filter_tree.sql",string)))
 before,before_err:=f.repos.actions.triggers_list(f.repos.actions.ctx,domain.Action_ID(id))
 defer domain.action_triggers_destroy(before)
 if !testing.expect(t,before_err.code==.None && len(before)==1) do return
 path:=strings.concatenate({"/api/v1/actions/",id},context.temp_allocator)
 got:=action_api_data(t,get_action_handler(&f.handlers,action_api_request(f,"GET",path,"")))
 triggers,_:=got["triggers"].(json.Array)
 trigger,_:=triggers[0].(json.Object);config,_:=trigger["config"].(json.Object)
 testing.expect_value(t,config["entity_id"].(string),"filter_chain")
 _,legacy:=config["data"];testing.expect(t,!legacy)
 _,legacy=config["chain_id"];testing.expect(t,!legacy)
 _,tree:=config["filter"].(json.Object);testing.expect(t,tree)
 patch:=make(json.Object,context.temp_allocator);patch["triggers"]=triggers
 encoded,_:=json.marshal(patch,allocator=context.temp_allocator)
 _=action_api_data(t,patch_action_handler(&f.handlers,action_api_request(f,"PATCH",path,string(encoded))))
 after,after_err:=f.repos.actions.triggers_list(f.repos.actions.ctx,domain.Action_ID(id))
 defer domain.action_triggers_destroy(after)
 if !testing.expect(t,after_err.code==.None && len(after)==1) do return
 testing.expect_value(t,after[0].data_filter_json,before[0].data_filter_json)
 testing.expect_value(t,after[0].subject_filter,before[0].subject_filter)
 testing.expect_value(t,after[0].config_json,before[0].config_json)
 testing.expect_value(t,after[0].rev,before[0].rev)
}
