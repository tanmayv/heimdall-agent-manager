#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"

member_call :: proc(f:^Fixture,child:Child,role,enabled,op:string,revision:string="") -> Result {
    p:=encode(doc(map[string]string{"instance_id"=child.instance,"agent_id"=child.agent_id,"role"=role,"enabled"=enabled}))
    c:=command(f,"chain.member.set",op,"",p,summary_revision(f) if revision=="" else revision)
    return execute(&f.store,c,p,"",f.creator,f.owner,1,"head",1000,&f.kr,Signer{&f.owner_priv,test_sign},child)
}
metadata_replay :: proc(f:^Fixture,op:string) -> Result {
    rows,ok:=query(f.store.db,"SELECT evidence_json FROM local_events WHERE operation_id=?",op)
    if !ok || len(rows)!=1 do return fail("storage_error")
    v,valid:=contracts.owner_content_document(rows[0][0]);o,obj:=v.(json.Object)
    if !valid || !obj do return fail("storage_error")
    return invoke(f,field(o,"command"),field(o,"payload"))
}
directory_body :: proc(path:string) -> string {
    return encode(doc(map[string]string{"directory_id"="directory","chain_id"="chain","owner_user_id"="account","path"=path,"bridge_id"="bridge","vcs_kind"="git","vcs_info_json"="{}","created_at"="original","updated_at"="now"}))
}
directory_call :: proc(f:^Fixture,path,enabled,op:string,revision:string="") -> Result {
    p:=encode(doc(map[string]string{"directory_id"="directory","enabled"=enabled,"body_cipher"=cipher(f,directory_body(path))}))
    return invoke(f,command(f,"chain.directory.set",op,"",p,summary_revision(f) if revision=="" else revision),p)
}
metadata_state :: proc(f:^Fixture) -> string {
    tables:=[13]string{"local_metadata_retirements","local_chain_member_versions","local_member_chains","local_chain_directory_versions","local_config_revocations","local_coordinator_revocations","local_fleet","local_leases","local_checkpoints","local_review_sessions","intent_invalidations","control_notices","tasks"}
    parts:=make([dynamic]string,context.temp_allocator)
    for table in tables {
        rows,_:=query(f.store.db,fmt.tprintf("SELECT * FROM %s ORDER BY rowid",table))
        append(&parts,encode(rows))
    }
    return fmt.tprintf("%s%s",native_metadata_test_state(f),encode(parts))
}
@(test)
member_cas_history_exact_child_removal_restart_and_last_coordinator :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    cap:=lifecycle_ready(t,f)
    if cap=="" do return
    child:=lease_child()
    old:=summary_revision(f)
    testing.expect_value(t,member_call(f,child,"worker","1","join",old).code,"ok")
    testing.expect(t,metadata_replay(f,"join").replay)
    testing.expect_value(t,member_call(f,child,"worker","0","stale",old).code,"stale_revision")
    forged:=child;forged.agent_id="imposter"
    testing.expect_value(t,member_call(f,forged,"worker","1","forged").code,"invalid_scope")
    testing.expect_value(t,member_call(f,child,"worker","0","remove").code,"ok")
    testing.expect(t,!member_authorized(&f.store,"chain",child))
    notices,_:=query(f.store.db,"SELECT json_extract(payload_json,\'$.task_id\') FROM runtime_intents WHERE kind=\'checkpoint\' AND operation_id=\'remove\'")
    testing.expect(t,len(notices)>0 && notices[0][0]=="task")
    testing.expect_value(t,lifecycle_call(f,child,"requirements.present","removed_present",`{"requirements_revision":"1"}`,cap).code,"invalid_scope")
    rows,_:=query(f.store.db,"SELECT enabled,(SELECT count(*) FROM local_leases WHERE retired_seq IS NULL),(SELECT count(*) FROM local_config_revocations) FROM local_fleet")
    testing.expect_value(t,encode(rows),encode([1][3]string{{"0","0","1"}}))
    view,record,_,scanned:=attempt_scan(&f.store,"chain","task",1)
    testing.expect(t,scanned && !view.incomplete && !view.live)
    testing.expect(t,record.outcome=="expired:replaced" && record.ended_ms=="1000" && record.completeness=="full")
    testing.expect_value(t,member_call(f,child,"worker","1","rejoin").code,"ok")
    testing.expect_value(t,lifecycle_call(f,child,"requirements.present","rejoin_old_cap",`{"requirements_revision":"1"}`,cap).code,"invalid_scope")
    testing.expect_value(t,member_call(f,child,"coordinator","1","promote").code,"ok")
    testing.expect_value(t,member_call(f,child,"worker","0","sole_remove").code,"operation_conflict")
    testing.expect_value(t,member_call(f,child,"worker","1","sole_demote").code,"operation_conflict")
    second:=lifecycle_reviewer()
    testing.expect_value(t,member_call(f,second,"coordinator","1","second").code,"ok")
    testing.expect_value(t,member_call(f,child,"worker","0","remove_coordinator").code,"ok")
    testing.expect(t,!exec(f.store.db,"UPDATE local_chain_member_versions SET role='worker'"))
    testing.expect(t,!exec(f.store.db,"DELETE FROM local_member_chains"))
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect(t,!member_authorized(&f.store,"chain",child))
    got:=context_call(f,"chain.metadata.read","members_read","")
    testing.expect(t,got.code=="ok" && strings.contains(got.body,"member") && strings.contains(got.body,"current"))
    rows,_=query(f.store.db,"PRAGMA foreign_key_check")
    testing.expect_value(t,len(rows),0)
}
@(test)
directory_signed_history_unicode_restart_and_path_authority_invalidation :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    cap:=lifecycle_ready(t,f)
    if cap=="" do return
    old:=summary_revision(f)
    testing.expect_value(t,directory_call(f,"/repo/界","1","directory_add",old).code,"ok")
    testing.expect(t,metadata_replay(f,"directory_add").replay)
    testing.expect_value(t,directory_call(f,"/repo/new","1","directory_stale",old).code,"stale_revision")
    _,_,configured:=lifecycle_config(&f.store,"chain","task")
    testing.expect(t,!configured)
    testing.expect_value(t,lifecycle_call(f,lease_child(),"requirements.present","old_path",`{"requirements_revision":"1"}`,cap).code,"invalid_scope")
    rows,_:=query(f.store.db,"SELECT count(*) FROM local_leases WHERE retired_seq IS NULL")
    testing.expect_value(t,rows[0][0],"0")
    view,record,_,scanned:=attempt_scan(&f.store,"chain","task",1)
    testing.expect(t,scanned && !view.incomplete && !view.live && record.outcome=="expired:replaced" && record.completeness=="full")
    testing.expect_value(t,directory_call(f,"/repo/new","1","directory_update").code,"ok")
    testing.expect_value(t,directory_call(f,"/repo/new","0","directory_remove").code,"ok")
    rows,_=query(f.store.db,"SELECT enabled,body FROM local_chain_directory_versions ORDER BY accepted_seq")
    testing.expect(t,len(rows)==3 && rows[2][0]=="0")
    if len(rows)==3 { v,_:=contracts.owner_content_document(rows[0][1]);o,_:=v.(json.Object);testing.expect_value(t,field(o,"path"),"/repo/界") }
    testing.expect(t,!exec(f.store.db,"DELETE FROM local_chain_directory_versions"))
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    got:=context_call(f,"chain.metadata.read","directories_read","")
    testing.expect(t,got.code=="ok" && strings.contains(got.body,"directory"))
}
@(test)
operational_metadata_statement_and_deferred_commit_rollback :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    for kind in ([2]string{"member","directory"}) {
        f:=fixture(t);lifecycle_seed(t,f)
        cap:=lifecycle_ready(t,f)
        if cap=="" {destroy(f);continue}
        child:=lease_child()
        testing.expect_value(t,member_call(f,child,"worker","1","rollback_join").code,"ok")
        state:=metadata_state(f)
        testing.expect(t,exec(f.store.db,fmt.tprintf("CREATE TRIGGER metadata_fail BEFORE INSERT ON local_events WHEN NEW.kind='chain.%s.set' BEGIN SELECT RAISE(ABORT,'fixture'); END",kind)))
        failed:=member_call(f,child,"worker","0","member_statement") if kind=="member" else directory_call(f,"/new","1","directory_statement")
        testing.expect_value(t,failed.code,"storage_error")
        testing.expect_value(t,metadata_state(f),state)
        testing.expect(t,exec(f.store.db,"DROP TRIGGER metadata_fail; CREATE TABLE metadata_parent(id INTEGER PRIMARY KEY); CREATE TABLE metadata_ref(id INTEGER REFERENCES metadata_parent(id) DEFERRABLE INITIALLY DEFERRED)"))
        table:="local_chain_member_versions" if kind=="member" else "local_chain_directory_versions"
        testing.expect(t,exec(f.store.db,fmt.tprintf("CREATE TRIGGER metadata_fail AFTER INSERT ON %s BEGIN INSERT INTO metadata_ref VALUES(1); END",table)))
        failed=member_call(f,child,"worker","0","member_commit") if kind=="member" else directory_call(f,"/new","1","directory_commit")
        testing.expect_value(t,failed.code,"storage_error")
        testing.expect_value(t,metadata_state(f),state)
        testing.expect_value(t,lifecycle_call(f,child,"requirements.present","rollback_still_live",`{"requirements_revision":"1"}`,cap).code,"ok")
        destroy(f)
    }
}

@(test)
member_removal_revokes_separately_enrolled_coordinator_without_revival_on_rejoin :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);seed(t,f)
    child:=lease_child()
    testing.expect_value(t,member_call(f,child,"worker","1","coord_member").code,"ok")
    bound:=coordinator_test_config(f,child,"1","separate_coord")
    if !testing.expect_value(t,bound.code,"ok") do return
    testing.expect_value(t,member_call(f,child,"worker","0","remove_coord_worker").code,"ok")
    testing.expect_value(t,member_call(f,child,"worker","1","rejoin_coord_worker").code,"ok")
    testing.expect(t,member_authorized(&f.store,"chain",child))
    testing.expect(t,!member_authorized(&f.store,"other_chain",child))
    rows,_:=query(f.store.db,"SELECT revision FROM local_coordinator_revocations")
    testing.expect_value(t,encode(rows),encode([1][1]string{{"1"}}))
    body:=`{"run_id":"run","execution":"1","stage_key":"gate","verdict":"approve","summary":"Old enrollment"}`
    raw:=coordinator_test_raw(f,"task","old_coordinator",body,result_cap(bound),child)
    testing.expect_value(t,execute_coordinator_gate(&f.store,raw,body,result_cap(bound),child,f.owner,1000,Signer{&f.owner_priv,test_sign}).code,"invalid_scope")
    testing.expect_value(t,coordinator_test_config(f,child,"2","fresh_coord").code,"ok")
}
@(test)
directory_unrelated_binding_survives_and_revoked_lifecycle_cannot_fall_back_to_generic_claim :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    cap:=lifecycle_ready(t,f)
    if cap=="" do return
    v,_:=contracts.owner_content_document(directory_body("/other"));d,_:=v.(json.Object)
    d["directory_id"]=json.String("other_directory")
    p:=encode(doc(map[string]string{"directory_id"="other_directory","enabled"="1","body_cipher"=cipher(f,encode(d))}))
    testing.expect_value(t,invoke(f,command(f,"chain.directory.set","unrelated_directory","",p,summary_revision(f)),p).code,"ok")
    testing.expect_value(t,lifecycle_call(f,lease_child(),"requirements.present","unrelated_still_live",`{"requirements_revision":"1"}`,cap).code,"ok")
    testing.expect_value(t,directory_call(f,"/repo","1","revoke_target_directory").code,"ok")
    child:=lease_child()
    p=encode(doc(map[string]string{"instance_id"=child.instance,"configuration_revision"="3","enabled"="1"}))
    testing.expect_value(t,execute(&f.store,command(f,"fleet.edit","path_reenroll","task",p,"5"),p,"",f.creator,f.owner,1,"head",1000,&f.kr,Signer{&f.owner_priv,test_sign},child).code,"ok")
    raw:=lease_request(f,child,"lease.claim","generic_bypass","new_lease","","6")
    c,_:=contracts.owner_parse(raw,"lease_command");c["configuration_revision"]=json.String("3")
    sig,_:=test_sign(&f.owner_priv,"lease_command",c);c["signature"]=json.String(sig)
    testing.expect_value(t,lease_invoke(f,encode(c),"",child).code,"invalid_scope")
    configs,_:=query(f.store.db,"SELECT config_json FROM lifecycle_configs WHERE chain_id='chain' AND task_id='task' ORDER BY revision DESC LIMIT 1")
    config,_:=contracts.owner_parse(configs[0][0],"lifecycle_config_payload")
    config["directory_id"]=json.String("other_directory");config["configuration_revision"]=json.String("3")
    payload:=encode(config)
    testing.expect_value(t,execute(&f.store,command(f,"lifecycle.configure","move_directory","task",payload,"6"),payload,"",f.creator,f.owner,1,"head",1000,&f.kr,Signer{&f.owner_priv,test_sign},{},Lifecycle_Proof{child,lifecycle_reviewer(),true}).code,"ok")
    c["expected_revision"]=json.String("7");c["operation_id"]=json.String("new_directory_claim")
    sig,_=test_sign(&f.owner_priv,"lease_command",c);c["signature"]=json.String(sig)
    testing.expect_value(t,lease_invoke(f,encode(c),"",child).code,"ok")
    testing.expect_value(t,directory_call(f,"/old-directory-updated","1","old_directory_change").code,"ok")
    testing.expect(t,lifecycle_path_current(&f.store,"chain","task"))
    active,_:=query(f.store.db,"SELECT count(*) FROM local_leases WHERE retired_seq IS NULL")
    testing.expect_value(t,active[0][0],"1")
}
