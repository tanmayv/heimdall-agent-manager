#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import contracts "odin_test:contracts"

// Explicit future-dispatch policy. It never changes running child accounting.
// The execution device must separately admit its static slot/directory ledger.
remote_assignment_policy :: proc(s:^Store,c:json.Object)->bool {
    chain,task,agent:=field(c,"chain_id"),field(c,"task_id"),field(c,"agent_id")
    rows,ok:=query(s.db,"SELECT * FROM local_fleet_policy_current WHERE chain_id=? AND agent_id=?",chain,agent)
    if !ok || len(rows)!=1 do return false
    policy:=fleet_policy_document(rows[0])
    if policy.bridge_id!="" && policy.bridge_id!=field(c,"executor_bridge_id") do return false
    roles,valid:=contracts.owner_fleet_roles(policy.roles_json,false)
    worker:=false
    for role in roles do if role=="worker" do worker=true
    paused,p_ok:=contracts.owner_fleet_roles(policy.paused_roles_json,true)
    for role in paused do if role=="*" || role=="worker" do worker=false
    if !valid || !p_ok || !worker do return false
    provider,model,profile:=policy.provider,policy.model,policy.provider_profile
    models,m_ok:=contracts.owner_fleet_models(policy.bridge_models_json)
    if !m_ok do return false
    if override,found:=models[field(c,"executor_bridge_id")];found {
        provider=override.provider;model=override.model;profile=override.provider_profile
    }
    // Empty native policy fields leave resolution to the executor catalog;
    // the device command still authorizes every concrete selected value.
    if (provider!="" && provider!=field(c,"provider")) || (model!="" && model!=field(c,"model")) ||
       (profile!="" && profile!=field(c,"provider_profile")) {return false}
    counts,read:=query(s.db,`SELECT count(*) FROM local_fleet f JOIN local_assignment_history h
      ON h.chain_id=f.chain_id AND h.task_id=f.task_id AND h.revision=f.configuration_revision
      WHERE f.chain_id=? AND f.task_id!=? AND f.enabled=1 AND json_extract(h.child_json,'$.agent_id')=?`,chain,task,agent)
    return read && len(counts)==1 && number(counts[0][0])<policy.capacity
}

remote_assignment_directory_current :: proc(s:^Store,c:json.Object)->bool {
    rows,ok:=query(s.db,"SELECT enabled,body FROM local_chain_directory_versions WHERE chain_id=? AND directory_id=? ORDER BY accepted_seq DESC LIMIT 1",field(c,"chain_id"),field(c,"directory_id"))
    if !ok do return false
    if len(rows)==0 do return true
    v,parsed:=contracts.owner_content_document(rows[0][1]);d,obj:=v.(json.Object)
    return rows[0][0]=="1" && parsed && obj && field(d,"bridge_id")==field(c,"executor_bridge_id") && field(d,"path")==field(c,"directory_path")
}

// Full configuration is authorized by the signed device command. An executor
// signature attests the reserved identity/configuration, not a live local child.
// The remote key was separately checked against the paired directory at the
// exact pin already revalidated by execute under this same transaction.
remote_assignment_child :: proc(s:^Store,command,p:json.Object,reservation:string,key:contracts.Owner_Verified_Key,now:i64,seq:i64)->(Child,string) {
    document,parsed:=contracts.owner_parse(reservation,"remote_reservation")
    if !parsed do return {},"invalid_content"
    raw:=field(document,"configuration")
    c,valid:=contracts.owner_parse(raw,"remote_configuration")
    a,a_ok:=contracts.executor_parse(field(document,"attestation"),"enrollment")
    if !valid || !a_ok || !contracts.executor_enrollment_matches(a,raw,key,now) ||
       field(c,"account_id")!=s.account || field(c,"owner_bridge_id")!=s.owner ||
       field(c,"chain_id")!=field(command,"chain_id") || field(c,"task_id")!=field(command,"task_id") ||
       field(c,"instance_id")!=field(p,"instance_id") || field(c,"configuration_revision")!=field(p,"configuration_revision") ||
       field(p,"enabled")!="1" {return {},"invalid_scope"}
    if !remote_assignment_policy(s,c) do return {},"invalid_scope"
    chain,task:=field(c,"chain_id"),field(c,"task_id")
    child:=Child{field(c,"instance_id"),field(c,"launch_epoch"),field(c,"token_generation"),number(field(c,"run_count")),field(c,"agent_id")}
    if !member_authorized(s,chain,child) || !lifecycle_path_current(s,chain,task) do return {},"invalid_scope"
    // A signed remote enrollment cannot adopt an already active local identity
    // or replace unsettled physical effects. Exact recovery belongs to M3's
    // journal/reconciliation path, not assignment edits.
    live,read:=query(s.db,`SELECT 1 FROM local_leases WHERE retired_seq IS NULL AND (task_id=? OR instance_id=?)
      UNION ALL SELECT 1 FROM owner_execution_journal WHERE state!='retired' AND (task_id=? OR instance_id=?)
      UNION ALL SELECT 1 FROM local_assignment_history WHERE json_extract(command_json,'$.method')='fleet.edit'
        AND json_extract(child_json,'$.instance')=? LIMIT 1`,task,child.instance,task,child.instance,child.instance)
    if !read do return {},"storage_error"
    if len(live)>0 do return {},"operation_conflict"
    // Existing directory configuration is authoritative when present. A new
    // ID is explicitly scoped by this signed device configuration; executor
    // canonicalization and actual launchability still run before preparation.
    if !remote_assignment_directory_current(s,c) do return {},"invalid_scope"
    members,m_ok:=query(s.db,"SELECT 1 FROM local_member_chains WHERE instance_id=?",child.instance)
    if !m_ok do return {},"storage_error"
    if len(members)==0 {
        member:=doc(map[string]string{"instance_id"=child.instance,"agent_id"=child.agent_id,"role"="worker","enabled"="1"})
        if code:=member_set(s,command,member,child,seq);code!="ok" do return {},code
    }
    return child,"ok"
}

// Revalidate immutable accepted remote configuration before preparation or
// launch. Historical enrollment expiry is not a fresh-attestation requirement;
// current executor incarnation/policy and exact host receipt are checked again.
remote_assignment_prepare_matches :: proc(s:^Store,p:json.Object,payload:string,current_admission:=true)->bool {
    c,valid:=remote_assignment_configuration(payload)
    if !valid do return false
    for name in ([11]string{"account_id","owner_bridge_id","executor_bridge_id","chain_id","task_id","instance_id","launch_epoch","run_count","token_generation","configuration_revision","protocol_version"}) {
        if field(c,name)!=field(p,name) do return false
    }
    if !current_admission do return true
    for name in ([5]string{"executor_incarnation","policy_revision","slot_id","provider_profile","directory_key"}) {
        if field(c,name)!=field(p,name) do return false
    }
    return field(p,"purpose")=="work" && remote_assignment_policy(s,c) && remote_assignment_directory_current(s,c)
}

remote_assignment_key_matches :: proc(s:^Store,p:json.Object,key:contracts.Owner_Verified_Key)->bool {
    rows,ok:=query(s.db,"SELECT payload_json FROM local_assignment_history WHERE chain_id=? AND task_id=? AND revision=?",field(p,"chain_id"),field(p,"task_id"),field(p,"configuration_revision"))
    if !ok || len(rows)!=1 do return false
    c,valid:=remote_assignment_configuration(rows[0][0])
    return valid && key.kind=="bridge" && key.account_id==s.account && key.enrolled && !key.revoked &&
      key.principal_id==field(c,"executor_bridge_id") && key.key_id==field(c,"executor_key_id")
}

remote_assignment_configuration :: proc(snapshot:string)->(json.Object,bool) {
    saved,ok:=contracts.owner_parse(snapshot,"remote_assignment_snapshot")
    reservation,parsed:=contracts.owner_parse(field(saved,"reservation"),"remote_reservation")
    c,valid:=contracts.owner_parse(field(reservation,"configuration"),"remote_configuration")
    return c,ok && parsed && valid
}
