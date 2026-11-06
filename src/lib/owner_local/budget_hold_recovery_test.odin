#+feature dynamic-literals
package owner_local
import "core:testing"
import "core:fmt"

@(test)
independent_released_hold_does_not_return_after_budget_increase :: proc(t:^testing.T) {
 context.allocator=context.temp_allocator
 f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
 p:=encode(doc(map[string]string{"requirements_revision"="2","body_cipher"=cipher(f,`{"goal":"bounded","acceptance":["done"],"budget":{"max_attempts":1}}`)}))
 testing.expect_value(t,invoke(f,command(f,"requirements.edit","one","task",p,"4"),p).code,"ok")
 testing.expect_value(t,dependency_claim(f,"task","lease","claim","5").code,"ok")
 testing.expect_value(t,control_call(f,"task.hold","hold_before_expiry","5").code,"ok")
 testing.expect(t,expire_leases(&f.store,902000))
 testing.expect_value(t,review_human_at(f,"task.release","release","6",902000).code,"ok")
 p=encode(doc(map[string]string{"requirements_revision"="3","body_cipher"=cipher(f,`{"goal":"raised","acceptance":["done"],"budget":{"max_attempts":2}}`)}))
 testing.expect_value(t,invoke(f,command(f,"requirements.edit","raise","task",p,"7",904000),p,902000).code,"ok")
 budget_expect_test(t,f,1,1,"")
 testing.expect(t,!control_held(&f.store,"chain","task"),"released hold must not be resurrected")
 testing.expect_value(t,lease_invoke(f,lease_request(f,lease_child(),"lease.claim","next","next_lease","","8",904000),"",lease_child(),902000).code,"ok")
}

@(test)
budget_released_hold_restart_replay_and_transaction_rollback :: proc(t:^testing.T) {
 context.allocator=context.temp_allocator
 for stage in ([2]string{"release","raise"}) {
  for deferred in ([2]bool{false,true}) {
   f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
   p:=encode(doc(map[string]string{"requirements_revision"="2","body_cipher"=cipher(f,`{"goal":"bounded","acceptance":["done"],"budget":{"max_attempts":1}}`)}))
   testing.expect_value(t,invoke(f,command(f,"requirements.edit","one","task",p,"4"),p).code,"ok")
   testing.expect_value(t,dependency_claim(f,"task","lease","claim","5").code,"ok")
   testing.expect_value(t,control_call(f,"task.hold","hold_before_expiry","5").code,"ok")
   testing.expect(t,expire_leases(&f.store,902000))
   close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
   p=encode(doc(map[string]string{"body_cipher"=cipher(f,"Explicitly release hold")}))
   release:=command(f,"task.release","release","task",p,"6",904000)
   method,raw,payload:="task.release",release,p
   if stage=="raise" {
    testing.expect_value(t,invoke(f,release,p,902000).code,"ok")
    replay:=invoke(f,release,p,902000);testing.expect(t,replay.code=="ok" && replay.replay)
    payload=encode(doc(map[string]string{"requirements_revision"="3","body_cipher"=cipher(f,`{"goal":"raised","acceptance":["done"],"budget":{"max_attempts":2}}`)}))
    method="requirements.edit";raw=command(f,method,"raise","task",payload,"7",904000)
   }
   snapshot_sql:=`SELECT (SELECT prior_json FROM budget_control_owners),(SELECT mode||':'||resume_state||':'||reason||':'||waiting_on FROM local_controls),(SELECT revision FROM tasks WHERE task_id='task'),(SELECT count(*) FROM local_events),(SELECT count(*) FROM command_receipts),(SELECT count(*) FROM local_checkpoints),(SELECT count(*) FROM runtime_intents)`
   before,read:=query(f.store.db,snapshot_sql);testing.expect(t,read)
   if deferred {
    testing.expect(t,exec(f.store.db,`CREATE TABLE hold_parent(id INTEGER PRIMARY KEY);CREATE TABLE hold_ref(id INTEGER REFERENCES hold_parent(id) DEFERRABLE INITIALLY DEFERRED);`))
    testing.expect(t,exec(f.store.db,fmt.tprintf("CREATE TRIGGER hold_fail AFTER INSERT ON local_events WHEN NEW.kind='%s' BEGIN INSERT INTO hold_ref VALUES(1);END;",method)))
   } else {
    testing.expect(t,exec(f.store.db,fmt.tprintf("CREATE TRIGGER hold_fail BEFORE INSERT ON local_events WHEN NEW.kind='%s' BEGIN SELECT RAISE(ABORT,'failure');END;",method)))
   }
   testing.expect_value(t,invoke(f,raw,payload,902000).code,"storage_error")
   after,checked:=query(f.store.db,snapshot_sql)
   testing.expect(t,checked && encode(before)==encode(after),"failed signed transition rolls back underlying ownership, controls, revision, events, receipts and intents")
   testing.expect(t,exec(f.store.db,"DROP TRIGGER hold_fail"))
   close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
   testing.expect_value(t,invoke(f,raw,payload,902000).code,"ok")
   replay:=invoke(f,raw,payload,902000);testing.expect(t,replay.code=="ok" && replay.replay)
   if stage=="release" {
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    payload=encode(doc(map[string]string{"requirements_revision"="3","body_cipher"=cipher(f,`{"goal":"raised","acceptance":["done"],"budget":{"max_attempts":2}}`)}))
    testing.expect_value(t,invoke(f,command(f,"requirements.edit","raise","task",payload,"7",904000),payload,902000).code,"ok")
   }
   close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
   testing.expect(t,!control_held(&f.store,"chain","task") && control_ready(&f.store,"chain","task"))
   budget_expect_test(t,f,1,1,"")
   testing.expect_value(t,lease_invoke(f,lease_request(f,lease_child(),"lease.claim","next","next_lease","","8",904000),"",lease_child(),902000).code,"ok")
  }
 }
}

@(test)
budget_hold_release_retains_independent_block_and_cancel :: proc(t:^testing.T) {
 context.allocator=context.temp_allocator
 for cancel in ([2]bool{false,true}) {
  f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
  p:=encode(doc(map[string]string{"requirements_revision"="2","body_cipher"=cipher(f,`{"goal":"bounded","acceptance":["done"],"budget":{"max_attempts":1}}`)}))
  testing.expect_value(t,invoke(f,command(f,"requirements.edit","one","task",p,"4"),p).code,"ok")
  r:=dependency_claim(f,"task","lease","claim","5");testing.expect_value(t,r.code,"ok")
  testing.expect_value(t,control_call(f,"task.hold","hold_before_block","5").code,"ok")
  p=`{"requirements_revision":"2","summary":"Independent block","next_steps":"Need answer","waiting_on":"human"}`
  testing.expect_value(t,attempt_call_test(f,"lease.block","block","lease",p,result_cap(r),"6").code,"ok")
  testing.expect_value(t,control_call(f,"task.release","release_blocked","7").code,"ok")
  revision:="8"
  if cancel {
   testing.expect_value(t,control_call(f,"task.cancel","cancel","8").code,"ok")
   revision="9"
  }
  p=encode(doc(map[string]string{"requirements_revision"="3","body_cipher"=cipher(f,`{"goal":"raised","acceptance":["done"],"budget":{"max_attempts":2}}`)}))
  testing.expect_value(t,invoke(f,command(f,"requirements.edit","raise","task",p,revision),p).code,"ok")
  close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
  rows,ok:=query(f.store.db,"SELECT mode,reason,waiting_on FROM local_controls")
  if cancel { testing.expect(t,ok && rows[0][0]=="cancelled") } else {
   testing.expect(t,ok && rows[0][0]=="blocked" && rows[0][1]=="Independent block" && rows[0][2]=="human")
  }
  rev,_:=query(f.store.db,"SELECT revision FROM tasks WHERE task_id='task'")
  testing.expect_value(t,dependency_claim(f,"task","denied","claim_denied",rev[0][0]).code,"invalid_scope")
 }
}

@(test)
budget_hold_before_expiry_and_rehold_remain_active_after_recovery :: proc(t:^testing.T) {
 context.allocator=context.temp_allocator
 for rehold in ([2]bool{false,true}) {
  f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
  p:=encode(doc(map[string]string{"requirements_revision"="2","body_cipher"=cipher(f,`{"goal":"bounded","acceptance":["done"],"budget":{"max_attempts":1}}`)}))
  testing.expect_value(t,invoke(f,command(f,"requirements.edit","one","task",p,"4"),p).code,"ok")
  testing.expect_value(t,dependency_claim(f,"task","lease","claim","5").code,"ok")
  testing.expect_value(t,control_call(f,"task.hold","hold_before_expiry","5").code,"ok")
  testing.expect(t,expire_leases(&f.store,902000))
  revision:="6"
  if rehold {
   testing.expect_value(t,review_human_at(f,"task.release","release","6",902000).code,"ok")
   testing.expect_value(t,review_human_at(f,"task.hold","rehold","7",902000,"New independent hold").code,"ok")
   revision="8"
  }
  p=encode(doc(map[string]string{"requirements_revision"="3","body_cipher"=cipher(f,`{"goal":"raised","acceptance":["done"],"budget":{"max_attempts":2}}`)}))
  testing.expect_value(t,invoke(f,command(f,"requirements.edit","raise","task",p,revision,904000),p,902000).code,"ok")
  close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
  testing.expect(t,control_held(&f.store,"chain","task"))
  if rehold {
   rows,ok:=query(f.store.db,"SELECT reason FROM local_controls")
   testing.expect(t,ok && rows[0][0]=="New independent hold")
  }
  rows,_:=query(f.store.db,"SELECT revision FROM tasks WHERE task_id='task'")
  testing.expect_value(t,lease_invoke(f,lease_request(f,lease_child(),"lease.claim","denied","denied","",rows[0][0],904000),"",lease_child(),902000).code,"invalid_scope")
  testing.expect_value(t,review_human_at(f,"task.release","final_release",rows[0][0],902000).code,"ok")
  rows,_=query(f.store.db,"SELECT revision FROM tasks WHERE task_id='task'")
  testing.expect_value(t,lease_invoke(f,lease_request(f,lease_child(),"lease.claim","next","next","",rows[0][0],904000),"",lease_child(),902000).code,"ok")
 }
}
