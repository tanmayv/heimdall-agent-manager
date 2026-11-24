package actions

import "core:encoding/json"
import "core:fmt"
import "core:testing"
import "core:strings"
import "core:mem"
import domain "odin_test:hub/domain"
import sqlite "odin_test:hub/repository/sqlite"

@(test)
test_filter_operator_matrix :: proc(t:^testing.T) {actions_track(t,filter_operator_matrix)}
filter_operator_matrix :: proc(t:^testing.T) {
 cases:=[?]struct{json:string,positive,exists,prefix:bool}{
  {`"3"`,true,true,true},{`3`,true,true,false},{`true`,false,true,false},
  {`null`,false,false,false},{`{}`,false,true,false},{`[]`,false,true,false},{``,false,false,false},
 }
 // Empty data exercises an absent final segment; an absent data object only
 // exercises the intermediate segment. Both must obey identical semantics.
 leaf_absent:=test_config(`{"data":{}}`)
 for tc in cases {
  sample:="{}"
  if tc.json!="" do sample=fmt.tprintf("%s%s%s",`{"data":{"x":`,tc.json,`}}`)
  event:json.Value
  testing.expect(t,json.unmarshal_string(sample,&event)==nil)
  envelope,_:=event.(json.Object)
  for op in FILTER_OPERATORS {
   value:=`"3"`
   if op=="in" || op=="not_in" do value=`["3"]`
   if op=="exists" do value=`true`
   raw:json.Value
   source:=fmt.tprintf("%s%s%s%s%s",`{"field":"data.x","op":"`,op,`","value":`,value,`}`)
   testing.expect(t,json.unmarshal_string(source,&raw)==nil)
   tree,e:=filter_compile(raw,nil,FILTER_DEFAULT_LIMITS)
   testing.expect_value(t,e.reason,"")
   expected:=tc.positive
   if op=="ne" || op=="not_in" do expected=!expected
   if op=="exists" do expected=tc.exists
   if op=="prefix" do expected=tc.prefix
   matched,_:=filter_evaluate(tree,envelope)
   full,trace:=filter_evaluate(tree,envelope,true)
   testing.expect(t,matched==expected,fmt.tprintf("%s %s",op,tc.json))
   testing.expect_value(t,full,matched)
   testing.expect_value(t,trace,"T" if expected else "F")
   missing,_:=filter_evaluate(tree,leaf_absent)
   missing_full,missing_trace:=filter_evaluate(tree,leaf_absent,true)
   expected_missing:=op=="ne" || op=="not_in"
   testing.expect_value(t,missing,expected_missing)
   testing.expect_value(t,missing_full,missing)
   delete(missing_trace)
   if op=="exists" {
    tree.nodes[0].exists=false
    inverted,_:=filter_evaluate(tree,envelope)
    missing_false,_:=filter_evaluate(tree,leaf_absent)
    testing.expect_value(t,inverted,!tc.exists)
    testing.expect(t,missing_false)
   }
   delete(trace)
   filter_destroy(&tree)
   json.destroy_value(raw)
  }
  json.destroy_value(event)
 }
}
@(test)
test_filter_nested_trace :: proc(t:^testing.T) {actions_track(t,filter_nested_trace)}
filter_nested_trace :: proc(t:^testing.T) {
 raw:json.Value
 testing.expect(t,json.unmarshal_string(`{"all":[{"any":[{"field":"actor","op":"eq","value":"user"},{"field":"actor","op":"eq","value":"hub"}]},{"not":{"field":"actor","op":"eq","value":"hub"}}]}`,&raw)==nil)
 defer json.destroy_value(raw)
 tree,e:=filter_compile(raw,nil,FILTER_DEFAULT_LIMITS)
 defer filter_destroy(&tree)
 testing.expect_value(t,e.reason,"")
 envelope:=make(json.Object)
 defer delete(envelope)
 envelope["actor"]="user"
 fast,_:=filter_evaluate(tree,envelope)
 full,trace:=filter_evaluate(tree,envelope,true)
 defer delete(trace)
 testing.expect(t,fast && full)
 testing.expect_value(t,trace,"TTTFTF")
}

@(test)
test_filter_validation_limits :: proc(t:^testing.T) {actions_track(t,filter_validation_limits)}
filter_validation_limits :: proc(t:^testing.T) {
 leaf:=`{"field":"actor","op":"eq","value":"user"}`
 pair:=fmt.tprintf("%s%s%s%s%s",`{"all":[`,leaf,`,`,leaf,`]}`)
 cases:=[?]struct{raw,reason,path:string,limit:string}{
  {`null`,"unknown_node","",""},
  {`{"all":[],"extra":true}`,"unknown_node","",""},
  {`{"all":[]}`,"empty_group","",""},
  {`{"not":{"field":"data.a.b.c.d.e","op":"eq","value":"x"}}`,"unknown_field","/not",""},
  {`{"field":"data.a..b","op":"eq","value":"x"}`,"unknown_field","",""},
  {`{"field":"actor","op":"oops","value":true}`,"unknown_op","",""},
  {`{"field":"actor","op":"eq","value":null}`,"bad_value","",""},
  {`{"field":"actor","op":"exists","value":"true"}`,"bad_value","",""},
  {`{"field":"actor","op":"prefix","value":""}`,"bad_value","",""},
  {`{"field":"actor","op":"in","value":[]}`,"bad_value","",""},
  {pair,"too_deep","/all/0","depth"},
  {pair,"too_many_nodes","/all/1","checks"},
  {pair,"too_many_nodes","/all/1","nodes"},
  {pair,"too_many_nodes","","children"},
  {pair,"too_large","","bytes"},
  {`{"field":"actor","op":"in","value":["a","b"]}`,"bad_value","","values"},
  {leaf,"bad_value","","value_bytes"},
  {leaf,"unknown_field","","field_bytes"},
  {`{"field":"data.ab","op":"eq","value":"x"}`,"unknown_field","","segment_bytes"},
  {`{"field":"data.a.b","op":"eq","value":"x"}`,"unknown_field","","segments"},
 }
 for tc in cases {
  limits:=FILTER_DEFAULT_LIMITS
  switch tc.limit {
  case "depth": limits.max_depth=1
  case "checks": limits.max_checks=1
  case "nodes": limits.max_nodes=2
  case "children": limits.max_children=1
  case "bytes": limits.max_bytes=2
  case "values": limits.max_values=1
  case "value_bytes": limits.max_value_bytes=1
  case "field_bytes": limits.max_field_bytes=1
  case "segment_bytes": limits.max_segment_bytes=1
  case "segments": limits.max_path_segments=1
  }
  raw:json.Value
  testing.expect(t,json.unmarshal_string(tc.raw,&raw)==nil)
  tree,e:=filter_compile(raw,nil,limits)
  testing.expect_value(t,e.reason,tc.reason)
  testing.expect_value(t,e.path,tc.path)
  filter_destroy(&tree)
  json.destroy_value(raw)
 }
 // Field syntax defaults, including the byte caps, are enforced independently.
 for field in ([]string{strings.repeat("x",129,context.temp_allocator),fmt.tprintf("data.%s",strings.repeat("x",65,context.temp_allocator))}) {
  raw:=make(json.Object)
  raw["field"]=field;raw["op"]="eq";raw["value"]="x"
  tree,e:=filter_compile(raw,nil,FILTER_DEFAULT_LIMITS)
  testing.expect_value(t,e.reason,"unknown_field")
  filter_destroy(&tree);delete(raw)
 }
}

@(test)
test_filter_event_contract_and_delay :: proc(t:^testing.T) {actions_track(t,filter_contract_tracked)}
filter_contract_tracked :: proc(t:^testing.T) {service_case(t,filter_contract_scenario)}
filter_contract_scenario :: proc(t:^testing.T,s:^Service,db:^sqlite.Conn) {
 service_foreign_chain(t,s,db)
 compile_case(t,"event",`{"event_type":"chain.state","data":{}}`,"invalid_config","")
 compile_case(t,"event",`{"event_type":"chain.state","chain_id":"c"}`,"invalid_config","")
 compile_case(t,"event",`{"event_type":"chain.state","filter":null}`,"unknown_node","")
 compile_case(t,"event",`{"event_type":"chain.state","filter":{"all":[{"field":"entity.id","op":"eq","value":"c"}]}}`,"","ev.owner.chain.c.state")
 compile_case(t,"event",`{"event_type":"chain.state","filter":{"field":"entity.id","op":"eq","value":"c"}}`,"","ev.owner.chain.c.state")
 config:=test_config(`{"event_type":"chain.state","filter":{"field":"data.state","op":"eq","value":"completed"}}`)
 spec,err:=event_compile("owner","a","t",config,context.allocator)
 defer match_spec_destroy(&spec)
 testing.expect_value(t,err.code,domain.Error_Code.None)
 testing.expect_value(t,spec.data_filter_json,`{"all":[{"field":"data.state","op":"eq","value":"completed"}]}`)
 // Preserve the descriptor layout and restore the flag before other tests run.
 descriptor:=event_descriptor_find("chain.state")
 saved:=descriptor.no_delay
 descriptor.no_delay=true
 defer descriptor.no_delay=saved
 input:=test_input()
 input.triggers=[]Trigger_Input{{kind="event",config=config,delay_s=1}}
 view,e:=create(s,"owner",input)
 defer action_view_destroy(&view)
 testing.expect(t,strings.contains(e.details_json,"delay_not_supported"))
}

@(test)
test_filter_stored_rules_survive_lower_save_limits :: proc(t:^testing.T) {
 config:=test_config(`{"event_type":"chain.state","filter":{"all":[{"field":"actor","op":"eq","value":"user"},{"field":"data.state","op":"eq","value":"completed"}]}}`)
 spec,err:=event_compile("owner","a","t",config,context.allocator)
 defer match_spec_destroy(&spec)
 testing.expect_value(t,err.code,domain.Error_Code.None)
 lowered:=FILTER_DEFAULT_LIMITS
 lowered.max_checks=1
 rejected,e:=event_compile_limits("owner","a","t",config,lowered,context.allocator)
 defer match_spec_destroy(&rejected)
 testing.expect_value(t,e.code,domain.Error_Code.Validation_Failed)
 event:=test_config(`{"actor":"user","data":{"state":"completed"}}`)
 testing.expect(t,data_matches(spec.data_filter_json,event))
}

@(test)
test_filter_compiled_evaluation_allocates_nothing :: proc(t:^testing.T) {
 raw:=test_config(`{"all":[{"any":[{"field":"data.x","op":"eq","value":"3"}]},{"field":"actor","op":"prefix","value":"u"},{"field":"data.ok","op":"eq","value":true},{"field":"data.f","op":"eq","value":1.5}]}`)
 tree,e:=filter_compile(raw,nil,FILTER_DEFAULT_LIMITS)
 defer filter_destroy(&tree)
 testing.expect_value(t,e.reason,"")
 event:=test_config(`{"actor":"user","data":{"x":3,"ok":true,"f":1.5}}`)
 event["actor"]="hub"
 fast,_:=filter_evaluate(tree,event)
 full,trace:=filter_evaluate(tree,event,true)
 testing.expect(t,!fast && full==fast)
 testing.expect_value(t,trace,"FTTFTT")
 delete(trace)
 event["actor"]="user"
 track:mem.Tracking_Allocator
 mem.tracking_allocator_init(&track,context.allocator)
 defer mem.tracking_allocator_destroy(&track)
 before:=context
 context.allocator=mem.tracking_allocator(&track)
 context.temp_allocator=context.allocator
 matched,_:=filter_evaluate(tree,event)
 context=before
 testing.expect(t,matched)
 testing.expect_value(t,track.total_allocation_count,i64(0))
}
