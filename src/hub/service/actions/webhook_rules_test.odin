package actions

import "core:encoding/json"
import "core:strings"
import "core:testing"
import "core:fmt"
import "core:unicode/utf8"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"

@(test)
test_webhook_nested_projection_and_render :: proc(t:^testing.T) {
 context.allocator=context.temp_allocator
 envelope:=test_config(`{"entity":{"kind":"webhook","id":"wh_test"},"actor":"webhook:wh_test","data":{"repo":{"name":"hello {{action.name}}\u001b\n"},"count":42,"ok":true}}`)
 raw:=test_config(`{"field":"data.repo.name","op":"prefix","value":"hello"}`)
 tree,e:=filter_compile(raw,event_descriptor_find("webhook.received"),FILTER_DEFAULT_LIMITS)
 testing.expect_value(t,e.reason,"")
 projection:=snapshot_projection(tree,"{{event.data.repo.name}}/{{event.data.count}}/{{event.json}}",context.allocator)
 snapshot:=event_params({event_type="webhook.received",event_id="evt",envelope=envelope},1,"T",projection)
 params:=test_config(snapshot)
 count,exists:=snapshot_lookup(params,[]string{"data","count"})
 testing.expect(t,exists)
 n,typed:=count.(json.Integer)
 testing.expect(t,typed && n==42)
 name,_:=snapshot_lookup(params,[]string{"data","repo","name"})
 text,_:=name.(string)
 testing.expect_value(t,text,"hello {{action.name}}\x1b\n")
 body:=render("{{event.data.repo.name}}/{{event.data.count}}",{name="EXPANDED"},{event_type="webhook.received",event_params_json=snapshot},0,context.allocator)
 testing.expect_value(t,body,"hello {{action.name}}/42\n"+WEBHOOK_UNTRUSTED_LINE)
 plain:=render("{{action.name}}",{name="own prompt"},{event_type="webhook.received",event_params_json=snapshot},0,context.allocator)
 testing.expect_value(t,plain,"own prompt")
 trusted:=render("{{event.data.repo.name}}",{},{event_type="memory.state",event_params_json=snapshot},0,context.allocator)
 testing.expect(t,!strings.contains(trusted,WEBHOOK_UNTRUSTED_LINE))
}

@(test)
test_webhook_snapshot_large_body :: proc(t:^testing.T) {action_test_case(t,webhook_large_body)}
webhook_large_body :: proc(t:^testing.T,f:^Action_Test) {
 repo:=&f.repos.actions
 action,found,err:=repo.get(repo.ctx,"action")
 testing.expect(t,found && err.code==.None)
 defer domain.action_destroy(&action)
 replace_string(&action.prompt_text,"{{event.data.repo.name}} {{event.json}}")
 testing.expect_value(t,repo.save(repo.ctx,action).code,domain.Error_Code.None)
 raw:=test_config(`{"field":"data.long","op":"prefix","value":"match"}`)
 testing.expect_value(t,repo.trigger_save(repo.ctx,{trigger_id="trigger",action_id="action",owner_user_id="owner",kind="event",enabled=true,rev=3,event_type="webhook.received",subject_filter="ev.owner.webhook.*.received",data_filter_json=snapshot_encode(raw),config_json="{}",created_at="2026-01-01T00:00:00Z",updated_at="2026-01-01T00:00:00Z"}).code,domain.Error_Code.None)
 envelope:=test_config(`{"entity":{"kind":"webhook","id":"wh1"},"owner_user_id":"owner","actor":"webhook:wh1","data":{"repo":{"name":"requested"}}}`)
 data,_:=envelope["data"].(json.Object)
 data["long"]=strings.concatenate({"match",strings.repeat("é",5120,context.temp_allocator)},context.temp_allocator)
 // Make the compact body exactly the ingress limit, including JSON overhead.
 encoded:=snapshot_encode(data)
 data["padding"]=strings.repeat("x",65536-len(encoded)-len(`,"padding":""`),context.temp_allocator)
 envelope["data"]=data
 testing.expect_value(t,len(snapshot_encode(data)),65536)
 // Equality on the entire 10 KiB string proves evaluation precedes projection.
 full_filter:=test_config(`{"field":"data.long","op":"eq","value":""}`)
 full_filter["value"]=data["long"]
 trigger,trigger_found,trigger_err:=repo.trigger_get(repo.ctx,"trigger")
 testing.expect(t,trigger_found && trigger_err.code==.None)
 defer domain.action_trigger_destroy(&trigger)
 replace_string(&trigger.data_filter_json,snapshot_encode(full_filter))
 testing.expect_value(t,repo.trigger_save(repo.ctx,trigger).code,domain.Error_Code.None)
 testing.expect(t,handle_message(&f.runtime,{subject="ev.owner.webhook.wh1.received",event_type="webhook.received",event_id="evt_large",stream_time_ms=f.now_ms,envelope=envelope}))
 rows:=action_test_rows(t,f)
 defer domain.action_runs_destroy(rows)
 if !testing.expect_value(t,len(rows),1) do return
 testing.expect_value(t,rows[0].state,domain.ACTION_RUN_QUEUED)
 testing.expect(t,len(rows[0].event_params_json)<=8192)
 params:=test_config(rows[0].event_params_json)
 value,present:=snapshot_lookup(params,[]string{"data","long"})
 text,ok:=value.(string)
 testing.expect(t,present && ok && len(text)<=2048 && strings.contains(text,"…[truncated "))
 testing.expect(t,utf8.valid_string(text))
 nested,_:=snapshot_lookup(params,[]string{"data","repo","name"})
 name,_:=nested.(string)
 testing.expect_value(t,name,"requested")
 trace,_:=params["_match"].(json.Object)
 nodes,_:=trace["nodes"].(string)
 testing.expect_value(t,nodes,"T")
 event_json,_:=params["json"].(string)
 fallback:=test_config(event_json)
 truncated,_:=fallback["_truncated"].(bool)
 testing.expect(t,truncated)
 // Rendering event.json preserves valid JSON rather than cutting a token.
 body:=render("{{event.json}}",{},rows[0],0,context.temp_allocator)
 line:=strings.index(body,"\n"+WEBHOOK_UNTRUSTED_LINE)
 testing.expect(t,line>0)
 parsed:json.Value
 if line>0 do testing.expect_value(t,json.unmarshal_string(body[:line],&parsed,allocator=context.temp_allocator),nil)
}

@(test)
test_snapshot_object_markers_and_parent_priority :: proc(t:^testing.T) {
 context.allocator=context.temp_allocator
 envelope:=test_config(`{"data":{"parent":{"child":true},"large":{"x":""}}}`)
 data,_:=envelope["data"].(json.Object)
 large,_:=data["large"].(json.Object)
 large["x"]=strings.repeat("quote\"\\",3000,context.temp_allocator)
 data["large"]=large
 envelope["data"]=data
 tree,_:=filter_compile(test_config(`{"field":"data.parent.child","op":"eq","value":true}`),nil,FILTER_DEFAULT_LIMITS)
 projection:=snapshot_projection(tree,"{{event.data.large}} {{event.data.parent}}",context.allocator)
 snapshot:=event_params({event_type="webhook.received",envelope=envelope},1,"T",projection)
 testing.expect(t,len(snapshot)<=8192)
 params:=test_config(snapshot)
 marker,present:=snapshot_lookup(params,[]string{"data","large","_truncated"})
 truncated,typed:=marker.(bool)
 testing.expect(t,present && typed && truncated)
 child,child_present:=snapshot_lookup(params,[]string{"data","parent","child"})
 flag,_:=child.(bool)
 testing.expect(t,child_present && flag)
 small:=event_params({event_type="webhook.received",envelope=test_config(`{"data":{"ok":true}}`)},1,"",snapshot_projection({},"{{event.json}}",context.allocator))
 small_params:=test_config(small)
 compact,_:=small_params["json"].(string)
 testing.expect_value(t,compact,`{"ok":true}`)
 rendered:=render("author\n{{event.data.large}}",{},{event_type="webhook.received",event_params_json=snapshot},0,context.allocator)
 testing.expect(t,strings.has_prefix(rendered,"author\n"),"author text retains its own control characters")
 testing.expect(t,strings.contains(rendered,WEBHOOK_UNTRUSTED_LINE),"truncated objects still require the untrusted-data line")
}

@(test)
test_webhook_batch_untrusted_line_once :: proc(t:^testing.T) {action_test_case(t,webhook_batch_untrusted)}
webhook_batch_untrusted :: proc(t:^testing.T,f:^Action_Test) {
 run:=domain.Action_Run{event_type="webhook.received",event_params_json=`{"data":{"x":"hello"}}`}
 action:=domain.Action{prompt_text="{{event.data.x}}"}
 body,_,_,err:=batch_render(&f.repos.actions,[]Prepared_Run{{action,run},{action,run}})
 testing.expect_value(t,err.code,domain.Error_Code.None)
 first:=strings.index(body,WEBHOOK_UNTRUSTED_LINE)
 testing.expect(t,first>=0)
 if first>=0 do testing.expect_value(t,strings.index(body[first+len(WEBHOOK_UNTRUSTED_LINE):],WEBHOOK_UNTRUSTED_LINE),-1)
}

@(test)
test_snapshot_priority_and_omissions :: proc(t:^testing.T) {
 context.allocator=context.temp_allocator
 envelope:=test_config(`{"entity":{"kind":"memory","id":"m1"},"data":{"nested":{"flag":true}}}`)
 data,_:=envelope["data"].(json.Object)
 for i in 0..<8 do data[fmt.tprintf("v%d",i)]=strings.repeat("x",2000,context.temp_allocator)
 envelope["data"]=data
 tree,e:=filter_compile(test_config(`{"field":"data.v7","op":"exists","value":true}`),nil,FILTER_DEFAULT_LIMITS)
 testing.expect_value(t,e.reason,"")
 prompt:strings.Builder
 defer strings.builder_destroy(&prompt)
 for i in 0..<7 do strings.write_string(&prompt,strings.concatenate({"{{event.data.v",fmt.tprintf("%d",i),"}}"},context.temp_allocator))
 p:=snapshot_projection(tree,strings.to_string(prompt),context.allocator)
 snapshot:=event_params({event_type="memory.state",envelope=envelope},1,"T",p)
 testing.expect(t,len(snapshot)<=8192)
 params:=test_config(snapshot)
 _,kept:=snapshot_lookup(params,[]string{"data","v7"})
 testing.expect(t,kept,"filter path has highest data priority")
 _,first:=snapshot_lookup(params,[]string{"data","v0"})
 testing.expect(t,first,"first template path precedes later paths")
 omitted,_:=params["_omitted"].(json.Array)
 testing.expect(t,len(omitted)>0)
 first_omitted,_:=omitted[0].(string)
 testing.expect_value(t,first_omitted,"data.v2")
 body:=render("{{event.data.v6}}",{},{event_params_json=snapshot},0,context.allocator)
 testing.expect_value(t,body,"")
 nested_tree,_:=filter_compile(test_config(`{"field":"data.nested.flag","op":"eq","value":true}`),nil,FILTER_DEFAULT_LIMITS)
 nested_snapshot:=event_params({event_type="memory.state",envelope=envelope},1,"T",snapshot_projection(nested_tree,"",context.allocator))
 flag,present:=snapshot_lookup(test_config(nested_snapshot),[]string{"data","nested","flag"})
 boolean,typed:=flag.(bool)
 testing.expect(t,present && typed && boolean,"all event types retain typed nested seen values")
}

@(test)
test_snapshot_template_path_limit :: proc(t:^testing.T) {
 context.allocator=context.temp_allocator
 envelope:=test_config(`{"data":{}}`)
 data,_:=envelope["data"].(json.Object)
 prompt:strings.Builder
 defer strings.builder_destroy(&prompt)
 for i in 0..<1000 {
  key:=fmt.tprintf("key%d",i)
  data[key]="value"
  strings.write_string(&prompt,strings.concatenate({"{{event.data.",key,"}}"},context.temp_allocator))
 }
 envelope["data"]=data
 p:=snapshot_projection({},strings.to_string(prompt),context.allocator)
 testing.expect_value(t,len(p.paths),64)
 testing.expect_value(t,p.overflow_count,936)
 snapshot:=event_params({event_type="webhook.received",envelope=envelope},1,"",p)
 testing.expect(t,len(snapshot)<=8192)
 params:=test_config(snapshot)
 omitted,_:=params["_omitted"].(json.Array)
 count,_:=params["_omitted_count"].(json.Integer)
 testing.expect_value(t,len(omitted),32)
 testing.expect_value(t,count,json.Integer(936))
}

@(test)
test_webhook_rule_delay_and_ownership :: proc(t:^testing.T) {actions_track(t,webhook_rule_service)}
webhook_rule_service :: proc(t:^testing.T) {service_case(t,webhook_rule_scenario)}
webhook_rule_scenario :: proc(t:^testing.T,s:^Service,db:^sqlite.Conn) {
 impl:sqlite.Event_Webhook_Repo_SQLite
 s.repos.webhooks=sqlite.new_event_webhook_repository(&impl,db)
 repo:=&s.repos.webhooks
 uow,began,_:=iface.unit_of_work_begin(s.factory)
 if !testing.expect(t,began) do return
 testing.expect_value(t,repo.save(repo.ctx,{webhook_id="wh_own",owner_user_id="owner",name="own",enabled=true,token_hash="hash",created_at="now",updated_at="now"}).code,domain.Error_Code.None)
 testing.expect_value(t,repo.save(repo.ctx,{webhook_id="wh_other",owner_user_id="other",name="other",enabled=true,token_hash="hash2",created_at="now",updated_at="now"}).code,domain.Error_Code.None)
 committed,_:=iface.unit_of_work_commit(&uow)
 testing.expect(t,committed)
 input:=test_input()
 triggers:=[]Trigger_Input{{kind="event",config=test_config(`{"event_type":"webhook.received","entity_id":"wh_own","filter":{"field":"data.repo.name","op":"eq","value":"repo"}}`),delay_s=1}}
 input.triggers=triggers
 failed,err:=create(s,"owner",input)
 action_view_destroy(&failed)
 testing.expect(t,strings.contains(err.details_json,"delay_not_supported"))
 triggers[0].delay_s=0
 own,own_err:=create(s,"owner",input)
 defer action_view_destroy(&own)
 if !testing.expect_value(t,own_err.code,domain.Error_Code.None) do return
 testing.expect_value(t,own.triggers[0].subject_filter,"ev.owner.webhook.wh_own.received")
 for id in ([]string{"wh_other","wh_missing"}) {
  triggers[0].config["entity_id"]=id
  view,e:=create(s,"owner",input)
  action_view_destroy(&view)
  testing.expect(t,strings.contains(e.details_json,"unknown_entity"))
 }
}
