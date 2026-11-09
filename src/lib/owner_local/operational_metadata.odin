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
    // Membership binds the instance id and its agent, not one launch: the
    // instance token authenticates the live child, so a restart (new epoch,
    // run_count, token) stays a member. Leases still fence the exact child.
    members,read:=query(s.db,"SELECT enabled,agent_id FROM local_chain_member_versions WHERE chain_id=? AND instance_id=? ORDER BY accepted_seq DESC LIMIT 1",chain,child.instance)
    return read && len(members)==1 && members[0][0]=="1" && members[0][1]==child.agent_id
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
Registry_Member :: struct { agent_id,instance_id,role,enabled:string }

// The chain's members as its registry row names them (only ids and roles):
// the latest version of each instance, the bound coordinator first and then
// newest first (bounded), and the bound coordinator, which is the latest
// enabled coordinator member ("" when none).
registry_members :: proc(s:^Store,chain:string) -> (agent,instance,members:string,ok:bool) {
    rows,read:=query(s.db,fmt.tprintf(`SELECT m.agent_id,m.instance_id,m.role,m.enabled FROM local_chain_member_versions m WHERE m.chain_id=?
      AND m.accepted_seq=(SELECT max(accepted_seq) FROM local_chain_member_versions x WHERE x.chain_id=m.chain_id AND x.instance_id=m.instance_id)
      ORDER BY (m.enabled=1 AND m.role='coordinator') DESC,m.accepted_seq DESC LIMIT %d`,contracts.OWNER_REGISTRY_MEMBERS_MAX),chain)
    if !read do return "","","",false
    list:=make([]Registry_Member,len(rows),context.temp_allocator)
    for row,i in rows {
        list[i]={row[0],row[1],row[2],row[3]}
        if i==0 && row[2]=="coordinator" && row[3]=="1" { agent,instance=row[0],row[1] }
    }
    members=encode(list)
    return agent,instance,members,members!=""
}

// Adds the chain's members to a chain registry row (task_id ""), which then
// takes the registry_members shape and signing domain.
registry_add_members :: proc(s:^Store,registry:^json.Object,chain:string) -> bool {
    agent,instance,members,ok:=registry_members(s,chain)
    if !ok do return false
    registry["coordinator_agent_id"]=json.String(agent)
    registry["coordinator_instance_id"]=json.String(instance)
    registry["members_json"]=json.String(members)
    return true
}

// After a membership change: republish the chain registry row with the new
// members so the Hub listing names the bound coordinator. Titles are sealed
// and the row signed at delivery (registry.prepare), so no keyring or signer
// is needed in the membership transaction. A quarantined import publishes
// nothing until migration_activate, which carries the members itself.
registry_members_intent :: proc(tx:^Transaction,chain,principal,op:string,seq:i64) -> bool {
    s:=tx.store
    if migration_quarantined(s,chain) do return true
    agent,instance,members,ok:=registry_members(s,chain)
    if !ok do return false
    payload:=encode(doc(map[string]string{"task_id"="","metadata_revision"=fmt.tprintf("%d",seq),"coordinator_agent_id"=agent,"coordinator_instance_id"=instance,"members_json"=members}))
    return intent_enqueue(tx,Intent_Input{chain=chain,principal=principal,operation=op,seq=seq,kind="registry.prepare",destination="",fence="{}",payload=payload})
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
    tasks,ok:=query(s.db,"SELECT task_id FROM lifecycle_configs lc WHERE chain_id=? AND revision=(SELECT max(revision) FROM lifecycle_configs x WHERE x.chain_id=lc.chain_id AND x.task_id=lc.task_id) AND json_extract(config_json,\'$.directory_id\')=? UNION SELECT f.task_id FROM local_fleet f JOIN local_assignment_history h ON h.chain_id=f.chain_id AND h.task_id=f.task_id AND h.revision=f.configuration_revision WHERE f.chain_id=? AND json_extract(h.command_json,'$.method')='fleet.reserve' AND json_extract(json_extract(json_extract(h.payload_json,'$.reservation'),'$.configuration'),'$.directory_id')=?",chain,id,chain,id)
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

// Agent `task-chain create`: the ONE coordinator binding an agent may cause.
// Only on a chain whose genesis creator is this owner Bridge key, only as the
// chain's first membership, and only for a proven live child (member_set
// validation). General chain.member.set and grant.* stay human-only
// (agent_command_admit). Recorded and attributed like a member version.
bind_created_coordinator :: proc(s:^Store,chain:string,child:Child,requested_by:string,now:i64) -> Result {
    context.allocator=context.temp_allocator
    if s.db==nil || now<0 || !agent_child_valid(child) || !contracts.owner_field_valid(requested_by,"id") do return fail("invalid_scope")
    tx:Transaction
    if !transaction_begin(s,&tx) do return fail("storage_error")
    defer transaction_rollback(&tx)
    state,ok:=query(s.db,"SELECT commit_seq,clock_high_ms,recovery_state FROM runtime_database WHERE singleton=1")
    if !ok || len(state)!=1 do return fail("storage_error")
    rows,read:=query(s.db,"SELECT t.creator,t.creator_key,t.revision,g.genesis_json FROM task_chains t JOIN chain_genesis g USING(chain_id) WHERE t.chain_id=?",chain)
    if !read do return fail("storage_error")
    if len(rows)!=1 || rows[0][0]!=s.owner || rows[0][1]!=s.owner_key do return fail("invalid_scope")
    genesis,parsed:=contracts.owner_parse(rows[0][3],"genesis")
    if !parsed || field(genesis,"creator_id")!=s.owner || field(genesis,"creator_key_id")!=s.owner_key || field(genesis,"owner_bridge_id")!=s.owner || field(genesis,"owner_key_id")!=s.owner_key do return fail("invalid_scope")
    members,found:=query(s.db,"SELECT 1 FROM local_chain_member_versions WHERE chain_id=? LIMIT 1",chain)
    if !found do return fail("storage_error")
    if len(members)>0 do return fail("operation_conflict")
    if now<number(state[0][1]) {
        if !mark_clock_uncertain(&tx) do return fail("storage_error")
        return fail("clock_uncertain")
    }
    if state[0][2]!="ready" do return fail("clock_uncertain")
    if !work_chain_active(s,chain) do return fail("operation_conflict")
    seq,next:=number(state[0][0])+1,number(rows[0][2])+1
    op:=fmt.tprintf("bind_%s",chain)
    c:=doc(map[string]string{"chain_id"=chain,"task_id"="","method"="chain.member.set","principal_id"=requested_by,"operation_id"=op})
    p:=doc(map[string]string{"instance_id"=child.instance,"agent_id"=child.agent_id,"role"="coordinator","enabled"="1"})
    payload:=encode(p)
    if code:=member_set(s,c,p,child,seq);code!="ok" do return fail(code)
    if _,ok=query(s.db,"UPDATE task_chains SET revision=revision+1 WHERE chain_id=?",chain);!ok do return fail("storage_error")
    result:=encode(map[string]string{"chain_id"=chain,"task_id"="","operation_id"=op,"revision"=fmt.tprintf("%d",next),"instance_id"=child.instance})
    if _,ok=query(s.db,"INSERT INTO local_changes VALUES(?,?,?,?,?,?)",fmt.tprintf("%d",seq),chain,"chain.member.set","",fmt.tprintf("%d",next),op);!ok do return fail("storage_error")
    if !event_record(&tx,seq,now,chain,"","agent",requested_by,"chain.member.set",op,"",payload,encode(doc(map[string]string{"title"="","description"="","body"=""})),result) do return fail("storage_error")
    // The receipt anchors the registry republication in the outbox.
    if _,ok=query(s.db,"INSERT INTO command_receipts(principal_id,operation_id,chain_id,task_id,method,input_digest,digest_key_id,request_expires_ms,result_json,commit_seq,created_ms) VALUES(?,?,?,'',?,?,?,0,?,?,?)",
        requested_by,op,chain,"chain.member.set",contracts.owner_payload_digest(payload),s.owner_key,result,fmt.tprintf("%d",seq),fmt.tprintf("%d",now));!ok do return fail("storage_error")
    if !registry_members_intent(&tx,chain,requested_by,op,seq) do return fail("storage_error")
    if _,ok=query(s.db,"UPDATE runtime_database SET commit_seq=?,clock_high_ms=? WHERE singleton=1",fmt.tprintf("%d",seq),fmt.tprintf("%d",now));!ok do return fail("storage_error")
    if !transaction_commit(&tx) do return fail("storage_error")
    return Result{code="ok",body=result,seq=seq}
}
