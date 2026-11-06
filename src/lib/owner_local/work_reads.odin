#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"

work_read :: proc(s:^Store,chain:string,p:json.Object)->Result {
    header,ok:=query(s.db,"SELECT publish_state,status,work_revision FROM local_work_chains WHERE chain_id=?",chain)
    if !ok || len(header)!=1 do return fail("storage_error")
    scope:=payload_hash(encode([4]string{s.account,chain,"work.v1",header[0][2]}))
    offset:i64
    if cursor:=field(p,"cursor");cursor!="" {
        parts:=strings.split(cursor,":",context.temp_allocator)
        if len(parts)!=2 || parts[0]!=scope do return fail("stale_cursor")
        offset=number(parts[1])
        if offset<0 || fmt.tprintf("%d",offset)!=parts[1] do return fail("malformed")
    }
    limit:=min(number(field(p,"limit")),3)
    if limit<1 || number(field(p,"limit"))>100 do return fail("malformed")
    rows,read:=query(s.db,`SELECT kind,key,seq,body FROM (
      SELECT 'proposal' kind,proposal_id key,accepted_seq seq,json_object('proposal_id',proposal_id,'proposal_json',proposal_json,'created_at',created_at,'actor_kind',actor_kind,'actor_id',actor_id) body FROM local_work_proposals WHERE chain_id=?1
      UNION ALL SELECT 'decision',proposal_id,accepted_seq,json_object('proposal_id',proposal_id,'decision',decision,'note',note,'result_json',result_json,'decided_at',decided_at,'actor_kind',actor_kind,'actor_id',actor_id) FROM local_work_decisions WHERE chain_id=?1
      UNION ALL SELECT 'dependency',d.dependency_id,d.accepted_seq,json_object('dependency_id',d.dependency_id,'chain_id',d.chain_id,'owner_user_id',?2,'dependent',json_object('kind',dependent_kind,'id',dependent_id),'prerequisite',json_object('kind',prerequisite_kind,'id',prerequisite_id),'created_by_kind',created_by_kind,'created_by_id',created_by_id,'created_at',created_at,'removed_at',COALESCE(r.removed_at,''),'removed_by_kind',COALESCE(r.removed_by_kind,''),'removed_by_id',COALESCE(r.removed_by_id,''),'removal_reason',COALESCE(r.reason,'')) FROM local_work_dependencies d LEFT JOIN local_work_dependency_removals r USING(chain_id,dependency_id) WHERE d.chain_id=?1
      UNION ALL SELECT 'receipt',receipt_id,accepted_seq,json_object('receipt_id',receipt_id,'chain_id',chain_id,'owner_user_id',?2,'dependent',json_object('kind',dependent_kind,'id',dependent_id),'dependent_generation',dependent_generation,'prerequisite',json_object('kind',prerequisite_kind,'id',prerequisite_id),'prerequisite_generation',prerequisite_generation,'output_manifest_json',output_manifest_json,'created_at',created_at) FROM local_work_inputs WHERE chain_id=?1
      UNION ALL SELECT 'scope',CAST(decision_id AS TEXT),accepted_seq,json_object('decision_id',decision_id,'chain_id',chain_id,'owner_user_id',?2,'item',json_object('kind',item_kind,'id',item_id),'action',action,'reason',reason,'actor_kind',actor_kind,'actor_id',actor_id,'created_at',created_at) FROM local_work_scope WHERE chain_id=?1
      UNION ALL SELECT 'completion',chain_id,accepted_seq,json_object('chain_id',chain_id,'work_revision',work_revision,'summary',summary,'completed_at',completed_at,'actor_kind',actor_kind,'actor_id',actor_id) FROM local_work_completions WHERE chain_id=?1
      UNION ALL SELECT 'workflow_draft',run_id,accepted_seq,json_object('run_id',run_id,'run_json',run_json,'created_at',created_at,'actor_kind',actor_kind,'actor_id',actor_id) FROM local_work_pending_runs WHERE chain_id=?1
      UNION ALL SELECT 'workflow_draft_cancelled',run_id,accepted_seq,json_object('run_id',run_id,'execution_no',1,'reason',reason) FROM local_work_run_cancellations WHERE chain_id=?1
      UNION ALL SELECT 'task_publication',task_id,accepted_seq,json_object('task_id',task_id,'publish_state',publish_state) FROM local_task_publications WHERE chain_id=?1
      ) ORDER BY seq,kind,key LIMIT ?3 OFFSET ?4`,chain,s.account,fmt.tprintf("%d",limit+1),fmt.tprintf("%d",offset))
    if !read do return fail("storage_error")
    items:=make(json.Array,0,3,context.temp_allocator)
    next:=""
    if len(rows)>int(limit) do next=fmt.tprintf("%s:%d",scope,offset+limit)
    for row in rows[:min(len(rows),int(limit))] {
        v,valid:=contracts.owner_content_document(row[3])
        if !valid do return fail("storage_error")
        item:=doc(map[string]string{"kind"=row[0],"key"=row[1],"accepted_seq"=row[2]})
        item["record"]=v;append(&items,item)
    }
    pending,id,valid:=work_pending(s,chain)
    if !valid do return fail("storage_error")
    result:=doc(map[string]string{"chain_id"=chain,"publish_state"=header[0][0],"status"=header[0][1],"work_revision"=header[0][2],"pending_proposal_id"=id,"next_cursor"=next})
    result["items"]=items
    if pending!=nil {result["pending_proposal"]=pending} else {result["pending_proposal"]=nil}
    raw:=encode(result)
    if len(raw)>MAX_PAGE do return fail("invalid_content")
    return Result{code="ok",body=raw}
}
