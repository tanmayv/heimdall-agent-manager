#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"

Work_Snapshot :: struct { generation:i64, started,terminal,succeeded:bool, manifest:string, }
work_ref :: proc(o:json.Object,name:string)->json.Object {v,_:=o[name].(json.Object);return v}
work_snapshot :: proc(s:^Store,chain,kind,id:string)->(Work_Snapshot,bool) {
    if kind=="task" {
        rows,ok:=query(s.db,"SELECT COALESCE(l.state,'ready'),COALESCE(c.mode,'ready') FROM tasks t LEFT JOIN lifecycle_state l USING(chain_id,task_id) LEFT JOIN local_controls c USING(chain_id,task_id) WHERE t.chain_id=? AND t.task_id=? AND NOT EXISTS(SELECT 1 FROM local_workflow_tasks w WHERE w.chain_id=t.chain_id AND w.task_id=t.task_id)",chain,id)
        if !ok || len(rows)!=1 do return {},false
        view,read:=attempt_view(s,chain,id)
        if !read || view.incomplete do return {},false
        done:=rows[0][0]=="done" && rows[0][1]=="ready"
        cancelled:=rows[0][1]=="cancelled"
        manifest:=encode(struct {task_id:string,attempt_no:i64,output_ref:string,}{id,view.attempt_no,fmt.tprintf("facet:%s:%d:output",id,view.attempt_no)})
        return Work_Snapshot{view.attempt_no,view.attempt_no>0 || done || cancelled,done || cancelled,done && view.attempt_no>0,manifest},true
    }
    if kind!="workflow_run" do return {},false
    rows,ok:=query(s.db,"SELECT r.current_execution,COALESCE(l.state,e.state) FROM local_workflow_runs r JOIN local_workflow_executions e ON e.chain_id=r.chain_id AND e.run_id=r.run_id AND e.execution=r.current_execution LEFT JOIN local_workflow_language_executions l ON l.chain_id=e.chain_id AND l.run_id=e.run_id AND l.execution=e.execution WHERE r.chain_id=? AND r.run_id=?",chain,id)
    if !ok do return {},false
    if len(rows)==0 {
        pending,read:=query(s.db,"SELECT 1 FROM local_work_pending_runs WHERE chain_id=? AND run_id=?",chain,id)
        if !read || len(pending)!=1 do return {},false
        cancelled,cancel_read:=query(s.db,"SELECT 1 FROM local_work_run_cancellations WHERE chain_id=? AND run_id=?",chain,id)
        return Work_Snapshot{generation=1,started=len(cancelled)>0,terminal=len(cancelled)>0},cancel_read
    }
    execution,state:=rows[0][0],rows[0][1]
    manifest,read:=work_run_manifest(s,chain,id,execution)
    if !read do return {},false
    return Work_Snapshot{number(execution),true,state=="done" || state=="failed" || state=="cancelled" || state=="superseded",state=="done",manifest},true
}
work_inputs_ready :: proc(s:^Store,chain,kind,id:string)->bool {
    edges,ok:=query(s.db,`SELECT prerequisite_kind,prerequisite_id FROM local_work_active_dependencies WHERE chain_id=?1 AND dependent_kind=?2 AND dependent_id=?3
      UNION SELECT 'task',prerequisite FROM local_dependencies d WHERE chain_id=?1 AND task_id=?3 AND ?2='task'
      AND NOT EXISTS(SELECT 1 FROM local_workflow_tasks w WHERE w.chain_id=d.chain_id AND w.task_id=d.task_id)`,chain,kind,id)
    if !ok do return false
    for edge in edges {
        snapshot,valid:=work_snapshot(s,chain,edge[0],edge[1])
        if !valid || !snapshot.succeeded do return false
    }
    return true
}
work_unconsumed :: proc(s:^Store,chain,kind,id:string)->bool {
    rows,ok:=query(s.db,"SELECT 1 FROM local_work_inputs WHERE chain_id=? AND prerequisite_kind=? AND prerequisite_id=? LIMIT 1",chain,kind,id)
    return ok && len(rows)==0
}
work_capture_inputs :: proc(s:^Store,chain,kind,id:string,seq,now:i64)->bool {
    consumer,valid:=work_snapshot(s,chain,kind,id)
    if !valid || !consumer.started || consumer.terminal || consumer.generation<1 do return false
    edges,ok:=query(s.db,"SELECT prerequisite_kind,prerequisite_id FROM local_work_active_dependencies WHERE chain_id=? AND dependent_kind=? AND dependent_id=? ORDER BY prerequisite_kind,prerequisite_id",chain,kind,id)
    if !ok do return false
    generation:=fmt.tprintf("%d",consumer.generation)
    for edge in edges {
        provider,valid:=work_snapshot(s,chain,edge[0],edge[1])
        if !valid || !provider.succeeded || provider.generation<1 do return false
        prior,read:=query(s.db,"SELECT prerequisite_generation,output_manifest_json FROM local_work_inputs WHERE chain_id=? AND dependent_kind=? AND dependent_id=? AND dependent_generation=? AND prerequisite_kind=? AND prerequisite_id=?",chain,kind,id,generation,edge[0],edge[1])
        if !read do return false
        if len(prior)>0 {
            if number(prior[0][0])!=provider.generation || prior[0][1]!=provider.manifest do return false
            continue
        }
        receipt:=fmt.tprintf("winput_%s",payload_hash(encode([6]string{s.account,chain,kind,id,generation,encode(edge)})))
        if _,ok=query(s.db,"INSERT INTO local_work_inputs VALUES(?,?,?,?,?,?,?,?,?,?,?)",receipt,chain,kind,id,generation,edge[0],edge[1],fmt.tprintf("%d",provider.generation),provider.manifest,work_time(now),fmt.tprintf("%d",seq));!ok do return false
    }
    return true
}
work_dependency_add :: proc(s:^Store,c,p:json.Object,seq,now:i64)->string {
    chain:=field(c,"chain_id")
    dependent,prerequisite:=work_ref(p,"dependent"),work_ref(p,"prerequisite")
    dk,di,pk,pi:=field(dependent,"kind"),field(dependent,"id"),field(prerequisite,"kind"),field(prerequisite,"id")
    consumer,ok:=work_snapshot(s,chain,dk,di)
    if !ok do return "invalid_scope"
    if _,ok=work_snapshot(s,chain,pk,pi);!ok do return "invalid_scope"
    existing,read:=query(s.db,"SELECT dependency_id FROM local_work_active_dependencies WHERE chain_id=? AND dependent_kind=? AND dependent_id=? AND prerequisite_kind=? AND prerequisite_id=?",chain,dk,di,pk,pi)
    if !read do return "storage_error"
    if len(existing)>0 do return "ok"
    if consumer.started do return "operation_conflict"
    if dk==pk && di==pi do return "invalid_content"
    if !work_edge_acyclic(s,chain,dk,di,pk,pi) do return "operation_conflict"
    if _,ok=query(s.db,"INSERT INTO local_work_dependencies VALUES(?,?,?,?,?,?,?,?,?,?)",chain,field(p,"dependency_id"),dk,di,pk,pi,work_time(now), "user",s.account,fmt.tprintf("%d",seq));!ok do return "operation_conflict"
    return "ok"
}
work_scope :: proc(s:^Store,c,p:json.Object,seq,now:i64)->string {
    item:=work_ref(p,"item");chain:=field(c,"chain_id")
    snapshot,valid:=work_snapshot(s,chain,field(item,"kind"),field(item,"id"))
    if !valid do return "invalid_scope"
    if field(p,"action")=="exclude" && !snapshot.terminal do return "operation_conflict"
    if _,ok:=query(s.db,"INSERT INTO local_work_scope VALUES(?,?,?,?,?,?,?,?,?,?)",fmt.tprintf("%d",seq),chain,field(item,"kind"),field(item,"id"),field(p,"action"),field(p,"reason"),"user",s.account,work_time(now),fmt.tprintf("%d",seq));!ok do return "storage_error"
    return "ok"
}
work_complete :: proc(s:^Store,c,p:json.Object,seq,now:i64)->string {
    chain:=field(c,"chain_id")
    pending,_,read:=work_pending(s,chain)
    if !read do return "storage_error"
    if pending!=nil do return "operation_conflict"
    revision,ok:=query(s.db,"SELECT work_revision FROM local_work_chains WHERE chain_id=?",chain)
    if !ok || len(revision)!=1 do return "storage_error"
    if revision[0][0]!=field(p,"expected_work_revision") do return "stale_revision"
    items,items_read:=query(s.db,"SELECT 'task',task_id FROM tasks t WHERE chain_id=?1 AND NOT EXISTS(SELECT 1 FROM local_workflow_tasks w WHERE w.chain_id=t.chain_id AND w.task_id=t.task_id) UNION SELECT 'workflow_run',run_id FROM local_workflow_runs WHERE chain_id=?1 UNION SELECT 'workflow_run',run_id FROM local_work_pending_runs WHERE chain_id=?1",chain)
    if !items_read do return "storage_error"
    successes:=0
    for item in items {
        snapshot,valid:=work_snapshot(s,chain,item[0],item[1])
        if !valid do return "invalid_scope"
        scope,read:=query(s.db,"SELECT action FROM local_work_scope WHERE chain_id=? AND item_kind=? AND item_id=? ORDER BY decision_id DESC LIMIT 1",chain,item[0],item[1])
        if !read do return "storage_error"
        if len(scope)>0 && scope[0][0]=="exclude" {
            if !snapshot.terminal do return "operation_conflict"
            continue
        }
        if !snapshot.succeeded || !work_inputs_ready(s,chain,item[0],item[1]) do return "operation_conflict"
        if item[0]=="task" && !work_task_published(s,chain,item[1]) do return "operation_conflict"
        successes+=1
    }
    if successes==0 do return "operation_conflict"
    leases,leases_read:=query(s.db,"SELECT 1 FROM local_leases WHERE chain_id=? AND retired_seq IS NULL UNION SELECT 1 FROM local_review_sessions WHERE chain_id=? LIMIT 1",chain,chain)
    if !leases_read do return "storage_error"
    if len(leases)>0 do return "operation_conflict"
    if _,ok=query(s.db,"INSERT INTO local_work_completions VALUES(?,?,?,?,?,?,?)",chain,revision[0][0],field(p,"summary"),work_time(now),"user",s.account,fmt.tprintf("%d",seq));!ok do return "storage_error"
    if _,ok=query(s.db,"UPDATE local_work_chains SET status='completed' WHERE chain_id=?",chain);!ok do return "storage_error"
    return "ok"
}

// Include V1 ordinary task edges in the effective graph; stage edges stay private.
work_edge_acyclic :: proc(s:^Store,chain,dk,di,pk,pi:string)->bool {
    cycle,cycle_read:=query(s.db,`WITH RECURSIVE edges(dk,di,pk,pi) AS (
      SELECT dependent_kind,dependent_id,prerequisite_kind,prerequisite_id FROM local_work_active_dependencies WHERE chain_id=?1
      UNION SELECT 'task',task_id,'task',prerequisite FROM local_dependencies d WHERE chain_id=?1
        AND NOT EXISTS(SELECT 1 FROM local_workflow_tasks w WHERE w.chain_id=d.chain_id AND w.task_id=d.task_id)),
      reachable(kind,id) AS (SELECT ?2,?3 UNION SELECT e.pk,e.pi FROM edges e JOIN reachable r ON r.kind=e.dk AND r.id=e.di)
      SELECT 1 FROM reachable WHERE kind=?4 AND id=?5 LIMIT 1`,chain,pk,pi,dk,di)
    return cycle_read && len(cycle)==0
}

// Native workflow manifests are stage-key -> ordered raw output arrays.
// Read the existing executor's current submitted outputs; absent output is {}.
work_run_manifest :: proc(s:^Store,chain,run,execution:string)->(string,bool) {
    stages,ok:=query(s.db,`SELECT stage_key FROM local_workflow_stage_expansions WHERE chain_id=?1 AND run_id=?2 AND execution=?3
      UNION SELECT COALESCE(i.stage_key,w.stage_key) FROM local_workflow_tasks w LEFT JOIN local_workflow_language_items i USING(task_id)
      WHERE w.chain_id=?1 AND w.run_id=?2 AND w.execution=?3 ORDER BY 1`,chain,run,execution)
    if !ok do return "",false
    parts:=make([dynamic]string,context.temp_allocator)
    for stage in stages {
        rows,read:=query(s.db,`SELECT COALESCE(o.output_json,'{}') FROM local_workflow_tasks w
          LEFT JOIN local_workflow_language_items i USING(task_id)
          JOIN lifecycle_state l ON l.chain_id=w.chain_id AND l.task_id=w.task_id
          LEFT JOIN local_workflow_outputs o ON o.chain_id=w.chain_id AND o.task_id=w.task_id AND o.attempt=l.attempt
          WHERE w.chain_id=? AND w.run_id=? AND w.execution=? AND COALESCE(i.stage_key,w.stage_key)=? AND l.state='done'
          ORDER BY COALESCE(i.stage_index,0),w.task_id`,chain,run,execution,stage[0])
        if !read do return "",false
        outputs:=make(json.Array,0,len(rows),context.temp_allocator)
        for row in rows {
            value,valid:=contracts.owner_content_document(row[0])
            if !valid do return "",false
            append(&outputs,value)
        }
        append(&parts,fmt.tprintf("%s:%s",encode(stage[0]),encode(outputs)))
    }
    return fmt.tprintf("%s%s%s","{",strings.join(parts[:],",",context.temp_allocator),"}"),true
}
