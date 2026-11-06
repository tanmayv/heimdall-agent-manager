#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"
import wf "odin_test:lib/workflow_v1"
import vault "odin_test:lib/vault"

// The wrapper pins original workflow.v1 bytes without converting them to the
// preceding static DAG dialect. Both formats remain explicit and disjoint.
language_definition :: proc(s:^Store,chain,workflow,version:string)->(wf.Workflow_Parsed_Spec,bool) {
    rows,ok:=query(s.db,"SELECT definition_json FROM local_workflow_definitions WHERE chain_id=? AND workflow_id=? AND version=?",chain,workflow,version)
    if !ok || len(rows)!=1 do return {},false
    d,valid:=contracts.owner_parse(rows[0][0],"workflow_language_definition")
    if !valid do return {},false
    spec,parsed,_:=wf.parse_bounded(field(d,"spec"))
    return spec,parsed
}
language_execution :: proc(s:^Store,chain,run,execution:string,c:json.Object,seq:i64)->bool {
    if _,ok:=query(s.db,"INSERT INTO local_workflow_executions VALUES(?,?,?,'running')",chain,run,execution);!ok do return false
    if _,ok:=query(s.db,"INSERT INTO local_workflow_language_executions VALUES(?,?,?,'running','',?,?)",chain,run,execution,field(c,"principal_id"),field(c,"operation_id"));!ok do return false
    _,ok:=query(s.db,"INSERT OR IGNORE INTO local_workflow_events VALUES(?,?,?,?,'expanded',?,?)",chain,run,execution,fmt.tprintf("%d",seq),field(c,"principal_id"),field(c,"operation_id"))
    return ok
}
language_command :: proc(s:^Store,c:json.Object,raw:string,seq:i64)->(bool,string) {
    chain,method:=field(c,"chain_id"),field(c,"method")
    if method=="workflow.define" {
        p,valid:=contracts.owner_parse(raw,"workflow_language_definition")
        if !valid do return false,""
        if _,ok,_:=wf.parse_bounded(field(p,"spec"));!ok do return true,"invalid_content"
        if _,ok:=query(s.db,"INSERT INTO local_workflow_definitions VALUES(?,?,?,?)",chain,field(p,"workflow_id"),field(p,"version"),raw);!ok do return true,"operation_conflict"
        return true,"ok"
    }
    if method=="workflow.cancel" {
        p,valid:=contracts.owner_parse(raw,"workflow_control")
        if !valid || strings.trim_space(field(p,"reason"))=="" do return true,"malformed"
        rows,ok:=query(s.db,"SELECT x.state FROM local_workflow_runs r JOIN local_workflow_language_executions x ON x.chain_id=r.chain_id AND x.run_id=r.run_id AND x.execution=r.current_execution WHERE r.chain_id=? AND r.run_id=? AND r.current_execution=?",chain,field(p,"run_id"),field(p,"execution"))
        if !ok do return true,"storage_error"
        if len(rows)!=1 || rows[0][0]!="running" do return true,"stale_revision"
        if !language_merges_settled(s,chain,field(p,"run_id"),field(p,"execution")) do return true,"operation_conflict"
        if !language_stop(s,c,field(p,"run_id"),field(p,"execution"),seq) do return true,"storage_error"
        if _,ok=query(s.db,"UPDATE local_workflow_language_executions SET state='cancelled',failure=? WHERE chain_id=? AND run_id=? AND execution=?",field(p,"reason"),chain,field(p,"run_id"),field(p,"execution"));!ok do return true,"storage_error"
        return true,"ok"
    }
    if method=="workflow.gate" {
        p,valid:=contracts.owner_parse(raw,"workflow_gate")
        if !valid do return true,"malformed"
        rows,ok:=query(s.db,"SELECT t.task_id FROM local_workflow_tasks t JOIN local_workflow_language_items i USING(task_id) JOIN local_workflow_runs r USING(chain_id,run_id) JOIN local_workflow_language_executions e ON e.chain_id=t.chain_id AND e.run_id=t.run_id AND e.execution=t.execution JOIN lifecycle_state l ON l.chain_id=t.chain_id AND l.task_id=t.task_id WHERE t.chain_id=? AND t.run_id=? AND t.execution=? AND r.current_execution=t.execution AND e.state='running' AND i.stage_key=? AND i.kind='gate' AND l.state='in_review'",chain,field(p,"run_id"),field(p,"execution"),field(p,"stage_key"))
        if !ok do return true,"storage_error"
        if len(rows)!=1 do return true,"stale_revision"
        if !control_ready(s,chain,rows[0][0]) do return true,"operation_conflict"
        if field(p,"verdict")=="request_changes" {
            if !language_stop(s,c,field(p,"run_id"),field(p,"execution"),seq) do return true,"storage_error"
            if _,ok=query(s.db,"UPDATE local_workflow_language_executions SET state='failed',failure='gate_rejected' WHERE chain_id=? AND run_id=? AND execution=?",chain,field(p,"run_id"),field(p,"execution"));!ok do return true,"storage_error"
        } else {
            if _,ok=query(s.db,"UPDATE lifecycle_state SET state='done' WHERE chain_id=? AND task_id=?",chain,rows[0][0]);!ok do return true,"storage_error"
        }
        if _,ok=query(s.db,"UPDATE tasks SET revision=revision+1 WHERE chain_id=? AND task_id=?",chain,rows[0][0]);!ok do return true,"storage_error"
        return true,"ok"
    }
    if method=="workflow.run" {
        p,valid:=contracts.owner_parse(raw,"workflow_language_run")
        if !valid do return false,""
        count,read_count:=query(s.db,"SELECT count(*) FROM local_workflow_runs WHERE chain_id=?",chain)
        if !read_count || len(count)!=1 do return true,"storage_error"
        if number(count[0][0])>=128 do return true,"retention_capacity"
        spec,ok:=language_definition(s,chain,field(p,"workflow_id"),field(p,"version"))
        if !ok do return true,"invalid_scope"
        if _,err:=wf.snapshot(spec,field(p,"inputs"));err.code!=.None do return true,"invalid_content"
        if _,ok=query(s.db,"INSERT INTO local_workflow_runs VALUES(?,?,?,?,1,1)",chain,field(p,"run_id"),field(p,"workflow_id"),field(p,"version"));!ok do return true,"operation_conflict"
        if _,ok=query(s.db,"INSERT INTO local_workflow_language_runs VALUES(?,?,?)",chain,field(p,"run_id"),field(p,"inputs"));!ok do return true,"storage_error"
        if !language_execution(s,chain,field(p,"run_id"),"1",c,seq) do return true,"storage_error"
        return true,"ok"
    }
    if method=="workflow.retry" {
        p,valid:=contracts.owner_parse(raw,"workflow_retry")
        if !valid do return false,""
        run:=field(p,"run_id")
        rows,ok:=query(s.db,"SELECT r.current_execution FROM local_workflow_runs r JOIN local_workflow_language_runs l USING(chain_id,run_id) WHERE r.chain_id=? AND r.run_id=?",chain,run)
        if !ok do return true,"storage_error"
        if len(rows)==0 do return false,""
        execution:=field(p,"execution")
        if rows[0][0]!=execution do return true,"stale_revision"
        terminal,terminal_read:=query(s.db,"SELECT state FROM local_workflow_language_executions WHERE chain_id=? AND run_id=? AND execution=?",chain,run,execution)
        if !terminal_read || len(terminal)!=1 do return true,"storage_error"
        if terminal[0][0]=="running" || !language_merges_settled(s,chain,run,execution) do return true,"operation_conflict"
        consumed,read:=query(s.db,"SELECT 1 FROM local_workflow_output_triggers WHERE chain_id=? AND source_run=? AND consumed=1 LIMIT 1",chain,run)
        if !read do return true,"storage_error"
        if len(consumed)>0 do return true,"operation_conflict"
        old,old_read:=query(s.db,"SELECT task_id FROM local_workflow_tasks WHERE chain_id=? AND run_id=? AND execution=?",chain,run,execution)
        if !old_read do return true,"storage_error"
        for row in old {
            command:=doc(map[string]string{"chain_id"=chain,"task_id"=row[0],"principal_id"=field(c,"principal_id"),"operation_id"=field(c,"operation_id")})
            if !control_revoke(s,command,seq,"checkpoint") do return true,"storage_error"
            if _,ok=query(s.db,"DELETE FROM local_checkpoints WHERE chain_id=? AND task_id=?",chain,row[0]);!ok do return true,"storage_error"
            if _,ok=query(s.db,"UPDATE source_episodes SET resolved=1,source_version=? WHERE chain_id=? AND origin_kind='local.review' AND origin_id=? AND resolved=0",fmt.tprintf("%d",seq),chain,row[0]);!ok do return true,"storage_error"
        }
        next:=fmt.tprintf("%d",number(execution)+1)
        if _,ok=query(s.db,"UPDATE local_workflow_executions SET state='superseded' WHERE chain_id=? AND run_id=? AND execution=?",chain,run,execution);!ok do return true,"storage_error"
        if _,ok=query(s.db,"UPDATE local_workflow_runs SET current_execution=?,revision=revision+1 WHERE chain_id=? AND run_id=?",next,chain,run);!ok do return true,"storage_error"
        if !language_execution(s,chain,run,next,c,seq) do return true,"storage_error"
        return true,"ok"
    }
    return false,""
}

// Called only inside an existing owner writer transaction. The command receipt
// remains pinned by its running execution's event until expansion is terminal.
language_refresh :: proc(s:^Store)->bool {
    for _ in 0..<128 {
        if !language_refresh_pass(s) do return false
        changed,ok:=language_triggers(s)
        if !ok do return false
        if !changed do return true
    }
    return true
}
language_refresh_pass :: proc(s:^Store)->bool {
    rows,ok:=query(s.db,"SELECT r.chain_id,r.run_id,r.current_execution,r.workflow_id,r.definition_version,l.inputs_json,x.principal_id,x.operation_id FROM local_workflow_runs r JOIN local_workflow_language_runs l USING(chain_id,run_id) JOIN local_workflow_language_executions x ON x.chain_id=r.chain_id AND x.run_id=r.run_id AND x.execution=r.current_execution WHERE x.state='running' ORDER BY r.chain_id,r.run_id")
    if !ok do return false
    for row in rows {
        chain,run,execution:=row[0],row[1],row[2]
        prerequisite,prereq_read:=query(s.db,"SELECT g.source_execution,r.current_execution,e.state,g.consumed FROM local_workflow_output_triggers g JOIN local_workflow_runs r ON r.chain_id=g.chain_id AND r.run_id=g.source_run JOIN local_workflow_language_executions e ON e.chain_id=g.chain_id AND e.run_id=g.source_run AND e.execution=g.source_execution WHERE g.chain_id=? AND g.target_run=?",chain,run)
        if !prereq_read do return false
        if len(prerequisite)==1 {
            p:=prerequisite[0]
            if p[0]!=p[1] {
                if _,ok=query(s.db,"UPDATE local_workflow_language_executions SET state='failed',failure='stale_source_execution' WHERE chain_id=? AND run_id=? AND execution=?",chain,run,execution);!ok do return false
                continue
            }
            if p[2]!="done" do continue
            if p[3]=="0" { if _,ok=query(s.db,"UPDATE local_workflow_output_triggers SET consumed=1 WHERE chain_id=? AND target_run=?",chain,run);!ok do return false }
        }
        spec,parsed:=language_definition(s,chain,row[3],row[4])
        if !parsed do return false
        snap,err:=wf.snapshot(spec,row[5])
        if err.code!=.None do return false
        for _ in 0..<len(spec.stages) {
            changed:=false
            for stage in spec.stages {
                expanded,read:=query(s.db,"SELECT item_count FROM local_workflow_stage_expansions WHERE chain_id=? AND run_id=? AND execution=? AND stage_key=?",chain,run,execution,stage.key)
                if !read do return false
                if len(expanded)>0 do continue
                ready:=true
                for dep in stage.depends_on {
                    counts,checked:=query(s.db,"SELECT (SELECT count(*) FROM local_workflow_stage_expansions WHERE chain_id=? AND run_id=? AND execution=? AND stage_key=?),(SELECT count(*) FROM local_workflow_tasks t JOIN local_workflow_language_items i USING(task_id) LEFT JOIN lifecycle_state l ON l.chain_id=t.chain_id AND l.task_id=t.task_id LEFT JOIN local_controls c ON c.chain_id=t.chain_id AND c.task_id=t.task_id WHERE t.chain_id=? AND t.run_id=? AND t.execution=? AND i.stage_key=? AND (l.state IS NULL OR l.state!='done' OR COALESCE(c.mode,'ready')!='ready'))",chain,run,execution,dep,chain,run,execution,dep)
                    if !checked || len(counts)!=1 do return false
                    if counts[0][0]!="1" || counts[0][1]!="0" { ready=false;break }
                }
                if !ready do continue
                views:=make(map[string]wf.Stage_View,context.temp_allocator)
                outputs,outputs_read:=query(s.db,"SELECT i.stage_key,o.output_json FROM local_workflow_tasks t JOIN local_workflow_language_items i USING(task_id) JOIN lifecycle_state l ON l.chain_id=t.chain_id AND l.task_id=t.task_id JOIN local_workflow_outputs o ON o.chain_id=t.chain_id AND o.task_id=t.task_id AND o.attempt=l.attempt WHERE t.chain_id=? AND t.run_id=? AND t.execution=? AND l.state='done' ORDER BY i.stage_key,i.stage_index",chain,run,execution)
                if !outputs_read do return false
                for output in outputs {
                    view:=views[output[0]]
                    all:=make([dynamic]string,len(view.outputs),context.temp_allocator)
                    copy(all[:],view.outputs);append(&all,output[1])
                    views[output[0]]=wf.Stage_View{outputs=all[:]}
                }
                plan,perr:=wf.plan_stage(snap,stage,views)
                if perr.code!=.None {
                    if !language_fail(s,row,perr.message) do return false
                    return true
                }
                if !language_materialize(s,row,stage,plan) do return false
                changed=true
            }
            if !changed do break
        }
        complete,read:=query(s.db,"SELECT (SELECT count(*) FROM local_workflow_stage_expansions WHERE chain_id=? AND run_id=? AND execution=?),(SELECT count(*) FROM local_workflow_tasks t LEFT JOIN lifecycle_state l ON l.chain_id=t.chain_id AND l.task_id=t.task_id LEFT JOIN local_controls c ON c.chain_id=t.chain_id AND c.task_id=t.task_id WHERE t.chain_id=? AND t.run_id=? AND t.execution=? AND (l.state IS NULL OR l.state!='done' OR COALESCE(c.mode,'ready')!='ready'))",chain,run,execution,chain,run,execution)
        if !read || len(complete)!=1 do return false
        if number(complete[0][0])==i64(len(spec.stages)) && complete[0][1]=="0" {
            if _,ok=query(s.db,"UPDATE local_workflow_language_executions SET state='done' WHERE chain_id=? AND run_id=? AND execution=?",chain,run,execution);!ok do return false
            if _,ok=query(s.db,"UPDATE local_workflow_executions SET state='done' WHERE chain_id=? AND run_id=? AND execution=?",chain,run,execution);!ok do return false
        }
    }
    return true
}
language_materialize :: proc(s:^Store,row:[]string,stage:wf.Workflow_Stage_Spec,plan:wf.Stage_Plan)->bool {
    chain,run,execution:=row[0],row[1],row[2]
    quota,ok:=query(s.db,"SELECT (SELECT count(*) FROM tasks),(SELECT count(*) FROM local_dependencies)")
    if !ok || len(quota)!=1 || number(quota[0][0])+i64(len(plan.items))>MAX_RECORDS do return false
    // Keep transitive prerequisite tasks, including ancestors of empty stages.
    ancestors:=make(map[string]bool,context.temp_allocator)
    spec,parsed:=language_definition(s,chain,row[3],row[4])
    if !parsed do return false
    for dep in stage.depends_on do ancestors[dep]=true
    for _ in 0..<len(spec.stages) {
        for st in spec.stages { if ancestors[st.key] { for dep in st.depends_on do ancestors[dep]=true } }
    }
    prior,read:=query(s.db,"SELECT t.task_id,i.stage_key FROM local_workflow_tasks t JOIN local_workflow_language_items i USING(task_id) WHERE t.chain_id=? AND t.run_id=? AND t.execution=?",chain,run,execution)
    if !read do return false
    deps:=make([dynamic]string,context.temp_allocator)
    for p in prior { if ancestors[p[1]] do append(&deps,p[0]) }
    if number(quota[0][1])+i64(len(deps)*len(plan.items))>MAX_RECORDS do return false
    receipts,receipt_read:=query(s.db,"SELECT commit_seq FROM command_receipts WHERE principal_id=? AND operation_id=?",row[6],row[7])
    if !receipt_read || len(receipts)!=1 do return false
    for item in plan.items {
        if len(item.title)>MAX_BODY || len(item.description)>MAX_BODY || len(item.brief_json)>MAX_BODY || len(encode(item.title))>MAX_ENCODED_FIELD || len(encode(item.description))>MAX_ENCODED_FIELD do return false
        key:=fmt.tprintf("%s:%d",stage.key,item.index)
        task:=workflow_task_id(chain,run,execution,key)
        if _,ok=query(s.db,"INSERT INTO tasks VALUES(?,?,?,?,1)",chain,task,item.title,item.description);!ok do return false
        if _,ok=query(s.db,"INSERT INTO local_workflow_tasks VALUES(?,?,?,?,?)",chain,run,execution,key,task);!ok do return false
        if _,ok=query(s.db,"INSERT INTO local_workflow_language_items VALUES(?,?,?,?,?,?,?,?)",task,stage.key,fmt.tprintf("%d",item.index),("gate" if item.kind==.Gate else "task"),item.priority,fmt.tprintf("%d",item.max_parallel),("1" if item.requires_user_approval else "0"),item.generated_by_json);!ok do return false
        if _,ok=query(s.db,"INSERT INTO task_requirements VALUES(?,?,1,?,?,?,?)",chain,task,item.brief_json,"",row[6],row[7]);!ok do return false
        if _,ok=query(s.db,"INSERT INTO lifecycle_state VALUES(?,?,?,0,'')",chain,task,("in_review" if item.kind==.Gate else "ready"));!ok do return false
        for dep in deps { if _,ok=query(s.db,"INSERT INTO local_dependencies VALUES(?,?,?)",chain,task,dep);!ok do return false }
        payload:=encode(doc(map[string]string{"task_id"=task,"title"=item.title,"metadata_revision"=receipts[0][0]}))
        if !intent_enqueue(s.active,Intent_Input{chain=chain,principal=row[6],operation=row[7],seq=number(receipts[0][0]),kind="registry.prepare",destination=task,fence="{}",payload=payload}) do return false
    }
    _,ok=query(s.db,"INSERT INTO local_workflow_stage_expansions VALUES(?,?,?,?,?)",chain,run,execution,stage.key,fmt.tprintf("%d",len(plan.items)))
    return ok
}

// Freeze exact encrypted/signed registry bytes before external publication.
// Recovered claims return the same bytes; encryption randomness is never replayed.
language_registry_prepare :: proc(s:^Store,claim:Intent_Claim,kr:^vault.Vault_Keyring,sign:Signer)->(string,bool) {
    if payload_hash(claim.payload)!=claim.digest do return "",false
    tx:Transaction
    if !transaction_begin(s,&tx) do return "",false
    defer transaction_rollback(&tx)
    rows,ok:=query(s.db,"SELECT state,claim_incarnation,attempts,payload_digest,chain_id FROM runtime_intents WHERE intent_id=? AND kind='registry.prepare'",claim.id)
    if !ok || len(rows)!=1 || rows[0][0]!="claimed" || number(rows[0][1])!=claim.incarnation || number(rows[0][2])!=claim.attempt || rows[0][3]!=claim.digest || rows[0][4]!=claim.chain do return "",false
    existing,read:=query(s.db,"SELECT registry_json FROM local_workflow_registry_envelopes WHERE intent_id=?",claim.id)
    if !read do return "",false
    result:=""
    if len(existing)==1 { result=existing[0][0] } else {
        v,valid:=contracts.owner_request_document(claim.payload);p,obj:=v.(json.Object)
        if !valid || !obj || sign.sign==nil do return "",false
        genesis,found:=query(s.db,"SELECT genesis_digest FROM chain_genesis WHERE chain_id=?",claim.chain)
        if !found || len(genesis)!=1 do return "",false
        title,sealed:=vault.seal_string(field(p,"title"),kr,context.temp_allocator)
        if !sealed do return "",false
        r:=doc(map[string]string{"protocol_version"="1","account_id"=s.account,"chain_id"=claim.chain,"owner_bridge_id"=s.owner,"key_id"=s.owner_key,"genesis_digest"=genesis[0][0],"metadata_revision"=field(p,"metadata_revision"),"task_id"=field(p,"task_id"),"chain_title_cipher"="","chain_description_cipher"="","task_title_cipher"=title,"deleted"="0","signature"=strings.repeat("0",128,context.temp_allocator)})
        sig,signed:=sign.sign(sign.ctx,"registry",r)
        if !signed do return "",false
        r["signature"]=json.String(sig);result=encode(r)
        if _,ok=query(s.db,"INSERT INTO local_workflow_registry_envelopes VALUES(?,?)",claim.id,result);!ok do return "",false
    }
    if !transaction_commit(&tx) do return "",false
    return result,true
}


language_claim_ready :: proc(s:^Store,chain,task:string)->bool {
    rows,ok:=query(s.db,"SELECT i.kind,i.max_parallel,t.run_id,t.execution,i.stage_key FROM local_workflow_tasks t JOIN local_workflow_language_items i USING(task_id) WHERE t.chain_id=? AND t.task_id=?",chain,task)
    if !ok do return false
    if len(rows)==0 do return true
    row:=rows[0]
    if row[0]!="task" do return false
    if !language_policy_ready(s,chain,task) do return false
    if number(row[1])==0 do return true
    live,read:=query(s.db,"SELECT count(*) FROM local_leases l JOIN local_workflow_tasks t ON t.chain_id=l.chain_id AND t.task_id=l.task_id JOIN local_workflow_language_items i USING(task_id) WHERE t.chain_id=? AND t.run_id=? AND t.execution=? AND i.stage_key=? AND l.retired_seq IS NULL",chain,row[2],row[3],row[4])
    return read && len(live)==1 && number(live[0][0])<number(row[1])
}

language_resolve_ref :: proc(s:^Store,chain,ref:string)->(string,string,bool) {
    definitions,ok:=query(s.db,"SELECT workflow_id,version,definition_json FROM local_workflow_definitions WHERE chain_id=? ORDER BY version DESC,workflow_id",chain)
    if !ok do return "","",false
    // Explicit definition identity wins over every definition-name alias.
    for row in definitions {
        if row[0]!=ref do continue
        if _,parsed:=language_definition(s,chain,row[0],row[1]);!parsed do return "","",false
        return row[0],row[1],true
    }
    for row in definitions {
        d,valid:=contracts.owner_parse(row[2],"workflow_language_definition")
        if !valid do continue
        spec,parsed,_:=wf.parse_bounded(field(d,"spec"))
        if !parsed do return "","",false
        native,native_ok:=contracts.owner_request_document(field(d,"spec"))
        object,is_object:=native.(json.Object)
        alias:=ref
        if strings.has_prefix(alias,"builtin:") do alias=alias[len("builtin:"):]
        if spec.name==ref || spec.name==alias || (native_ok && is_object && field(object,"id")==ref) do return row[0],row[1],true
    }
    return "","",false
}
language_triggers :: proc(s:^Store)->(bool,bool) {
    rows,ok:=query(s.db,"SELECT t.chain_id,t.run_id,t.execution,t.task_id,l.attempt,q.brief_json,COALESCE(o.output_json,'{}'),x.principal_id,x.operation_id FROM local_workflow_tasks t JOIN local_workflow_runs r USING(chain_id,run_id) JOIN local_workflow_language_executions x USING(chain_id,run_id,execution) JOIN lifecycle_state l ON l.chain_id=t.chain_id AND l.task_id=t.task_id JOIN task_requirements q ON q.chain_id=t.chain_id AND q.task_id=t.task_id LEFT JOIN local_workflow_outputs o ON o.chain_id=t.chain_id AND o.task_id=t.task_id AND o.attempt=l.attempt WHERE t.execution=r.current_execution AND x.state IN('running','done') AND l.state='done' AND json_type(q.brief_json,'$.on_output')='object' AND q.revision=(SELECT max(revision) FROM task_requirements qr WHERE qr.chain_id=q.chain_id AND qr.task_id=q.task_id) AND NOT EXISTS(SELECT 1 FROM local_workflow_output_triggers g WHERE g.chain_id=t.chain_id AND g.source_task=t.task_id AND g.source_attempt=l.attempt) AND NOT EXISTS(SELECT 1 FROM local_workflow_trigger_failures f WHERE f.chain_id=t.chain_id AND f.source_task=t.task_id AND f.source_attempt=l.attempt) ORDER BY t.chain_id,t.run_id,t.task_id")
    if !ok do return false,false
    changed:=false
    for row in rows {
        v,parse_err:=json.parse(transmute([]u8)row[5],parse_integers=true,allocator=context.temp_allocator)
        valid:=parse_err==nil
        brief,obj:=v.(json.Object)
        if !valid || !obj do return false,false
        trigger,has:=brief["on_output"].(json.Object)
        if !has do continue
        ref:=field(trigger,"start_workflow")
        if ref=="" do ref=field(trigger,"workflow")
        workflow,version,resolved:=language_resolve_ref(s,row[0],ref)
        // Missing/invalid references are durable workflow failures, never a
        // successful task pretending that its follow-up ran.
        if !resolved {
            if _,ok=query(s.db,"INSERT INTO local_workflow_trigger_failures VALUES(?,?,?,'workflow_trigger_not_found')",row[0],row[3],row[4]);!ok do return false,false
            continue
        }
        count,read:=query(s.db,"SELECT count(*) FROM local_workflow_runs WHERE chain_id=?",row[0])
        if !read || len(count)!=1 do return false,false
        if number(count[0][0])>=128 do continue
        input:=row[6]
        if value,present:=trigger["inputs"];present {
            mapping,object:=value.(json.Object)
            if !object do return false,false
            values:=make(json.Object,context.temp_allocator)
            for key,value in mapping {
                if text,is_string:=value.(json.String);is_string {
                    values[key]=json.String(wf.substitute_on_output_placeholders(string(text),row[6]))
                } else { values[key]=value }
            }
            input=encode(values)
        }
        spec,parsed:=language_definition(s,row[0],workflow,version)
        if !parsed do return false,false
        if _,err:=wf.snapshot(spec,input);err.code!=.None {
            if _,ok=query(s.db,"INSERT INTO local_workflow_trigger_failures VALUES(?,?,?,'workflow_trigger_invalid_inputs')",row[0],row[3],row[4]);!ok do return false,false
            continue
        }
        run:=fmt.tprintf("run_%s",payload_hash(encode([3]string{row[0],row[3],row[4]})))
        if _,ok=query(s.db,"INSERT INTO local_workflow_runs VALUES(?,?,?,?,1,1)",row[0],run,workflow,version);!ok do return false,false
        if _,ok=query(s.db,"INSERT INTO local_workflow_language_runs VALUES(?,?,?)",row[0],run,input);!ok do return false,false
        receipt,read_receipt:=query(s.db,"SELECT commit_seq FROM command_receipts WHERE principal_id=? AND operation_id=?",row[7],row[8])
        if !read_receipt || len(receipt)!=1 do return false,false
        c:=doc(map[string]string{"principal_id"=row[7],"operation_id"=row[8]})
        if !language_execution(s,row[0],run,"1",c,number(receipt[0][0])) do return false,false
        if _,ok=query(s.db,"INSERT INTO local_workflow_output_triggers VALUES(?,?,?,?,?,?,0)",row[0],row[3],row[4],row[1],row[2],run);!ok do return false,false
        changed=true
    }
    return changed,true
}

language_merges_settled :: proc(s:^Store,chain,run,execution:string)->bool {
    rows,ok:=query(s.db,"SELECT 1 FROM runtime_intents n JOIN local_workflow_tasks t ON t.chain_id=n.chain_id AND t.task_id=json_extract(n.exact_fence_json,'$.task_id') WHERE t.chain_id=? AND t.run_id=? AND t.execution=? AND n.kind='merge' AND n.state!='settled' AND (n.state='claimed' OR NOT EXISTS(SELECT 1 FROM intent_invalidations x WHERE x.intent_id=n.intent_id)) LIMIT 1",chain,run,execution)
    return ok && len(rows)==0
}
language_stop :: proc(s:^Store,c:json.Object,run,execution:string,seq:i64)->bool {
    rows,ok:=query(s.db,"SELECT task_id FROM local_workflow_tasks WHERE chain_id=? AND run_id=? AND execution=?",field(c,"chain_id"),run,execution)
    if !ok do return false
    for row in rows {
        merging,merge_read:=query(s.db,"SELECT 1 FROM runtime_intents n WHERE n.chain_id=? AND n.kind='merge' AND json_extract(n.exact_fence_json,'$.task_id')=? AND n.state!='settled' AND (n.state='claimed' OR NOT EXISTS(SELECT 1 FROM intent_invalidations x WHERE x.intent_id=n.intent_id)) LIMIT 1",field(c,"chain_id"),row[0])
        if !merge_read do return false
        // A possible Git CAS must settle before retry. Revoking its evidence
        // would strand the callback and incorrectly release the generation.
        if len(merging)>0 do continue
        command:=doc(map[string]string{"chain_id"=field(c,"chain_id"),"task_id"=row[0],"principal_id"=field(c,"principal_id"),"operation_id"=field(c,"operation_id")})
        if !control_revoke(s,command,seq,"checkpoint") do return false
        if _,ok=query(s.db,"DELETE FROM local_checkpoints WHERE chain_id=? AND task_id=?",field(c,"chain_id"),row[0]);!ok do return false
        if _,ok=query(s.db,"UPDATE source_episodes SET resolved=1,source_version=? WHERE chain_id=? AND origin_kind='local.review' AND origin_id=? AND resolved=0",fmt.tprintf("%d",seq),field(c,"chain_id"),row[0]);!ok do return false
    }
    return true
}


language_fail :: proc(s:^Store,row:[]string,reason:string)->bool {
    current,ok:=query(s.db,"SELECT max(commit_seq) FROM (SELECT commit_seq FROM runtime_database UNION ALL SELECT commit_seq FROM command_receipts)")
    receipt,read:=query(s.db,"SELECT commit_seq FROM command_receipts WHERE principal_id=? AND operation_id=?",row[6],row[7])
    if !ok || !read || len(current)!=1 || len(receipt)!=1 do return false
    c:=doc(map[string]string{"chain_id"=row[0],"principal_id"=row[6],"operation_id"=row[7],"method"="workflow.failed","task_id"=""})
    if !language_stop(s,c,row[1],row[2],number(current[0][0])) || !control_intents(s.active,c,number(receipt[0][0])) do return false
    _,ok=query(s.db,"UPDATE local_workflow_language_executions SET state='failed',failure=? WHERE chain_id=? AND run_id=? AND execution=?",reason,row[0],row[1],row[2])
    return ok
}


language_policy_ready :: proc(s:^Store,chain,task:string)->bool {
    req,found:=lifecycle_requirements(s,chain,task)
    if !found do return false
    v,valid:=contracts.owner_request_document(req[1]);brief,obj:=v.(json.Object)
    if !valid || !obj do return false
    config,_,configured:=lifecycle_config(s,chain,task)
    if !configured do return false
    if assignee:=field(brief,"assignee");assignee!="" && assignee!=field(config,"author_agent_id") do return false
    for name in ([2]string{"review_roles","reviewers"}) {
        if values,exists:=brief[name];exists {
            list,array:=values.(json.Array)
            if !array do return false
            for value in list {
                text,is_string:=value.(json.String)
                if !is_string do return false
                if name=="reviewers" && string(text)==field(config,"reviewer_agent_id") do continue
                column:="role"
                if name=="reviewers" do column="agent_id"
                sql:=fmt.tprintf("SELECT 1 FROM local_role_pairs p WHERE p.chain_id=? AND p.task_id=? AND p.%s=? AND p.revision=(SELECT max(revision) FROM local_role_configs c WHERE c.chain_id=p.chain_id AND c.task_id=p.task_id)",column)
                pairs,read:=query(s.db,sql,chain,task,string(text))
                if !read || len(pairs)==0 do return false
            }
        }
    }
    return true
}
