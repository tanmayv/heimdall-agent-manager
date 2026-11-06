#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:time"
import contracts "odin_test:contracts"

work_time :: proc(now:i64)->string {
    t:=time.unix(now/1000,(now%1000)*1000000)
    y,m,d:=time.date(t);h,n,s:=time.clock(t)
    return fmt.tprintf("%04d-%02d-%02dT%02d:%02d:%02dZ",y,int(m),d,h,n,s)
}
work_chain_active :: proc(s:^Store,chain:string)->bool {
    rows,ok:=query(s.db,"SELECT status FROM local_work_chains WHERE chain_id=?",chain)
    return ok && len(rows)==1 && rows[0][0]=="active"
}
work_task_published :: proc(s:^Store,chain,task:string)->bool {
    rows,ok:=query(s.db,"SELECT 1 FROM local_work_chains w WHERE chain_id=? AND status='active' AND publish_state='published' AND COALESCE((SELECT publish_state FROM local_task_publications p WHERE p.chain_id=w.chain_id AND p.task_id=? ORDER BY accepted_seq DESC LIMIT 1),'published')='published'",chain,task)
    return ok && len(rows)==1
}
work_pending :: proc(s:^Store,chain:string)->(json.Object,string,bool) {
    rows,ok:=query(s.db,"SELECT defaults_json,accepted_seq FROM local_chain_defaults_versions WHERE chain_id=? ORDER BY accepted_seq DESC LIMIT 1",chain)
    if !ok do return nil,"",false
    if len(rows)==0 do return nil,"",true
    v,valid:=contracts.owner_content_document(rows[0][0]);defaults,obj:=v.(json.Object)
    if !valid || !obj do return nil,"",false
    p,pending:=defaults["proposal"].(json.Object)
    if !pending || len(p)==0 do return nil,"",true
    id:=field(p,"proposal_id")
    if id=="" {
        event,read:=query(s.db,"SELECT operation_id FROM local_events WHERE seq=?",rows[0][1])
        if !read || len(event)!=1 do return nil,"",false
        id=event[0][0]
    }
    return p,id,true
}
work_set_pending :: proc(s:^Store,chain:string,p:json.Object,seq:i64)->bool {
    rows,ok:=query(s.db,"SELECT defaults_json FROM local_chain_defaults_versions WHERE chain_id=? ORDER BY accepted_seq DESC LIMIT 1",chain)
    if !ok do return false
    current:=doc(map[string]string{})
    if len(rows)>0 {
        v,valid:=contracts.owner_content_document(rows[0][0]);old,obj:=v.(json.Object)
        if !valid || !obj do return false
        for k,v in old {if k!="proposal" do current[k]=v}
    }
    if p!=nil do current["proposal"]=p
    _,ok=query(s.db,"INSERT INTO local_chain_defaults_versions VALUES(?,?,?)",chain,fmt.tprintf("%d",seq),encode(current))
    return ok
}
work_publish_brief :: proc(s:^Store,chain,raw:string)->string {
    if !brief_valid(raw) do return "invalid_content"
    v,_:=contracts.owner_request_document(raw);b,_:=v.(json.Object)
    if len(strings.trim_space(field(b,"goal")))>2000 do return "invalid_content"
    acceptance,_:=b["acceptance"].(json.Array)
    if len(acceptance)>20 do return "invalid_content"
    for value in acceptance {text,_:=value.(json.String);if len(text)>200 do return "invalid_content"}
    _,code:=brief_inputs_resolve(s,chain,raw)
    if code!="ok" do return code
    if value,present:=b["review_roles"];present {
        roles,_:=value.(json.Array)
        for value in roles {
            role,_:=value.(json.String)
            rows,ok:=query(s.db,"SELECT 1 FROM local_fleet_policy_current p JOIN local_fleet_policy_roles r ON r.chain_id=p.chain_id AND r.agent_id=p.agent_id AND r.seq=p.seq WHERE p.chain_id=? AND r.role=? AND r.paused=0 LIMIT 1",chain,string(role))
            if !ok do return "storage_error"
            if len(rows)==0 do return "invalid_scope"
        }
    }
    if value,present:=b["reviewers"];present {
        reviewers,_:=value.(json.Array)
        for value in reviewers {
            agent,_:=value.(json.String)
            rows,ok:=query(s.db,"SELECT 1 FROM local_chain_member_versions m WHERE chain_id=? AND agent_id=? AND enabled=1 AND accepted_seq=(SELECT max(accepted_seq) FROM local_chain_member_versions x WHERE x.chain_id=m.chain_id AND x.instance_id=m.instance_id) LIMIT 1",chain,string(agent))
            if !ok do return "storage_error"
            if len(rows)==0 do return "invalid_scope"
        }
    }
    return "ok"
}
work_spec_brief :: proc(spec:json.Object)->string {
    if v,present:=spec["brief"];present {return encode(v)}
    goal:=field(spec,"goal");if goal=="" do goal=field(spec,"title")
    b:=doc(map[string]string{"goal"=goal})
    if a,present:=spec["acceptance"];present {b["acceptance"]=a} else {b["acceptance"]=json.Array{json.String(goal)}}
    return encode(b)
}
work_proposal_validate :: proc(s:^Store,chain:string,p:json.Object,seq:i64)->string {
    if field(p,"kind")=="workflow_run" {return work_validate_proposed_run(s,chain,p,seq)}
    values,_:=p["tasks"].(json.Array)
    existing,ok:=query(s.db,"SELECT task_id FROM tasks WHERE chain_id=?",chain)
    if !ok do return "storage_error"
    if len(values)==0 && len(existing)==0 do return "invalid_content"
    ids:=make(map[string]bool,context.temp_allocator)
    for value in values {
        spec,_:=value.(json.Object);id:=field(spec,"id");if id=="" do id=field(spec,"task_id")
        if id!="" && ids[id] do return "invalid_content"
        if id!="" do ids[id]=true
        if code:=work_publish_brief(s,chain,work_spec_brief(spec));code!="ok" do return code
    }
    for row in existing {
        draft,read:=query(s.db,"SELECT COALESCE((SELECT publish_state FROM local_task_publications WHERE chain_id=? AND task_id=? ORDER BY accepted_seq DESC LIMIT 1),'published')",chain,row[0])
        if !read do return "storage_error"
        if draft[0][0]!="draft" do continue
        req,has:=lifecycle_requirements(s,chain,row[0])
        if !has do return "invalid_content"
        if code:=work_publish_brief(s,chain,req[1]);code!="ok" do return code
    }
    return "ok"
}
work_publish_task :: proc(s:^Store,chain,task:string,seq:i64)->string {
    generated,read:=query(s.db,"SELECT 1 FROM local_workflow_tasks WHERE chain_id=? AND task_id=?",chain,task)
    if !read do return "storage_error"
    if len(generated)>0 do return "invalid_scope"
    req,has:=lifecycle_requirements(s,chain,task)
    if !has do return "invalid_content"
    if code:=work_publish_brief(s,chain,req[1]);code!="ok" do return code
    rows,ok:=query(s.db,"SELECT publish_state FROM local_task_publications WHERE chain_id=? AND task_id=? ORDER BY accepted_seq DESC LIMIT 1",chain,task)
    if !ok do return "storage_error"
    if len(rows)==0 || rows[0][0]=="published" do return "ok"
    if _,ok=query(s.db,"INSERT INTO local_task_publications VALUES(?,?,?,'published')",chain,task,fmt.tprintf("%d",seq));!ok do return "storage_error"
    if _,ok=query(s.db,"UPDATE tasks SET revision=revision+1 WHERE chain_id=? AND task_id=?",chain,task);!ok do return "storage_error"
    return "ok"
}
work_publish :: proc(s:^Store,c:json.Object,seq:i64)->string {
    chain:=field(c,"chain_id")
    tasks,ok:=query(s.db,"SELECT task_id FROM tasks WHERE chain_id=? AND COALESCE((SELECT publish_state FROM local_task_publications p WHERE p.chain_id=tasks.chain_id AND p.task_id=tasks.task_id ORDER BY accepted_seq DESC LIMIT 1),'published')='draft'",chain)
    if !ok do return "storage_error"
    for row in tasks {if code:=work_publish_task(s,chain,row[0],seq);code!="ok" do return code}
    if _,ok=query(s.db,"INSERT OR IGNORE INTO local_work_run_publications SELECT chain_id,run_id,? FROM local_work_pending_runs WHERE chain_id=?",fmt.tprintf("%d",seq),chain);!ok do return "storage_error"
    if _,ok=query(s.db,"UPDATE local_work_chains SET publish_state='published' WHERE chain_id=?",chain);!ok do return "storage_error"
    return "ok"
}
work_approve_tasks :: proc(s:^Store,c,p:json.Object,seq,now:i64,proposal_id:string="")->(json.Object,string) {
    chain:=field(c,"chain_id")
    proposal:=proposal_id
    if proposal=="" do proposal=field(c,"operation_id")
    if code:=work_proposal_validate(s,chain,p,seq);code!="ok" do return nil,code
    values,_:=p["tasks"].(json.Array)
    ids:=make([dynamic]string,context.temp_allocator)
    for value,i in values {
        spec,_:=value.(json.Object);id:=field(spec,"id");if id=="" do id=field(spec,"task_id")
        if id=="" do id=fmt.tprintf("task_%s",payload_hash(encode([3]string{chain,proposal,fmt.tprintf("%d",i)})))
        present,ok:=query(s.db,"SELECT 1 FROM tasks WHERE task_id=? AND chain_id=?",id,chain)
        if !ok do return nil,"storage_error"
        if len(present)==0 {
            if _,ok=query(s.db,"INSERT INTO tasks VALUES(?,?,?,?,1)",chain,id,field(spec,"title"),field(spec,"description"));!ok do return nil,"operation_conflict"
            brief:=work_spec_brief(spec)
            if _,ok=query(s.db,"INSERT INTO task_requirements VALUES(?,?,1,?,?,?,?)",chain,id,brief,"",field(c,"principal_id"),field(c,"operation_id"));!ok do return nil,"storage_error"
            if code:=brief_inputs_pin(s,chain,id,"1",brief);code!="ok" do return nil,code
            priority:=field(spec,"priority");if priority=="" do priority="p2"
            if _,ok=query(s.db,"INSERT INTO local_task_priority_versions VALUES(?,?,?,?)",chain,id,fmt.tprintf("%d",seq),priority);!ok do return nil,"storage_error"
        } else {
            generated,read:=query(s.db,"SELECT 1 FROM local_workflow_tasks WHERE chain_id=? AND task_id=?",chain,id)
            if !read do return nil,"storage_error"
            if len(generated)>0 do return nil,"invalid_scope"
        }
        if _,ok:=query(s.db,"INSERT INTO local_work_materialized_tasks VALUES(?,?,?,?,?)",chain,id,fmt.tprintf("%d",seq),proposal,encode(spec));!ok do return nil,"storage_error"
        append(&ids,id)
    }
    for value,i in values {
        spec,_:=value.(json.Object);deps,_:=spec["depends_on"].(json.Array)
        for dep,j in deps {
            parent,_:=dep.(json.String)
            edge:=doc(map[string]string{"dependency_id"=fmt.tprintf("wdep_%s",payload_hash(encode([4]string{chain,proposal,fmt.tprintf("%d",i),fmt.tprintf("%d",j)})))})
            edge["dependent"]=doc(map[string]string{"kind"="task","id"=ids[i]})
            edge["prerequisite"]=doc(map[string]string{"kind"="task","id"=string(parent)})
            if code:=work_dependency_add(s,c,edge,seq,now);code!="ok" do return nil,code
        }
    }
    if len(values)==0 {
        existing,ok:=query(s.db,"SELECT task_id FROM tasks WHERE chain_id=? ORDER BY task_id",chain)
        if !ok do return nil,"storage_error"
        for row in existing do append(&ids,row[0])
    }
    if code:=work_publish(s,c,seq);code!="ok" do return nil,code
    result:=doc(map[string]string{"tasks"=encode(ids)})
    return result,"ok"
}
