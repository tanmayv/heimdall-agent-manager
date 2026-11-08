#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"

work_run_document :: proc(s:^Store,chain:string,p:json.Object,id:string)->(string,bool) {
    ref:=field(p,"workflow")
    at:=strings.last_index(ref,":")
    if at<1 || at==len(ref)-1 || !contracts.owner_field_valid(ref[at+1:],"positive") do return "",false
    workflow,version:=ref[:at],ref[at+1:]
    if !contracts.owner_field_valid(workflow,"id") do return "",false
    run:=doc(map[string]string{"run_id"=id,"workflow_id"=workflow,"version"=version})
    language,_:=language_definition(s,chain,workflow,version)
    if language.name!="" {
        input:="{}"
        if inputs,present:=p["inputs"];present {input=encode(inputs)}
        run["inputs"]=json.String(input)
    } else if input,present:=p["inputs"];present {
        o,_:=input.(json.Object)
        if len(o)>0 do return "",false
    }
    return encode(run),true
}
work_validate_run :: proc(s:^Store,chain,body:string,seq:i64)->string {
    tx:Transaction
    if !transaction_savepoint(s.active,&tx) do return "storage_error"
    defer transaction_rollback(&tx)
    c:=doc(map[string]string{"chain_id"=chain,"method"="workflow.run","principal_id"="validation","operation_id"="validation"})
    return workflow_command(s,c,body,seq)
}
work_validate_proposed_run :: proc(s:^Store,chain:string,p:json.Object,seq:i64)->string {
    body,valid:=work_run_document(s,chain,p,fmt.tprintf("run_validate_%s",payload_hash(encode(p))))
    if !valid do return "invalid_content"
    return work_validate_run(s,chain,body,seq)
}
work_queue_run :: proc(s:^Store,c:json.Object,body:string,seq,now:i64)->string {
    p,valid:=contracts.owner_parse(body,"workflow_run")
    if !valid {p,valid=contracts.owner_parse(body,"workflow_language_run")}
    if !valid do return "invalid_content"
    chain,run:=field(c,"chain_id"),field(p,"run_id")
    if code:=work_validate_run(s,chain,body,seq);code!="ok" do return code
    if _,ok:=query(s.db,"INSERT INTO local_work_pending_runs VALUES(?,?,?,?,?,?,?)",chain,run,body,work_time(now),"user",s.account,fmt.tprintf("%d",seq));!ok do return "operation_conflict"
    return "ok"
}
work_decide :: proc(s:^Store,c,p:json.Object,seq,now:i64)->string {
    chain:=field(c,"chain_id")
    pending,id,read:=work_pending(s,chain)
    if !read do return "storage_error"
    if pending==nil || id!=field(p,"proposal_id") do return "stale_revision"
    original,ok:=query(s.db,"SELECT proposal_json FROM local_work_proposals WHERE chain_id=? AND proposal_id=?",chain,id)
    if !ok do return "storage_error"
    if len(original)==0 {
        // Legacy defaults retained an original proposal without a local ID.
        // Keep its exact source object as evidence; reject clears it safely.
        if _,ok=query(s.db,"INSERT INTO local_work_proposals VALUES(?,?,?,?,?,?,?)",chain,id,fmt.tprintf("%d",seq),encode(pending),field(pending,"proposed_at"),field(pending,"proposed_by_kind"),field(pending,"proposed_by_id"));!ok do return "storage_error"
    } else {
        v,parsed:=contracts.owner_content_document(original[0][0]);o,obj:=v.(json.Object)
        if !parsed || !obj do return "storage_error"
        pending=o
    }
    result:=doc(map[string]string{"proposal_id"=id,"decision"=field(p,"decision")})
    if field(p,"decision")=="approve" {
        // Source pending proposals include immutable author/time/status metadata.
        // Validate the command projection while retaining the original raw record.
        projection:=doc(map[string]string{})
        for key,value in pending {
            if key=="proposal_id" || key=="status" || key=="proposed_by_kind" || key=="proposed_by_id" || key=="proposed_by" || key=="proposed_at" || key=="created_at_ms" do continue
            projection[key]=value
        }
        if field(projection,"kind")=="" do projection["kind"]=json.String("task")
        validated,valid:=contracts.owner_work_document(encode(projection),"chain.propose")
        if !valid do return "invalid_content"
        if field(validated,"kind")=="workflow_run" {
            run:=fmt.tprintf("run_%s",payload_hash(encode([2]string{chain,id})))
            body,valid:=work_run_document(s,chain,validated,run)
            if !valid do return "invalid_content"
            if code:=work_queue_run(s,c,body,seq,now);code!="ok" do return code
            result["run_id"]=json.String(run)
            if code:=work_publish(s,c,seq);code!="ok" do return code
        } else {
            materialized,code:=work_approve_tasks(s,c,validated,seq,now,id)
            if code!="ok" do return code
            result["tasks"]=materialized["tasks"]
        }
    }
    if !work_set_pending(s,chain,nil,seq) do return "storage_error"
    if _,ok=query(s.db,"INSERT INTO local_work_decisions VALUES(?,?,?,?,?,?,?,?,?)",chain,id,fmt.tprintf("%d",seq),field(p,"decision"),field(p,"note"),encode(result),work_time(now),"user",s.account);!ok do return "storage_error"
    return "ok"
}
work_command :: proc(s:^Store,c:json.Object,body:string,seq,now:i64,agent:=false)->string {
    method,chain:=field(c,"method"),field(c,"chain_id")
    if !work_chain_active(s,chain) do return "operation_conflict"
    if method=="workflow.draft" do return work_queue_run(s,c,body,seq,now)
    p,valid:=contracts.owner_work_document(body,method)
    if !valid do return "invalid_content"
    switch method {
    case "chain.draft":
        started,ok:=query(s.db,"SELECT 1 FROM local_leases WHERE chain_id=? UNION SELECT 1 FROM local_workflow_runs WHERE chain_id=? LIMIT 1",chain,chain)
        if !ok do return "storage_error"
        if len(started)>0 do return "operation_conflict"
        if _,ok=query(s.db,"UPDATE local_work_chains SET publish_state='draft' WHERE chain_id=?",chain);!ok do return "storage_error"
    case "chain.publish":
        pending,_,read:=work_pending(s,chain)
        if !read do return "storage_error"
        if pending!=nil do return "operation_conflict"
        header,ok:=query(s.db,"SELECT publish_state FROM local_work_chains WHERE chain_id=?",chain)
        if !ok || len(header)!=1 do return "storage_error"
        if header[0][0]!="draft" do return "operation_conflict"
        return work_publish(s,c,seq)
    case "task.publish":
        rows,ok:=query(s.db,"SELECT w.publish_state,COALESCE((SELECT publish_state FROM local_task_publications WHERE chain_id=w.chain_id AND task_id=? ORDER BY accepted_seq DESC LIMIT 1),\'published\') FROM local_work_chains w WHERE chain_id=?",field(c,"task_id"),chain)
        if !ok || len(rows)!=1 do return "storage_error"
        if rows[0][0]!="published" || rows[0][1]!="draft" do return "operation_conflict"
        return work_publish_task(s,chain,field(c,"task_id"),seq)
    case "chain.propose":
        pending,_,read:=work_pending(s,chain)
        if !read do return "storage_error"
        if pending!=nil do return "operation_conflict"
        if code:=work_proposal_validate(s,chain,p,seq);code!="ok" do return code
        if _,ok:=query(s.db,"INSERT INTO local_work_proposals VALUES(?,?,?,?,?,?,?)",chain,field(c,"operation_id"),fmt.tprintf("%d",seq),body,work_time(now),"user",s.account);!ok do return "operation_conflict"
        auto,_:=p["auto_approve"].(json.Boolean)
        if bool(auto) {
            result:=doc(map[string]string{"proposal_id"=field(c,"operation_id"),"decision"="approve"})
            if field(p,"kind")=="workflow_run" {
                run:=fmt.tprintf("run_%s",payload_hash(encode([2]string{chain,field(c,"operation_id")})))
                body,valid:=work_run_document(s,chain,p,run)
                if !valid do return "invalid_content"
                if code:=work_queue_run(s,c,body,seq,now);code!="ok" do return code
                result["run_id"]=json.String(run)
                if code:=work_publish(s,c,seq);code!="ok" do return code
            } else {
                materialized,code:=work_approve_tasks(s,c,p,seq,now)
                if code!="ok" do return code
                result["tasks"]=materialized["tasks"]
            }
            if !work_set_pending(s,chain,nil,seq) do return "storage_error"
            if _,ok:=query(s.db,"INSERT INTO local_work_decisions VALUES(?,?,?,?,?,?,?,?,?)",chain,field(c,"operation_id"),fmt.tprintf("%d",seq),"approve","auto-approved",encode(result),work_time(now),"user",s.account);!ok do return "storage_error"
        } else {
            slot:=doc(map[string]string{})
            for k,v in p do slot[k]=v
            slot["proposal_id"]=json.String(field(c,"operation_id"));slot["status"]=json.String("pending")
            slot["proposed_by_kind"]=json.String("user");slot["proposed_by_id"]=json.String(s.account)
            slot["proposed_at"]=json.String(work_time(now))
            if !work_set_pending(s,chain,slot,seq) do return "storage_error"
        }
    case "chain.decide": return work_decide(s,c,p,seq,now)
    case "work.dependency.add": return work_dependency_add(s,c,p,seq,now)
    case "work.dependency.remove":
        edge,read:=query(s.db,"SELECT 1 FROM local_work_dependencies WHERE chain_id=? AND dependency_id=?",chain,field(p,"dependency_id"))
        if !read do return "storage_error"
        if len(edge)!=1 do return "invalid_scope"
        removed,removal_read:=query(s.db,"SELECT 1 FROM local_work_dependency_removals WHERE chain_id=? AND dependency_id=?",chain,field(p,"dependency_id"))
        if !removal_read do return "storage_error"
        if len(removed)>0 do return "ok"
        if _,ok:=query(s.db,"INSERT INTO local_work_dependency_removals VALUES(?,?,?,?,?,?,?)",chain,field(p,"dependency_id"),work_time(now),"user",s.account,field(p,"reason"),fmt.tprintf("%d",seq));!ok do return "storage_error"
    case "work.scope": return work_scope(s,c,p,seq,now)
    case "chain.complete": return work_complete(s,c,p,seq,now,agent)
    case: return "malformed"
    }
    return "ok"
}
// Runs only inside the accepted event transaction. Existing workflow execution
// and stage expansion implementations remain the single runtime authority.
work_after_event :: proc(tx:^Transaction,chain,task,kind,principal,op,payload:string,seq,now:i64)->bool {
    s:=tx.store
    if kind=="lease.claim" || kind=="lease.submit" {
        generated,read:=query(s.db,"SELECT 1 FROM local_workflow_tasks WHERE chain_id=? AND task_id=?",chain,task)
        if !read do return false
        if len(generated)==0 && !work_capture_inputs(s,chain,"task",task,seq,now) do return false
    }
    if kind=="lease.switch" {
        value,valid:=contracts.owner_request_document(payload);p,obj:=value.(json.Object)
        if !valid || !obj do return false
        generated,read:=query(s.db,"SELECT 1 FROM local_workflow_tasks WHERE chain_id=? AND task_id=?",field(p,"destination_chain_id"),field(p,"destination_task_id"))
        if !read do return false
        if len(generated)==0 && !work_capture_inputs(s,field(p,"destination_chain_id"),"task",field(p,"destination_task_id"),seq,now) do return false
    }
    // Publication prepares discovery for proposal-materialized ordinary tasks.
    tasks,ok:=query(s.db,"SELECT t.task_id,t.title FROM local_work_materialized_tasks w JOIN tasks t USING(chain_id,task_id) WHERE w.chain_id=? AND w.accepted_seq=?",chain,fmt.tprintf("%d",seq))
    if !ok do return false
    for row in tasks {
        p:=encode(doc(map[string]string{"task_id"=row[0],"title"=row[1],"metadata_revision"=fmt.tprintf("%d",seq)}))
        if !intent_enqueue(tx,Intent_Input{chain=chain,principal=principal,operation=op,seq=seq,kind="registry.prepare",destination=row[0],fence="{}",payload=p}) do return false
    }
    for pass in 0..<128 {
        pending,read:=query(s.db,"SELECT r.run_id,r.run_json,r.accepted_seq FROM local_work_pending_runs r JOIN local_work_run_publications p USING(chain_id,run_id) JOIN local_work_chains w USING(chain_id) WHERE r.chain_id=? AND w.status='active' AND w.publish_state='published' AND NOT EXISTS(SELECT 1 FROM local_work_run_starts x WHERE x.chain_id=r.chain_id AND x.run_id=r.run_id) AND NOT EXISTS(SELECT 1 FROM local_work_run_cancellations x WHERE x.chain_id=r.chain_id AND x.run_id=r.run_id) ORDER BY r.run_id",chain)
        if !read do return false
        if len(pending)==0 do return true
        changed:=false
        for row in pending {
            if !work_inputs_ready(s,chain,"workflow_run",row[0]) do continue
            origin,read:=query(s.db,"SELECT principal_id,operation_id,commit_seq FROM command_receipts WHERE chain_id=? AND commit_seq IN(?,?) ORDER BY commit_seq DESC LIMIT 1",chain,fmt.tprintf("%d",seq),row[2])
            if !read || len(origin)!=1 do return false
            command:=doc(map[string]string{"chain_id"=chain,"task_id"="","method"="workflow.run","principal_id"=origin[0][0],"operation_id"=origin[0][1]})
            command["work_activation"]=json.String("1")
            if workflow_command(s,command,row[1],seq)!="ok" do return false
            if _,ok=query(s.db,"INSERT INTO local_work_run_starts VALUES(?,?,?,?)",chain,row[0],fmt.tprintf("%d",seq),work_time(now));!ok do return false
            if !work_capture_inputs(s,chain,"workflow_run",row[0],seq,now) do return false
            language,language_read:=query(s.db,"SELECT 1 FROM local_workflow_language_runs WHERE chain_id=? AND run_id=?",chain,row[0])
            if !language_read do return false
            if len(language)==0 {
                generated,read:=query(s.db,"SELECT t.task_id,t.title FROM local_workflow_tasks w JOIN tasks t USING(chain_id,task_id) WHERE w.chain_id=? AND w.run_id=?",chain,row[0])
                if !read do return false
                for task in generated {
                    p:=encode(doc(map[string]string{"task_id"=task[0],"title"=task[1],"metadata_revision"=fmt.tprintf("%d",seq)}))
                    if !intent_enqueue(tx,Intent_Input{chain=chain,principal=origin[0][0],operation=origin[0][1],seq=number(origin[0][2]),kind="registry.prepare",destination=task[0],fence="{}",payload=p}) do return false
                }
            }
            changed=true
        }
        if !changed do return true
        if !workflow_refresh(s) do return false
    }
    return false
}


work_cancel_pending :: proc(s:^Store,c:json.Object,raw:string,seq:i64)->(bool,string) {
    p,valid:=contracts.owner_parse(raw,"workflow_control")
    if !valid do return false,""
    chain,run:=field(c,"chain_id"),field(p,"run_id")
    pending,ok:=query(s.db,"SELECT 1 FROM local_work_pending_runs r WHERE chain_id=? AND run_id=? AND NOT EXISTS(SELECT 1 FROM local_work_run_starts x WHERE x.chain_id=r.chain_id AND x.run_id=r.run_id)",chain,run)
    if !ok do return true,"storage_error"
    if len(pending)==0 do return false,""
    if field(p,"execution")!="1" do return true,"stale_revision"
    if strings.trim_space(field(p,"reason"))=="" do return true,"invalid_content"
    if _,ok=query(s.db,"INSERT INTO local_work_run_cancellations VALUES(?,?,?,?)",chain,run,field(p,"reason"),fmt.tprintf("%d",seq));!ok do return true,"operation_conflict"
    return true,"ok"
}
