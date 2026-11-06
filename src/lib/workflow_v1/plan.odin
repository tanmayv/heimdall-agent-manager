package workflow_v1

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import jsonx "odin_test:lib/jsonx"
import contracts "odin_test:contracts"

// A plan contains values only. The owner writer must insert the expansion
// marker, tasks, dependencies, provenance and publication intents in one UoW.
// Zero tasks is a successful expansion and must still persist its marker.
Stage_Item :: struct {
    index: int,
    title, description, brief_json, priority, generated_by_json: string,
    kind: Task_Kind,
    requires_user_approval: bool,
    max_parallel: int,
}
Stage_Plan :: struct {
    stage_key: string,
    items: []Stage_Item,
}

// snapshot validates all input fan-outs before a run can create any tasks.
// Inputs and definitions are retained verbatim by the caller for every retry.
snapshot :: proc(spec: Workflow_Parsed_Spec, inputs_json: string) -> (Workflow_Run_Snapshot, Error) {
    if len(inputs_json)>MAX_SPEC_BYTES do return {},language_error(.Validation_Failed,"workflow inputs exceed bound")
    if _,strict:=contracts.owner_request_document(inputs_json);!strict do return {},language_error(.Validation_Failed,"malformed workflow inputs")
    v, err := json.parse(transmute([]u8)inputs_json, allocator = context.temp_allocator)
    if err != nil do return {}, language_error(.Validation_Failed, "workflow inputs must be an object")
    if _, obj := v.(json.Object); !obj do return {}, language_error(.Validation_Failed, "workflow inputs must be an object")
    if verr := validate_workflow_run_inputs(spec, inputs_json); verr.code != .None do return {}, verr
    return Workflow_Run_Snapshot{spec=spec, inputs_json=inputs_json, inputs_members=jsonx_top_level_members(inputs_json)}, {}
}

// plan_stage matches materialize_single_stage_in_uow in the original runtime;
// callers invoke it only after every declared prerequisite stage succeeds.
plan_stage :: proc(snap: Workflow_Run_Snapshot, st: Workflow_Stage_Spec, views: map[string]Stage_View, default_user_approval := false) -> (Stage_Plan, Error) {
    raw_items := make([dynamic]string, context.temp_allocator)
    input_field, from_input := parse_for_each_input_expr(st.for_each)
    upstream := ""
    if from_input {
        items, err := resolve_for_each_input_items(st.key, input_field, snap.inputs_members, snap.spec.inputs)
        if err.code != .None do return {}, err
        append(&raw_items, ..items)
    } else if st.for_each != "" {
        field: string
        valid: bool
        upstream, field, valid = parse_for_each_expr(st.for_each)
        if !valid do return {}, language_error(.Validation_Failed, "invalid for_each expression")
        source := views[upstream].outputs
        if !strings.contains(st.for_each, "outputs[]") && len(source)>1 do source=source[:1]
        for output in source {
            append(&raw_items, ..extract_for_each_array_items(output,field))
            if err:=workflow_check_fan_out_size(st.key,st.for_each,len(raw_items),false); err.code!=.None do return {},err
        }
    } else {
        for _ in 0..<max(st.parallel,1) do append(&raw_items,"{}")
    }
    if err:=workflow_check_fan_out_size(st.key,st.for_each,len(raw_items),from_input);err.code!=.None do return {},err
    planned:=make([]Stage_Item,len(raw_items),context.temp_allocator)
    for raw,i in raw_items {
        title:=substitute_workflow_placeholders(st.title,snap,st.key,i,len(raw_items),raw,views,false)
        desc:=substitute_workflow_placeholders(st.description,snap,st.key,i,len(raw_items),raw,views,false)
        brief:=""
        if st.kind==.Gate {
            prompt:=substitute_workflow_placeholders((st.prompt if st.prompt!="" else st.title),snap,st.key,i,len(raw_items),raw,views,false)
            g:=json_begin(); json_str(&g,"approver",st.approver);json_str(&g,"prompt",prompt)
            b:=json_begin();json_str(&b,"goal",prompt);json_str(&b,"approver",st.approver);json_str(&b,"prompt",prompt);json_raw(&b,"gate",json_end(&g))
            brief=json_end(&b)
        } else {
            brief=substitute_workflow_placeholders(st.brief_raw,snap,st.key,i,len(raw_items),raw,views,true,preserve_output=true)
        }
        priority:=st.priority
        if priority=="" do priority=jsonx.extract_string(snap.spec.defaults_raw,"priority","p2",true,context.temp_allocator)
        if st.for_each!="" && strings.has_prefix(strings.trim_space(raw),"{") {
            if p:=jsonx.extract_string(raw,"priority","",true,context.temp_allocator);p!="" do priority=p
        }
        provenance:=json_begin()
        if st.for_each!="" {
            json_str(&provenance,("input" if from_input else "stage"),(input_field if from_input else upstream))
            key:=""
            if strings.has_prefix(strings.trim_space(raw),"{") {
                key=jsonx.extract_string(raw,"key","",true,context.temp_allocator)
                if key=="" do key=jsonx.extract_string(raw,"id","",true,context.temp_allocator)
            }
            if key=="" do key=fmt.tprintf("item_%d",i)
            json_str(&provenance,"item_key",key)
            json_raw(&provenance,"item_index",fmt.tprintf("%d",i))
            json_raw(&provenance,"item",raw)
        } else {
            json_str(&provenance,"stage",st.key)
        }
        user:=st.requires_user_approval if st.has_requires_user_approval else default_user_approval
        if st.kind==.Gate && st.approver=="user" do user=true
        planned[i]=Stage_Item{i,title,desc,brief,priority,json_end(&provenance),st.kind,user,st.max_parallel}
    }
    return Stage_Plan{st.key,planned},{}
}
