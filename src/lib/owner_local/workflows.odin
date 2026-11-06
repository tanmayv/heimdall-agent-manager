#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"
import vault "odin_test:lib/vault"
import wf "odin_test:lib/workflow_v1"

workflow_stages :: proc(def:json.Object) -> ([]json.Object,bool) {
    if strings.contains(field(def,"title"),"{{") || strings.contains(field(def,"title"),"}}") do return nil,false
    v,valid:=contracts.owner_request_document(field(def,"stages"))
    a,array:=v.(json.Array)
    if !valid || !array || len(a)<1 || len(a)>32 do return nil,false
    stages:=make([]json.Object,len(a),context.temp_allocator)
    keys:=make(map[string]bool,context.temp_allocator)
    for item,i in a {
        o,obj:=item.(json.Object)
        if !obj || !contracts.owner_document_valid("workflow_stage",o) || !brief_valid(field(o,"brief")) do return nil,false
        for name in ([2]string{"title","body"}) {
            if strings.contains(field(o,name),"{{") || strings.contains(field(o,name),"}}") do return nil,false
        }
        if !wf.static_brief_bounded(field(o,"brief")) do return nil,false
        key:=field(o,"key")
        if keys[key] || len(field(o,"title"))>MAX_BODY || len(field(o,"body"))>MAX_BODY || len(encode(field(o,"title")))>MAX_ENCODED_FIELD || len(encode(field(o,"body")))>MAX_ENCODED_FIELD do return nil,false
        // Definitions are topologically ordered. This admits arbitrary static
        // DAGs while rejecting cycles and unknown prerequisites before writes.
        deps,parsed:=contracts.owner_request_document(field(o,"depends_on"))
        dependencies,is_array:=deps.(json.Array)
        if !parsed || !is_array || len(dependencies)>32 do return nil,false
        seen:=make(map[string]bool,context.temp_allocator)
        for dep in dependencies {
            name,text:=dep.(json.String)
            if !text || !keys[string(name)] || seen[string(name)] do return nil,false
            seen[string(name)]=true
        }
        keys[key]=true;stages[i]=o
    }
    return stages,true
}
workflow_task_id :: proc(chain,run,execution,key:string)->string {
    return fmt.tprintf("task_%s",payload_hash(encode([4]string{chain,run,execution,key})))
}
workflow_expand :: proc(s:^Store,chain,run,execution:string,stages:[]json.Object,c:json.Object,seq:i64)->bool {
    if _,ok:=query(s.db,"INSERT INTO local_workflow_executions VALUES(?,?,?,'running')",chain,run,execution);!ok do return false
    for stage in stages {
        task:=workflow_task_id(chain,run,execution,field(stage,"key"))
        if _,ok:=query(s.db,"INSERT INTO tasks VALUES(?,?,?,?,1)",chain,task,field(stage,"title"),field(stage,"body"));!ok do return false
        if _,ok:=query(s.db,"INSERT INTO local_workflow_tasks VALUES(?,?,?,?,?)",chain,run,execution,field(stage,"key"),task);!ok do return false
        if _,ok:=query(s.db,"INSERT INTO task_requirements VALUES(?,?,1,?,?,?,?)",chain,task,field(stage,"brief"),"",field(c,"principal_id"),field(c,"operation_id"));!ok do return false
        if _,ok:=query(s.db,"INSERT INTO lifecycle_state VALUES(?,?,'ready',0,'')",chain,task);!ok do return false
        v,_:=contracts.owner_request_document(field(stage,"depends_on"));deps,_:=v.(json.Array)
        for dep in deps {
            key,_:=dep.(json.String)
            if _,ok:=query(s.db,"INSERT INTO local_dependencies VALUES(?,?,?)",chain,task,workflow_task_id(chain,run,execution,string(key)));!ok do return false
        }
    }
    _,ok:=query(s.db,"INSERT INTO local_workflow_events VALUES(?,?,?,?,'expanded',?,?)",chain,run,execution,fmt.tprintf("%d",seq),field(c,"principal_id"),field(c,"operation_id"))
    return ok
}
workflow_command :: proc(s:^Store,c:json.Object,body:string,seq:i64)->string {
    if handled,code:=language_command(s,c,body,seq);handled do return code
    chain,method:=field(c,"chain_id"),field(c,"method")
    kind:="workflow_run"
    if method=="workflow.define" do kind="workflow_definition"
    if method=="workflow.retry" do kind="workflow_retry"
    p,valid:=contracts.owner_parse(body,kind)
    if !valid do return "malformed"
    if method=="workflow.define" {
        if _,ok:=workflow_stages(p);!ok do return "invalid_content"
        if _,ok:=query(s.db,"INSERT INTO local_workflow_definitions VALUES(?,?,?,?)",chain,field(p,"workflow_id"),field(p,"version"),body);!ok do return "operation_conflict"
        return "ok"
    }
    run,execution:=field(p,"run_id"),"1"
    workflow,version:=field(p,"workflow_id"),field(p,"version")
    if method=="workflow.retry" {
        rows,ok:=query(s.db,"SELECT workflow_id,definition_version,current_execution FROM local_workflow_runs WHERE chain_id=? AND run_id=?",chain,run)
        if !ok do return "storage_error"
        if len(rows)!=1 || rows[0][2]!=field(p,"execution") do return "stale_revision"
        consumed,read_consumed:=query(s.db,"SELECT 1 FROM local_workflow_output_triggers WHERE chain_id=? AND source_run=? AND consumed=1 LIMIT 1",chain,run)
        if !read_consumed do return "storage_error"
        if len(consumed)>0 do return "operation_conflict"
        workflow=rows[0][0];version=rows[0][1]
        execution=fmt.tprintf("%d",number(rows[0][2])+1)
        old,read:=query(s.db,"SELECT task_id FROM local_workflow_tasks WHERE chain_id=? AND run_id=? AND execution=?",chain,run,rows[0][2])
        if !read do return "storage_error"
        for row in old {
            command:=doc(map[string]string{"chain_id"=chain,"task_id"=row[0],"principal_id"=field(c,"principal_id"),"operation_id"=field(c,"operation_id")})
            command["method"]=json.String(method)
            if !workflow_retire_task(s,command,run,rows[0][2],row[0],seq) do return "storage_error"
            if !control_revoke(s,command,seq,"checkpoint") do return "storage_error"
            if _,ok=query(s.db,"DELETE FROM local_checkpoints WHERE chain_id=? AND task_id=?",chain,row[0]);!ok do return "storage_error"
            // No future verdict may complete an obsolete execution's review.
            // Resolve its producers in this same retry transaction, preserving
            // card identity/closure and every consumption/ACK/retirement floor.
            if _,ok=query(s.db,"UPDATE source_episodes SET resolved=1,source_version=? WHERE chain_id=? AND origin_kind='local.review' AND origin_id=? AND resolved=0",fmt.tprintf("%d",seq),chain,row[0]);!ok do return "storage_error"
        }
        if _,ok=query(s.db,"UPDATE local_workflow_executions SET state='superseded' WHERE chain_id=? AND run_id=? AND execution=?",chain,run,rows[0][2]);!ok do return "storage_error"
        if _,ok=query(s.db,"UPDATE local_workflow_runs SET current_execution=?,revision=revision+1 WHERE chain_id=? AND run_id=?",execution,chain,run);!ok do return "storage_error"
    }
    definitions,ok:=query(s.db,"SELECT definition_json FROM local_workflow_definitions WHERE chain_id=? AND workflow_id=? AND version=?",chain,workflow,version)
    if !ok do return "storage_error"
    if len(definitions)!=1 do return "invalid_scope"
    def,parsed:=contracts.owner_parse(definitions[0][0],"workflow_definition")
    stages,valid_stages:=workflow_stages(def)
    if !parsed || !valid_stages do return "storage_error"
    if method=="workflow.run" {
        if _,ok=query(s.db,"INSERT INTO local_workflow_runs VALUES(?,?,?,?,1,1)",chain,run,workflow,version);!ok do return "operation_conflict"
    }
    if !workflow_expand(s,chain,run,execution,stages,c,seq) do return "storage_error"
    return "ok"
}
workflow_task_current :: proc(s:^Store,chain,task:string)->bool {
    rows,ok:=query(s.db,"SELECT 1 FROM local_workflow_tasks t WHERE t.chain_id=? AND t.task_id=? AND NOT EXISTS(SELECT 1 FROM local_workflow_runs r JOIN local_workflow_executions e USING(chain_id,run_id) WHERE r.chain_id=t.chain_id AND r.run_id=t.run_id AND r.current_execution=t.execution AND e.execution=t.execution AND e.state='running')",chain,task)
    if !ok || len(rows)>0 do return false
    stopped,read:=query(s.db,"SELECT 1 FROM local_workflow_tasks t JOIN local_workflow_language_executions e USING(chain_id,run_id,execution) WHERE t.chain_id=? AND t.task_id=? AND e.state!='running'",chain,task)
    return read && len(stopped)==0
}
dependency_ready :: proc(s:^Store,chain,task:string)->bool {
    if !workflow_task_current(s,chain,task) do return false
    rows,ok:=query(s.db,"SELECT 1 FROM local_dependencies d LEFT JOIN lifecycle_state s ON s.chain_id=d.chain_id AND s.task_id=d.prerequisite LEFT JOIN local_controls c ON c.chain_id=d.chain_id AND c.task_id=d.prerequisite WHERE d.chain_id=? AND d.task_id=? AND (s.state IS NULL OR s.state!='done' OR COALESCE(c.mode,'ready')!='ready') LIMIT 1",chain,task)
    return ok && len(rows)==0
}
dependency_command :: proc(s:^Store,c,p:json.Object)->string {
    chain,task:=field(c,"chain_id"),field(c,"task_id")
    if !workflow_task_current(s,chain,task) do return "stale_revision"
    busy,ok:=query(s.db,"SELECT 1 FROM local_leases WHERE chain_id=? AND task_id=? UNION SELECT 1 FROM local_submissions WHERE chain_id=? AND task_id=? UNION SELECT 1 FROM local_workflow_tasks WHERE chain_id=? AND task_id IN(?,?)",chain,task,chain,task,chain,task,field(p,"prerequisite"))
    if !ok do return "storage_error"
    if len(busy)>0 do return "operation_conflict"
    if field(p,"enabled")=="1" {
        if _,ok=query(s.db,"INSERT INTO local_dependencies VALUES(?,?,?)",chain,task,field(p,"prerequisite"));!ok do return "operation_conflict"
    } else {
        if _,ok=query(s.db,"DELETE FROM local_dependencies WHERE chain_id=? AND task_id=? AND prerequisite=?",chain,task,field(p,"prerequisite"));!ok do return "storage_error"
    }
    if _,ok=query(s.db,"UPDATE tasks SET revision=revision+1 WHERE chain_id=? AND task_id=?",chain,task);!ok do return "storage_error"
    return "ok"
}
workflow_refresh :: proc(s:^Store)->bool {
    _,ok:=query(s.db,"UPDATE local_workflow_executions SET state='done' WHERE state='running' AND NOT EXISTS(SELECT 1 FROM local_workflow_language_runs v WHERE v.chain_id=local_workflow_executions.chain_id AND v.run_id=local_workflow_executions.run_id) AND NOT EXISTS(SELECT 1 FROM local_workflow_tasks t LEFT JOIN lifecycle_state s ON s.chain_id=t.chain_id AND s.task_id=t.task_id LEFT JOIN local_controls c ON c.chain_id=t.chain_id AND c.task_id=t.task_id WHERE t.chain_id=local_workflow_executions.chain_id AND t.run_id=local_workflow_executions.run_id AND t.execution=local_workflow_executions.execution AND (s.state IS NULL OR s.state!='done' OR COALESCE(c.mode,'ready')!='ready'))")
    return ok && language_refresh(s)
}

workflow_publications :: proc(tx:^Transaction,c:json.Object,body:string,seq:i64,kr:^vault.Vault_Keyring,sign:Signer)->bool {
    method:=field(c,"method")
    if method!="workflow.run" && method!="workflow.retry" do return true
    language_rows,check:=query(tx.store.db,"SELECT 1 FROM local_workflow_language_runs WHERE chain_id=? AND run_id=json_extract(?,'$.run_id')",field(c,"chain_id"),body)
    if !check do return false
    if len(language_rows)>0 do return true
    p,valid:=contracts.owner_parse(body,("workflow_run" if method=="workflow.run" else "workflow_retry"))
    if !valid || sign.sign==nil do return false
    s:=tx.store;chain:=field(c,"chain_id")
    rows,ok:=query(s.db,"SELECT t.task_id,t.title FROM local_workflow_tasks w JOIN local_workflow_runs r USING(chain_id,run_id) JOIN tasks t ON t.chain_id=w.chain_id AND t.task_id=w.task_id WHERE w.chain_id=? AND w.run_id=? AND w.execution=r.current_execution",chain,field(p,"run_id"))
    genesis,read:=query(s.db,"SELECT genesis_digest FROM chain_genesis WHERE chain_id=?",chain)
    if !ok || !read || len(genesis)!=1 do return false
    for row in rows {
        title,sealed:=vault.seal_string(row[1],kr,context.temp_allocator)
        if !sealed do return false
        r:=doc(map[string]string{"protocol_version"="1","account_id"=s.account,"chain_id"=chain,"owner_bridge_id"=s.owner,"key_id"=s.owner_key,"genesis_digest"=genesis[0][0],"metadata_revision"=fmt.tprintf("%d",seq),"task_id"=row[0],"chain_title_cipher"="","chain_description_cipher"="","task_title_cipher"=title,"deleted"="0","signature"=strings.repeat("0",128,context.temp_allocator)})
        sig,signed:=sign.sign(sign.ctx,"registry",r)
        if !signed do return false
        r["signature"]=json.String(sig)
        if !intent_enqueue(tx,Intent_Input{chain=chain,principal=field(c,"principal_id"),operation=field(c,"operation_id"),seq=seq,kind="registry",destination=row[0],fence="{}",payload=encode(r)}) do return false
    }
    return true
}

workflow_inventory :: proc(s:^Store,chain,cursor:string,limit,revision:i64)->Result {
    if limit<1 || limit>100 do return fail("malformed")
    state,read:=query(s.db,"SELECT commit_seq FROM runtime_database")
    if !read || len(state)!=1 do return fail("storage_error")
    scope:=payload_hash(encode([3]string{chain,"workflow",state[0][0]}))
    offset:i64
    if cursor!="" {
        parts:=strings.split(cursor,":",context.temp_allocator)
        if len(parts)!=2 || parts[0]!=scope do return fail("stale_cursor")
        offset=number(parts[1])
        if offset<0 || offset>MAX_RECORDS || fmt.tprintf("%d",offset)!=parts[1] do return fail("malformed")
    }
    rows,ok:=query(s.db,`SELECT * FROM (
      SELECT 'run' AS kind,r.run_id,r.workflow_id AS a,cast(r.definition_version AS TEXT) AS b,cast(r.current_execution AS TEXT) AS c,cast(r.revision AS TEXT) AS d,COALESCE(x.state,e.state) AS e
      FROM local_workflow_runs r JOIN local_workflow_executions e ON e.chain_id=r.chain_id AND e.run_id=r.run_id AND e.execution=r.current_execution LEFT JOIN local_workflow_language_executions x ON x.chain_id=r.chain_id AND x.run_id=r.run_id AND x.execution=r.current_execution WHERE r.chain_id=?
      UNION ALL SELECT 'task',run_id,cast(execution AS TEXT),stage_key,task_id,'','' FROM local_workflow_tasks WHERE chain_id=?
      UNION ALL SELECT 'event',run_id,cast(execution AS TEXT),cast(event_seq AS TEXT),kind,principal_id,operation_id FROM local_workflow_events WHERE chain_id=?
      UNION ALL SELECT 'event',COALESCE(t.run_id,f.source_task),cast(COALESCE(t.execution,f.source_attempt) AS TEXT),'trigger_failed',f.reason,f.source_task,cast(f.source_attempt AS TEXT) FROM local_workflow_trigger_failures f LEFT JOIN local_workflow_tasks t ON t.chain_id=f.chain_id AND t.task_id=f.source_task WHERE f.chain_id=?
      ) ORDER BY kind,run_id,a,b LIMIT ? OFFSET ?`,chain,chain,chain,chain,fmt.tprintf("%d",limit+1),fmt.tprintf("%d",offset))
    if !ok do return fail("storage_error")
    runs:=make([dynamic][]string,context.temp_allocator)
    tasks:=make([dynamic][]string,context.temp_allocator)
    events:=make([dynamic][]string,context.temp_allocator)
    count:=min(len(rows),int(limit))
    for row in rows[:count] {
        switch row[0] {
        case "run":append(&runs,row[1:])
        case "task":append(&tasks,row[1:5])
        case "event":append(&events,row[1:])
        }
    }
    next:=""
    if count<len(rows) do next=fmt.tprintf("%s:%d",scope,offset+i64(count))
    body:=encode(struct{kind,revision,next_cursor:string,runs,tasks,events:[dynamic][]string}{"workflow",fmt.tprintf("%d",revision),next,runs,tasks,events})
    if len(body)>MAX_PAGE do return fail("invalid_content")
    return Result{code="ok",body=body}
}
