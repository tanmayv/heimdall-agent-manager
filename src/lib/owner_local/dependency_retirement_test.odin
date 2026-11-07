#+feature dynamic-literals
package owner_local
import "core:encoding/json"
import "core:testing"
import contracts "odin_test:contracts"

dependency_lifecycle_call :: proc(f:^Fixture,task,lease:string,child:Child,method,op,p,cap,rev:string)->Result {
 c,_:=contracts.owner_parse(lifecycle_raw(f,child,method,op,p,cap,rev),"lifecycle_command")
 c["task_id"]=json.String(task);c["lease_id"]=json.String(lease)
 sig,_:=test_sign(&f.owner_priv,"lifecycle_command",c);c["signature"]=json.String(sig)
 return execute_lifecycle(&f.store,encode(c),p,cap,child,f.owner,1000,Signer{&f.owner_priv,test_sign},Source_Proof{"",true})
}
dependency_claim :: proc(f:^Fixture,task,lease,op,revision:string)->Result {
 c,_:=contracts.owner_parse(lease_request(f,lease_child(),"lease.claim",op,lease,"",revision),"lease_command")
 c["task_id"]=json.String(task)
 sig,_:=test_sign(&f.owner_priv,"lease_command",c);c["signature"]=json.String(sig)
 return lease_invoke(f,encode(c),"",lease_child())
}
@(test)
dependency_signed_live_retirement_rollback_replay_restart_and_next_grant :: proc(t:^testing.T) {
 context.allocator=context.temp_allocator
 f:=fixture(t);defer destroy(f);lifecycle_seed(t,f);control_destination_seed(t,f)
 p:=encode(doc(map[string]string{"requirements_revision"="2","body_cipher"=cipher(f,`{"goal":"bounded","acceptance":["done"]}`)}))
 testing.expect_value(t,invoke(f,command(f,"requirements.edit","one","task",p,"4"),p).code,"ok")
 claimed:=dependency_claim(f,"task","source_lease","claim_source","5")
 testing.expect_value(t,claimed.code,"ok");cap:=result_cap(claimed)
 p=`{"prerequisite":"dest","enabled":"1"}`
 raw:=command(f,"dependency.edit","add_dep","task",p,"5")
 testing.expect(t,exec(f.store.db,"CREATE TRIGGER dep_fail BEFORE INSERT ON local_events WHEN NEW.kind='dependency.edit' BEGIN SELECT RAISE(ABORT,'failure');END"))
 testing.expect_value(t,invoke(f,raw,p).code,"storage_error")
 rows,ok:=query(f.store.db,"SELECT (SELECT count(*) FROM local_dependencies),(SELECT count(*) FROM local_dependency_retirements),(SELECT count(*) FROM local_leases WHERE retired_seq IS NULL)")
 testing.expect(t,ok && rows[0][0]=="0" && rows[0][1]=="0" && rows[0][2]=="1")
 testing.expect(t,exec(f.store.db,"DROP TRIGGER dep_fail"))
 testing.expect_value(t,invoke(f,raw,p).code,"ok")
 replay:=invoke(f,raw,p,4000000);testing.expect(t,replay.code=="ok" && replay.replay)
 attempt:=attempt_read_test(t,f,"1")
 testing.expect_value(t,attempt.outcome,"expired:dep_added")
 testing.expect_value(t,dependency_claim(f,"task","blocked","blocked_source","6").code,"operation_conflict")
 close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
 testing.expect_value(t,attempt_read_test(t,f,"1").outcome,"expired:dep_added")
 prereq:=dependency_claim(f,"dest","dest_lease","claim_dest","4")
 testing.expect_value(t,prereq.code,"ok");dest_cap:=result_cap(prereq)
 p=`{"requirements_revision":"1"}`
 testing.expect_value(t,dependency_lifecycle_call(f,"dest","dest_lease",lease_child(),"requirements.present","dest_present",p,dest_cap,"4").code,"ok")
 testing.expect_value(t,dependency_lifecycle_call(f,"dest","dest_lease",lease_child(),"requirements.ack","dest_ack",p,dest_cap,"4").code,"ok")
 p=`{"requirements_revision":"1","head":"","summary":"Prerequisite complete"}`
 testing.expect_value(t,dependency_lifecycle_call(f,"dest","dest_lease",lease_child(),"lease.submit","dest_submit",p,dest_cap,"4").code,"ok")
 p=`{"requirements_revision":"1","attempt":"1","head":"","verdict":"approve","summary":"Reviewed"}`
 review:=dependency_lifecycle_call(f,"dest","dest_lease",lifecycle_reviewer(),"review.open","dest_review_open",p,"","5")
 testing.expect_value(t,review.code,"ok")
 testing.expect_value(t,dependency_lifecycle_call(f,"dest","dest_lease",lifecycle_reviewer(),"review.post","dest_review",p,result_cap(review),"5").code,"ok")
 testing.expect(t,dependency_ready(&f.store,"chain","task"))
 heartbeat:=lease_request(f,lease_child(),"lease.heartbeat","stale","source_lease",cap,"6")
 testing.expect_value(t,lease_invoke(f,heartbeat,cap,lease_child()).code,"invalid_scope")
 testing.expect_value(t,dependency_claim(f,"task","source_next","resume_source","6").code,"ok")
 rows,ok=query(f.store.db,"SELECT (SELECT count(*) FROM local_dependency_retirements),(SELECT count(*) FROM control_notices WHERE operation_id='add_dep'),(SELECT count(*) FROM local_work_attempts WHERE task_id='task')")
 testing.expect(t,ok && rows[0][0]=="1" && rows[0][1]=="1" && rows[0][2]=="2")
}
