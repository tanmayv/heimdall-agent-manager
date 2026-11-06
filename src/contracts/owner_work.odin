package contracts

import "core:encoding/json"
import "core:strings"

owner_work_keys :: proc(o:json.Object,allowed:string)->bool {
    names:=strings.split(allowed,"|",context.temp_allocator)
    for key,_ in o {
        found:=false
        for name in names {if key==name {found=true;break}}
        if !found do return false
    }
    return true
}
owner_work_item :: proc(v:json.Value)->bool {
    o,obj:=v.(json.Object)
    if !obj || len(o)!=2 do return false
    return (owner_string(o,"kind")=="task" || owner_string(o,"kind")=="workflow_run") && owner_field_valid(owner_string(o,"id"),"id")
}
owner_work_document :: proc(raw:string,method:string)->(json.Object,bool) {
    if len(raw)>OWNER_DOCUMENT_MAX do return nil,false
    value,parsed:=owner_content_document(raw);o,obj:=value.(json.Object)
    if !parsed || !obj do return nil,false
    switch method {
    case "chain.draft","chain.publish","task.publish":
        return o,len(o)==0
    case "chain.decide":
        if len(o)!=3 || !owner_work_keys(o,"proposal_id|decision|note") do return nil,false
        _,note:=o["note"].(json.String)
        return o,note && len(owner_string(o,"note"))<=8192 && owner_field_valid(owner_string(o,"proposal_id"),"id") && (owner_string(o,"decision")=="approve" || owner_string(o,"decision")=="reject")
    case "chain.complete":
        if len(o)!=2 || !owner_work_keys(o,"expected_work_revision|summary") do return nil,false
        _,summary:=o["summary"].(json.String)
        return o,summary && strings.trim_space(owner_string(o,"summary"))!="" && len(owner_string(o,"summary"))<=8192 && owner_field_valid(owner_string(o,"expected_work_revision"),"counter")
    case "work.dependency.add":
        return o,len(o)==3 && owner_work_keys(o,"dependency_id|dependent|prerequisite") && owner_field_valid(owner_string(o,"dependency_id"),"id") && owner_work_item(o["dependent"]) && owner_work_item(o["prerequisite"])
    case "work.dependency.remove":
        _,reason:=o["reason"].(json.String)
        return o,len(o)==2 && owner_work_keys(o,"dependency_id|reason") && owner_field_valid(owner_string(o,"dependency_id"),"id") && reason && strings.trim_space(owner_string(o,"reason"))!=""
    case "work.scope":
        _,reason:=o["reason"].(json.String)
        return o,len(o)==3 && owner_work_keys(o,"item|action|reason") && owner_work_item(o["item"]) && (owner_string(o,"action")=="include" || owner_string(o,"action")=="exclude") && reason && strings.trim_space(owner_string(o,"reason"))!=""
    case "chain.propose":
        if !owner_work_keys(o,"kind|tasks|rationale|alternative|auto_approve|workflow|inputs") do return nil,false
        kind:=owner_string(o,"kind")
        if kind!="task" && kind!="workflow_run" do return nil,false
        for name in ([3]string{"rationale","alternative","workflow"}) {
            if v,present:=o[name];present {if _,str:=v.(json.String);!str do return nil,false}
        }
        if v,present:=o["auto_approve"];present {if _,boolean:=v.(json.Boolean);!boolean do return nil,false}
        if v,present:=o["inputs"];present {if _,object:=v.(json.Object);!object do return nil,false}
        tasks,present:=o["tasks"]
        if present {
            a,array:=tasks.(json.Array)
            if !array || len(a)>32 || (kind=="workflow_run" && len(a)>0) do return nil,false
            for item in a {
                spec,object:=item.(json.Object)
                if !object || !owner_work_keys(spec,"id|task_id|title|description|priority|brief|goal|acceptance|role|depends_on") do return nil,false
                if title,str:=spec["title"].(json.String);!str || strings.trim_space(string(title))=="" || len(title)>8192 do return nil,false
                for name in ([7]string{"id","task_id","description","priority","goal","role","title"}) {
                    if v,present:=spec[name];present {if _,str:=v.(json.String);!str do return nil,false}
                }
                for name in ([2]string{"id","task_id"}) {if id:=owner_string(spec,name);id!="" && !owner_field_valid(id,"id") do return nil,false}
                if id,alias:=owner_string(spec,"id"),owner_string(spec,"task_id");id!="" && alias!="" && id!=alias do return nil,false
                if p:=owner_string(spec,"priority");p!="" && !owner_field_valid(p,"priority") do return nil,false
                if v,present:=spec["brief"];present {if _,object:=v.(json.Object);!object do return nil,false}
                for name in ([2]string{"acceptance","depends_on"}) {
                    if v,present:=spec[name];present {
                        values,array:=v.(json.Array)
                        if !array || len(values)>100 do return nil,false
                        for value in values { if _,str:=value.(json.String);!str do return nil,false }
                    }
                }
            }
        }
        if kind=="workflow_run" && owner_string(o,"workflow")=="" do return nil,false
        if kind=="task" && (owner_string(o,"workflow")!="" || o["inputs"]!=nil) do return nil,false
        return o,true
    }
    return nil,false
}
