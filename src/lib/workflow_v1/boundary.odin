package workflow_v1


import "core:encoding/json"
import "core:strings"
import contracts "odin_test:contracts"

MAX_STAGES :: 32
MAX_SPEC_BYTES :: 256*1024

keys_allowed :: proc(o:json.Object,names:string)->bool {
    for key in o {
        found:=false
        for name in strings.split(names,"|",context.temp_allocator) { if name==key { found=true;break } }
        if !found do return false
    }
    return true
}
string_member :: proc(o:json.Object,key:string)->bool {
    v,present:=o[key]
    if !present do return true
    _,text:=v.(json.String)
    return text
}
array_strings :: proc(v:json.Value)->bool {
    a,ok:=v.(json.Array)
    if !ok do return false
    for item in a { if _,text:=item.(json.String);!text do return false }
    return true
}
object_member :: proc(o:json.Object,key:string)->bool {
    v,present:=o[key]
    if !present do return true
    _,obj:=v.(json.Object)
    return obj
}
output_shape :: proc(v:json.Value)->bool {
    if s,text:=v.(json.String);text {
        return s=="none" || s=="inline" || s=="task_list.v1" || s=="findings.v1"
    }
    o,obj:=v.(json.Object)
    if !obj || !keys_allowed(o,"schema|kind|required_fields|required") do return false
    for key in ([2]string{"schema","kind"}) {
        if s,present:=o[key];present {
            text,ok:=s.(json.String)
            if !ok || (text!="inline" && text!="task_list.v1" && text!="findings.v1") do return false
        }
    }
    for key in ([2]string{"required_fields","required"}) { if a,present:=o[key];present && !array_strings(a) do return false }
    return true
}
brief_shape :: proc(o:json.Object)->bool {
    if !keys_allowed(o,"goal|acceptance|inputs|review_roles|assignee|reviewers|budget|output|on_output|requires_user_approval|approver|gate") do return false
    for key in ([3]string{"goal","assignee","approver"}) { if !string_member(o,key) do return false }
    for key in ([3]string{"acceptance","review_roles","reviewers"}) { if a,present:=o[key];present && !array_strings(a) do return false }
    if out,present:=o["output"];present && !output_shape(out) do return false
    if trigger,present:=o["on_output"];present {
        t,obj:=trigger.(json.Object)
        if !obj || !keys_allowed(t,"start_workflow|workflow|inputs") || !string_member(t,"start_workflow") || !string_member(t,"workflow") || !object_member(t,"inputs") do return false
        if _,a:=t["start_workflow"];!a { if _,b:=t["workflow"];!b do return false }
    }
    if approval,present:=o["requires_user_approval"];present { if _,ok:=approval.(json.Boolean);!ok do return false }
    return true
}

// Strict owner boundary for the original language, distinct from its historical
// permissive scanner. Decoded duplicate keys, malformed JSON, unknown behavior,
// command fields removed from the product, and unbounded definitions fail closed.
// Like existing owner-local requirement bodies, this boundary uses the strict
// owner document reader; rendered human strings remain document values.
parse_bounded :: proc(raw:string)->(Workflow_Parsed_Spec,bool,Error) {
    bad:=language_error(.Validation_Failed,"malformed or unsupported workflow.v1 definition")
    if len(raw)>MAX_SPEC_BYTES do return {},false,bad
    v,valid:=contracts.owner_request_document(raw);o,obj:=v.(json.Object)
    if !valid || !obj || !keys_allowed(o,"schema|kind|version|v|name|id|title|description|inputs|defaults|stages") do return {},false,bad
    for key in ([6]string{"schema","kind","name","id","title","description"}) { if !string_member(o,key) do return {},false,bad }
    for key in ([2]string{"v","version"}) { if n,present:=o[key];present { i,ok:=n.(json.Integer);if !ok || i<1 do return {},false,bad } }
    if d,present:=o["defaults"];present { defaults,ok:=d.(json.Object);if !ok || !keys_allowed(defaults,"priority") || !string_member(defaults,"priority") do return {},false,bad }
    if inputs,present:=o["inputs"];present && !inputs_shape(inputs) do return {},false,bad
    stages,arr:=o["stages"].(json.Array)
    if !arr || len(stages)==0 || len(stages)>MAX_STAGES do return {},false,bad
    for value in stages {
        st,ok:=value.(json.Object)
        if !ok || !keys_allowed(st,"key|id|kind|title|description|depends_on|needs|for_each|parallel|max_parallel|priority|brief|output|gate|approver|prompt|requires_user_approval") do return {},false,bad
        for key in ([9]string{"key","id","kind","title","description","for_each","priority","approver","prompt"}) { if !string_member(st,key) do return {},false,bad }
        for key in ([2]string{"depends_on","needs"}) { if a,present:=st[key];present && !array_strings(a) do return {},false,bad }
        for key in ([2]string{"parallel","max_parallel"}) { if n,present:=st[key];present { i,integer:=n.(json.Integer);if !integer || i<1 || i>50 do return {},false,bad } }
        for key in ([3]string{"title","description","prompt"}) { if text,present:=st[key];present { value,_:=text.(json.String);if !template_shape(string(value),false) do return {},false,bad } }
        if b,present:=st["brief"];present {
            brief,object:=b.(json.Object)
            if !object || !brief_shape(brief) do return {},false,bad
            for key,value in jsonx_top_level_members(st_to_json(brief)) { if !template_shape(value,key=="on_output") do return {},false,bad }
        }
        if out,present:=st["output"];present && !output_shape(out) do return {},false,bad
        if g,present:=st["gate"];present {
            gate,object:=g.(json.Object)
            if !object || !keys_allowed(gate,"approver|prompt") || !string_member(gate,"approver") || !string_member(gate,"prompt") do return {},false,bad
        }
        if approval,present:=st["requires_user_approval"];present { if _,boolean:=approval.(json.Boolean);!boolean do return {},false,bad }
    }
    return parse_and_validate_workflow_spec(raw)
}


input_shape :: proc(o:json.Object,named:bool)->bool {
    if !keys_allowed(o,"name|key|type|required|default|description") do return false
    for key in ([4]string{"name","key","type","description"}) { if !string_member(o,key) do return false }
    if named {
        name,_:=o["name"].(json.String)
        alias,_:=o["key"].(json.String)
        if name=="" && alias=="" do return false
    }
    if v,present:=o["required"];present { if _,boolean:=v.(json.Boolean);!boolean do return false }
    return true
}
inputs_shape :: proc(v:json.Value)->bool {
    if a,array:=v.(json.Array);array {
        if len(a)>128 do return false
        for value in a { o,obj:=value.(json.Object);if !obj || !input_shape(o,true) do return false }
        return true
    }
    o,obj:=v.(json.Object)
    if !obj || len(o)>128 do return false
    for key,value in o {
        if key=="" || len(key)>128 do return false
        if spec,obj:=value.(json.Object);obj { if !input_shape(spec,false) do return false } else { if _,str:=value.(json.String);!str do return false }
    }
    return true
}
template_shape :: proc(raw:string,allow_output:bool)->bool {
    pos:=0
    for pos<len(raw) {
        open:=strings.index(raw[pos:],"{{")
        if open<0 do return true
        start:=pos+open+2
        close:=strings.index(raw[start:],"}}")
        if close<0 do return false
        token:=strings.trim_space(raw[start:start+close])
        pos=start+close+2
        if token=="" || strings.contains(token,"{{") do return false
        if token=="stage.key" || token=="stage.index" || token=="stage.count" || token=="item" do continue
        if allow_output && (token=="output" || strings.has_prefix(token,"output.")) do continue
        if strings.has_prefix(token,"item.") || strings.has_prefix(token,"inputs.") || strings.has_prefix(token,"workflow.input.") do continue
        if strings.has_prefix(token,"stage.") {
            rest:=token[len("stage."):]
            dot:=strings.index_byte(rest,'.')
            if dot>0 {
                after:=rest[dot+1:]
                if strings.has_prefix(after,"output.") || strings.has_prefix(after,"outputs[0].") do continue
            }
        }
        return false
    }
    return true
}

st_to_json :: proc(o:json.Object)->string { b,err:=json.marshal(o,allocator=context.temp_allocator);if err!=nil do return "";return string(b) }
