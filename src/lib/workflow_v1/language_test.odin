#+feature dynamic-literals
package workflow_v1

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"

INPUT_SPEC :: `{"schema":"workflow.v1","name":"input_items","inputs":{"topics":{"type":"array","default":["default"]}},"defaults":{"priority":"p1"},"stages":[{"key":"write","title":"Write {{item.title}} {{stage.index}}/{{stage.count}}","for_each":"inputs.topics","brief":{"goal":"{{item}}","acceptance":["{{item.key}}"]}},{"key":"merge","depends_on":["write"],"brief":{"goal":"Merge","acceptance":["done"]}}]}`

@(test)
language_builtin_templates :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    templates:=[?]string{
        string(#load("../../prompts/workflows/explore_plan_build.json")),
        string(#load("../../prompts/workflows/fix_flaky_tests.json")),
        string(#load("../../prompts/workflows/security_audit.json")),
    }
    for raw in templates {
        spec,ok,err:=parse_bounded(raw)
        if !testing.expect(t,ok,err.message) do continue
        testing.expect(t,len(spec.stages)>0)
        snap,serr:=snapshot(spec,`{"goal":"new feature","suite":"tests","target":"src"}`)
        if !testing.expect(t,serr.code==.None,serr.message) do continue
        plan,perr:=plan_stage(snap,spec.stages[0],nil)
        if !testing.expect(t,perr.code==.None,perr.message) do continue
        testing.expect(t,len(plan.items)==1)
        testing.expect(t,!strings.contains(plan.items[0].brief_json,"{{"))
    }
}

@(test)
language_input_fanout_defaults_objects_scalars_and_empty :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    spec,ok,err:=parse_bounded(INPUT_SPEC)
    if !testing.expect(t,ok,err.message) do return
    snap,serr:=snapshot(spec,`{"topics":[{"key":"alpha","title":"Alpha","priority":"p0"},"scalar",3,1.5]}`)
    if !testing.expect(t,serr.code==.None,serr.message) do return
    plan,perr:=plan_stage(snap,spec.stages[0],nil)
    if !testing.expect(t,perr.code==.None,perr.message) do return
    testing.expect_value(t,len(plan.items),4)
    testing.expect_value(t,plan.items[0].title,"Write Alpha 0/4")
    testing.expect_value(t,plan.items[0].priority,"p0")
    testing.expect_value(t,plan.items[1].priority,"p1")
    testing.expect(t,strings.contains(plan.items[1].generated_by_json,`"item_key":"item_1"`))
    testing.expect(t,strings.contains(plan.items[1].generated_by_json,`"item":"scalar"`))
    for raw in ([2]string{`{}`,`{"topics":null}`}) {
        defaults,derr:=snapshot(spec,raw)
        if !testing.expect(t,derr.code==.None,derr.message) do continue
        default_plan,e:=plan_stage(defaults,spec.stages[0],nil)
        testing.expect(t,e.code==.None && len(default_plan.items)==1)
        testing.expect(t,strings.contains(default_plan.items[0].brief_json,"default"))
    }
    empty,eerr:=snapshot(spec,`{"topics":[]}`)
    if !testing.expect(t,eerr.code==.None,eerr.message) do return
    empty_plan,ep:=plan_stage(empty,spec.stages[0],nil)
    testing.expect(t,ep.code==.None && len(empty_plan.items)==0)
    testing.expect_value(t,empty_plan.stage_key,"write")
}

@(test)
language_input_fanout_rejects_invalid_and_oversize_before_plan :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    spec,_,_:=parse_bounded(INPUT_SPEC)
    for raw in ([3]string{`{"topics":"text"}`,`{"topics":{}}`,`{"topics":12}`}) {
        _,err:=snapshot(spec,raw)
        testing.expect(t,err.code==.Validation_Failed,raw)
    }
    values:=strings.repeat("0,",WORKFLOW_FAN_OUT_MAX_ITEMS,context.temp_allocator)
    _,err:=snapshot(spec,fmt.tprintf(`{"topics":[%s0]}`,values))
    testing.expect(t,err.code==.Validation_Failed)
    _,err=snapshot(spec,`[]`)
    testing.expect(t,err.code==.Validation_Failed)
}

@(test)
language_output_fanout_paths_flatten_and_bound :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    spec,_,_:=parse_bounded(INPUT_SPEC)
    snap,_:=snapshot(spec,`{}`)
    views:=map[string]Stage_View{"source"={outputs=[]string{`{"tasks":[{"goal":"one","key":"a"}]}`,`{"tasks":[{"goal":"two","id":"b"}]}`}}}
    for expr in ([6]string{"source.outputs[0].tasks","source.output.tasks","stage.source.output.tasks","stage.source.outputs[0].tasks","source.outputs[].tasks","stage.source.outputs[].tasks"}) {
        stage:=spec.stages[0];stage.for_each=expr;stage.title="{{item.goal}}"
        plan,err:=plan_stage(snap,stage,views)
        if !testing.expect(t,err.code==.None,err.message) do continue
        expected:=1
        if strings.contains(expr,"outputs[]") do expected=2
        testing.expect_value(t,len(plan.items),expected)
        testing.expect_value(t,plan.items[0].title,"one")
        if expected==2 do testing.expect_value(t,plan.items[1].title,"two")
    }
    stage:=spec.stages[0];stage.for_each="source.outputs[].tasks"
    huge:=strings.concatenate({`{"items":[`,strings.repeat("{},",256,context.temp_allocator),`{}]}`},context.temp_allocator)
    views["source"]=Stage_View{outputs=[]string{huge}}
    _,err:=plan_stage(snap,stage,views)
    testing.expect(t,err.code==.Validation_Failed)
    views["source"]=Stage_View{outputs=[]string{`{"items":[]}`}}
    empty,eerr:=plan_stage(snap,stage,views)
    testing.expect(t,eerr.code==.None && len(empty.items)==0)
}

@(test)
language_parallel_gate_and_json_escaping :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    raw:=`{"kind":"workflow","v":1,"stages":[{"id":"copies","parallel":3,"title":"Copy {{stage.index}}","brief":{"goal":"{{inputs.goal}}","output":"inline"}},{"key":"approve","kind":"gate","needs":["copies"],"approver":"user","prompt":"Approve {{stage.copies.output.summary}}?"}]}`
    spec,ok,err:=parse_bounded(raw)
    if !testing.expect(t,ok,err.message) do return
    snap,serr:=snapshot(spec,`{"goal":"Quote \" and slash \\ and newline\n"}`)
    if !testing.expect(t,serr.code==.None,serr.message) do return
    copies,cerr:=plan_stage(snap,spec.stages[0],nil)
    if !testing.expect(t,cerr.code==.None,cerr.message) do return
    testing.expect_value(t,len(copies.items),3)
    for item in copies.items {
        _,parse_err:=json.parse(transmute([]u8)item.brief_json,allocator=context.temp_allocator)
        testing.expect(t,parse_err==nil,item.brief_json)
    }
    views:=map[string]Stage_View{"copies"={outputs=[]string{`{"summary":"ready"}`}}}
    gate,gerr:=plan_stage(snap,spec.stages[1],views)
    if !testing.expect(t,gerr.code==.None,gerr.message) do return
    testing.expect_value(t,len(gate.items),1)
    testing.expect_value(t,gate.items[0].kind,Task_Kind.Gate)
    testing.expect(t,gate.items[0].requires_user_approval)
    testing.expect(t,strings.contains(gate.items[0].brief_json,"Approve ready?"))
}

@(test)
language_output_contracts :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    valid:=[?]struct{brief,output:string}{
        {`{"output":{"schema":"inline","required_fields":["summary"]}}`,`{"summary":"ok"}`},
        {`{"output":"task_list.v1"}`,`{"items":[{"id":"one","brief":{"goal":"one"}}]}`},
        {`{"output":"findings.v1"}`,`{"findings":[{"severity":"high","message":"fix"}]}`},
        {`{"output":"task_list.v1"}`,`{"tasks":[]}`},
    }
    for test in valid do testing.expect(t,validate_task_output_contract(test.brief,test.output).code==.None,test.output)
    invalid:=[?]struct{brief,output:string}{
        {`{"output":{"schema":"inline","required":["summary"]}}`,`{"summary":null}`},
        {`{"output":"inline"}`,`[]`},
        {`{"output":"task_list.v1"}`,`{"tasks":[{"key":"a","goal":"a"},{"key":"a","goal":"b"}]}`},
        {`{"output":"task_list.v1"}`,`{"tasks":[{"title":"missing goal"}]}`},
        {`{"output":"findings.v1"}`,`{"findings":[{"severity":"oops","summary":"fix"}]}`},
    }
    for test in invalid do testing.expect(t,validate_task_output_contract(test.brief,test.output).code==.Validation_Failed,test.output)
}

@(test)
language_boundary_rejects_unknown_malformed_and_ambiguous_types :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    cases:=[?]string{
        `{"schema":"workflow.v1","stages":[{"key":"a","brief":{"goal":"g","acceptance":["a"]},"bogus":true}]}`,
        `{"stages":[{"key":"a","brief":{"goal":"g","acceptance":["a"],"verify":"cmd"}}]}`,
        `{"stages":[{"key":"a","parallel":1.0,"brief":{"goal":"g","acceptance":["a"]}}]}`,
        `{"stages":[{"key":"a","depends_on":"bad","brief":{"goal":"g","acceptance":["a"]}}]}`,
        `{"stages":[{"key":"a","brief":{"goal":"g","acceptance":["a"]}}],}`,
        `{"stages":[{"key":"a","key":"b","brief":{"goal":"g","acceptance":["a"]}}]}`,
        `{"stages":[{"key":"a","kind":"gate","parallel":2}]}`,
        `{"stages":[{"key":"a","kind":"gate","approver":"anyone"}]}`,
        `{"stages":[{"key":"a","depends_on":["b"],"brief":{"goal":"g","acceptance":["a"]}},{"key":"b","depends_on":["a"],"brief":{"goal":"g","acceptance":["a"]}}]}`,
        `{"stages":[{"key":"a","brief":{"goal":"{{item}}","acceptance":["a"]}}]}`,
    }
    for raw in cases {
        _,ok,_:=parse_bounded(raw)
        testing.expect(t,!ok,raw)
    }
}

@(test)
language_on_output_binding_uses_original_scalar_rendering :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    testing.expect_value(t,substitute_on_output_placeholders("{{output.summary}} {{output.count}}",`{"summary":"done","count":2}`),"done 2")
}
