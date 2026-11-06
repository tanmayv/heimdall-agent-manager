#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import contracts "odin_test:contracts"

// Existing explicit enrollments remain valid until operational membership is
// configured. Once configured, only the enabled exact launch may exercise it.
member_authorized :: proc(s:^Store,chain:string,child:Child) -> bool {
    rows,ok:=query(s.db,"SELECT chain_id FROM local_member_chains WHERE instance_id=?",child.instance)
    if !ok do return false
    if len(rows)==0 do return true
    if rows[0][0]!=chain do return false
    members,read:=query(s.db,"SELECT enabled,child_json FROM local_chain_member_versions WHERE chain_id=? AND instance_id=? ORDER BY accepted_seq DESC LIMIT 1",chain,child.instance)
    return read && len(members)==1 && members[0][0]=="1" && members[0][1]==encode(child)
}
// Config evidence is immutable. A changed directory or removed participant
// requires fresh fleet/lifecycle enrollment instead of reviving stale paths.
metadata_revoke_task :: proc(s:^Store,c:json.Object,task:string,seq:i64) -> bool {
    bound:=doc(map[string]string{})
    for k,v in c do bound[k]=v
    bound["task_id"]=json.String(task)
    chain:=field(c,"chain_id")
    if _,ok:=query(s.db,"INSERT INTO local_metadata_retirements SELECT ?,?,?,COALESCE((SELECT lease_id FROM local_leases WHERE chain_id=? AND task_id=? AND retired_seq IS NULL),\'\'),?",fmt.tprintf("%d",seq),chain,task,chain,task,field(c,"method"));!ok do return false
    if !control_revoke(s,bound,seq,"checkpoint") do return false
    if _,ok:=query(s.db,"INSERT OR IGNORE INTO local_config_revocations SELECT chain_id,task_id,revision,? FROM lifecycle_configs WHERE chain_id=? AND task_id=?",fmt.tprintf("%d",seq),chain,task);!ok do return false
    if _,ok:=query(s.db,"DELETE FROM local_checkpoints WHERE chain_id=? AND task_id=?",chain,task);!ok do return false
    if _,ok:=query(s.db,"UPDATE local_fleet SET enabled=0,configuration_revision=configuration_revision+1 WHERE chain_id=? AND task_id=? AND enabled=1",chain,task);!ok do return false
    if _,ok:=query(s.db,"UPDATE lifecycle_state SET state='ready' WHERE chain_id=? AND task_id=? AND state!='done'",chain,task);!ok do return false
    if _,ok:=query(s.db,"UPDATE tasks SET revision=revision+1 WHERE chain_id=? AND task_id=?",chain,task);!ok do return false
    return true
}
member_set :: proc(s:^Store,c,p:json.Object,observed:Child,seq:i64) -> string {
    child:=observed
    chain,instance,agent:=field(c,"chain_id"),field(p,"instance_id"),field(p,"agent_id")
    enabled:=field(p,"enabled")=="1"
    lifetime,ok:=query(s.db,"SELECT chain_id FROM local_member_chains WHERE instance_id=?",instance)
    if !ok do return "storage_error"
    if len(lifetime)>0 && lifetime[0][0]!=chain do return "invalid_scope"
    prior,read:=query(s.db,"SELECT agent_id,role,enabled,child_json FROM local_chain_member_versions WHERE chain_id=? AND instance_id=? ORDER BY accepted_seq DESC LIMIT 1",chain,instance)
    if !read do return "storage_error"
    if len(prior)>0 && prior[0][0]!=agent do return "invalid_scope"
    if enabled {
        if child.instance!=instance || child.agent_id!=agent || child.epoch=="" || child.run_count<1 || !contracts.owner_field_valid(child.token_generation,"hash") do return "invalid_scope"
    } else {
        if len(prior)!=1 || prior[0][2]!="1" do return "operation_conflict"
        if json.unmarshal_string(prior[0][3],&child,.JSON,context.temp_allocator)!=nil do return "storage_error"
    }
    if len(prior)==1 && prior[0][2]=="1" && prior[0][1]=="coordinator" && (!enabled || field(p,"role")!="coordinator") {
        peers,found:=query(s.db,"SELECT count(*) FROM local_chain_member_versions m WHERE chain_id=? AND enabled=1 AND role='coordinator' AND accepted_seq=(SELECT max(accepted_seq) FROM local_chain_member_versions x WHERE x.chain_id=m.chain_id AND x.instance_id=m.instance_id)",chain)
        if !found do return "storage_error"
        if number(peers[0][0])<=1 do return "operation_conflict"
    }
    changed:=len(prior)==1 && prior[0][2]=="1" && (!enabled || prior[0][3]!=encode(child))
    if changed {
        tasks,found:=query(s.db,"SELECT task_id FROM local_fleet WHERE chain_id=?1 AND instance_id=?2 UNION SELECT task_id FROM lifecycle_configs lc WHERE chain_id=?1 AND revision=(SELECT max(revision) FROM lifecycle_configs x WHERE x.chain_id=lc.chain_id AND x.task_id=lc.task_id) AND (json_extract(author_child,'$.instance')=?2 OR json_extract(reviewer_child,'$.instance')=?2) UNION SELECT task_id FROM local_role_pairs rp WHERE chain_id=?1 AND revision=(SELECT max(revision) FROM local_role_configs x WHERE x.chain_id=rp.chain_id AND x.task_id=rp.task_id) AND json_extract(child_json,'$.instance')=?2 UNION SELECT task_id FROM local_leases WHERE chain_id=?1 AND instance_id=?2 AND retired_seq IS NULL",chain,instance)
        if !found do return "storage_error"
        for row in tasks { if !metadata_revoke_task(s,c,row[0],seq) do return "storage_error" }
        if _,ok=query(s.db,"INSERT OR IGNORE INTO local_coordinator_revocations SELECT chain_id,revision,? FROM local_workflow_coordinators WHERE chain_id=? AND json_extract(child_json,'$.instance')=?",fmt.tprintf("%d",seq),chain,instance);!ok do return "storage_error"

    }
    if _,ok=query(s.db,"INSERT OR IGNORE INTO local_member_chains VALUES(?,?)",instance,chain);!ok do return "storage_error"
    if _,ok=query(s.db,"INSERT INTO local_chain_member_versions VALUES(?,?,?,?,?,?,?)",chain,instance,fmt.tprintf("%d",seq),agent,field(p,"role"),field(p,"enabled"),encode(child));!ok do return "storage_error"
    return "ok"
}
directory_set :: proc(s:^Store,c,p:json.Object,body:string,seq:i64) -> string {
    chain,id:=field(c,"chain_id"),field(p,"directory_id")
    value,parsed:=contracts.owner_content_document(body)
    row,obj:=value.(json.Object)
    if !parsed || !obj || !contracts.owner_metadata_record_valid(row,"directory") || field(row,"chain_id")!=chain || field(row,"directory_id")!=id || field(row,"owner_user_id")!=s.account || field(row,"bridge_id")!=s.owner do return "invalid_content"
    conflicts,checked:=query(s.db,"SELECT 1 FROM local_chain_directory_versions WHERE directory_id=? AND chain_id!=? LIMIT 1",id,chain)
    if !checked do return "storage_error"
    if len(conflicts)>0 do return "invalid_scope"
    previous,read:=query(s.db,"SELECT enabled,body FROM local_chain_directory_versions WHERE chain_id=? AND directory_id=? ORDER BY accepted_seq DESC LIMIT 1",chain,id)
    if !read do return "storage_error"
    if field(p,"enabled")=="0" && (len(previous)!=1 || previous[0][0]!="1") do return "operation_conflict"
    // Directory IDs bind the exact lifecycle configuration. Unrelated task
    // paths remain valid; a replacement requires explicit Git activation.
    tasks,ok:=query(s.db,"SELECT task_id FROM lifecycle_configs lc WHERE chain_id=? AND revision=(SELECT max(revision) FROM lifecycle_configs x WHERE x.chain_id=lc.chain_id AND x.task_id=lc.task_id) AND json_extract(config_json,\'$.directory_id\')=?",chain,id)
    if !ok do return "storage_error"
    for task in tasks { if !metadata_revoke_task(s,c,task[0],seq) do return "storage_error" }
    if _,ok=query(s.db,"INSERT INTO local_chain_directory_versions VALUES(?,?,?,?,?)",chain,id,fmt.tprintf("%d",seq),field(p,"enabled"),body);!ok do return "storage_error"
    return "ok"
}


// Configuration is not Git activation: a configured directory constrains the
// separate lifecycle proof; source imports never enter this check.
directory_config_authorized :: proc(s:^Store,chain:string,p:json.Object) -> bool {
    rows,ok:=query(s.db,"SELECT enabled,body FROM local_chain_directory_versions WHERE chain_id=? AND directory_id=? ORDER BY accepted_seq DESC LIMIT 1",chain,field(p,"directory_id"))
    if !ok do return false
    if len(rows)==0 do return true
    if rows[0][0]!="1" do return false
    v,valid:=contracts.owner_content_document(rows[0][1]);d,obj:=v.(json.Object)
    if !valid || !obj do return false
    return field(p,"merge_policy")=="none" || field(p,"repository")==field(d,"path")
}
