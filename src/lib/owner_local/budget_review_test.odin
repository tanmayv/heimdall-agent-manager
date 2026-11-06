#+feature dynamic-literals
package owner_local
import "core:testing"
import "core:fmt"
import "core:encoding/json"
import contracts "odin_test:contracts"
@(test)
safety_budget_increase_after_expiry_allows_native_next_grant :: proc(t:^testing.T) {
 context.allocator=context.temp_allocator
 f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
 p:=encode(doc(map[string]string{"requirements_revision"="2","body_cipher"=cipher(f,`{"goal":"bounded","acceptance":["done"],"budget":{"max_attempts":1}}`)}))
 testing.expect_value(t,invoke(f,command(f,"requirements.edit","one","task",p,"4"),p).code,"ok")
 testing.expect_value(t,lease_invoke(f,lease_request(f,lease_child(),"lease.claim","only","only_lease","","5"),"",lease_child()).code,"ok")
 testing.expect(t,expire_leases(&f.store,902000))
 budget_expect_test(t,f,1,1,"budget_exhausted")
 p=encode(doc(map[string]string{"requirements_revision"="3","body_cipher"=cipher(f,`{"goal":"raised","acceptance":["done"],"budget":{"max_attempts":2}}`)}))
 testing.expect_value(t,invoke(f,command(f,"requirements.edit","raised","task",p,"5",904000),p,902000).code,"ok")
 budget_expect_test(t,f,1,1,"")
 testing.expect_value(t,lease_invoke(f,lease_request(f,lease_child(),"lease.claim","next","next_lease","","6",904000),"",lease_child(),902000).code,"ok")
}

@(test)
safety_three_rejections_stop_fourth_local_claim :: proc(t:^testing.T) {
 budget_review_cycles(t,false)
}
@(test)
budget_held_third_rejection_settles_oscillation_only_on_release :: proc(t:^testing.T) {
 budget_review_cycles(t,true)
}
budget_review_cycles :: proc(t:^testing.T,held_third:bool) {
 context.allocator=context.temp_allocator
 f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
 for n in 1..=3 {
  rev,_:=query(f.store.db,"SELECT revision FROM tasks WHERE task_id='task'")
  lease:=fmt.tprintf("lease%d",n)
  r:=lease_invoke(f,lease_request(f,lease_child(),"lease.claim",fmt.tprintf("claim%d",n),lease,"",rev[0][0]),"",lease_child())
  if !testing.expect_value(t,r.code,"ok") do return
  cap:=result_cap(r)
  p:=`{"requirements_revision":"1"}`
  testing.expect_value(t,attempt_call_test(f,"requirements.present",fmt.tprintf("present%d",n),lease,p,cap,rev[0][0]).code,"ok")
  testing.expect_value(t,attempt_call_test(f,"requirements.ack",fmt.tprintf("ack%d",n),lease,p,cap,rev[0][0]).code,"ok")
  p=`{"requirements_revision":"1","head":"","summary":"Done"}`
  testing.expect_value(t,attempt_call_test(f,"lease.submit",fmt.tprintf("submit%d",n),lease,p,cap,rev[0][0]).code,"ok")
  rev,_=query(f.store.db,"SELECT revision FROM tasks WHERE task_id='task'")
  p=fmt.tprintf(`{{"requirements_revision":"1","attempt":"%d","head":"","verdict":"request_changes","summary":"Fix it"}}`,n)
  opened:=safety_review_call(f,lease,"review.open",fmt.tprintf("open%d",n),p,"",rev[0][0])
  if !testing.expect_value(t,opened.code,"ok") do return
  if n==3 && held_third {
   testing.expect_value(t,control_call(f,"task.hold","hold_last_review",rev[0][0]).code,"ok")
   rev,_=query(f.store.db,"SELECT revision FROM tasks WHERE task_id='task'")
  }
  testing.expect_value(t,safety_review_call(f,lease,"review.post",fmt.tprintf("review%d",n),p,result_cap(opened),rev[0][0]).code,"ok")
  if n==3 && held_third {
   pending,_,pending_ok:=budget_view(&f.store,"chain","task")
   testing.expect(t,pending_ok && pending.held && !pending.oscillating && pending.review_rounds==2)
   rev,_=query(f.store.db,"SELECT revision FROM tasks WHERE task_id='task'")
   testing.expect_value(t,control_call(f,"task.release","settle_last_review",rev[0][0]).code,"ok")
  }
 }
 v,_,ok:=budget_view(&f.store,"chain","task")
 testing.expect(t,ok && v.oscillating && v.review_rounds==3)
 rev,_:=query(f.store.db,"SELECT revision FROM tasks WHERE task_id='task'")
 fourth:=lease_invoke(f,lease_request(f,lease_child(),"lease.claim","fourth","lease4","",rev[0][0]),"",lease_child())
 testing.expect(t,fourth.code!="ok","native oscillation must stop fourth work grant")
 close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
 budget_expect_test(t,f,3,3,"oscillation")
 testing.expect_value(t,control_call(f,"task.resolve","answer_oscillation",rev[0][0]).code,"ok")
 rev,_=query(f.store.db,"SELECT revision FROM tasks WHERE task_id='task'")
 testing.expect_value(t,lease_invoke(f,lease_request(f,lease_child(),"lease.claim","answered_fourth","lease4","",rev[0][0]),"",lease_child()).code,"ok")
}

review_human_at :: proc(f:^Fixture,method,op,revision:string,now:i64,body:="operator reason")->Result {
 p:=encode(doc(map[string]string{"body_cipher"=cipher(f,body)}))
 return invoke(f,command(f,method,op,"task",p,revision,now+2000),p,now)
}

@(test)
budget_increase_held_restart_preserves_hold_and_independent_block :: proc(t:^testing.T) {
 context.allocator=context.temp_allocator
 for held in ([2]bool{false,true}) {
  f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
  p:=encode(doc(map[string]string{"requirements_revision"="2","body_cipher"=cipher(f,`{"goal":"bounded","acceptance":["done"],"budget":{"max_attempts":1}}`)}))
  testing.expect_value(t,invoke(f,command(f,"requirements.edit","one","task",p,"4"),p).code,"ok")
  testing.expect_value(t,lease_invoke(f,lease_request(f,lease_child(),"lease.claim","claim","lease","","5"),"",lease_child()).code,"ok")
  testing.expect(t,expire_leases(&f.store,902000))
  if held do testing.expect_value(t,review_human_at(f,"task.hold","hold","5",902000,"Keep this hold").code,"ok")
  rev,_:=query(f.store.db,"SELECT revision FROM tasks WHERE task_id='task'")
  p=encode(doc(map[string]string{"requirements_revision"="3","body_cipher"=cipher(f,`{"goal":"raised","acceptance":["done"],"budget":{"max_attempts":2}}`)}))
  testing.expect_value(t,invoke(f,command(f,"requirements.edit","raise","task",p,rev[0][0],904000),p,902000).code,"ok")
  close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
  budget_expect_test(t,f,1,1,"")
  rev,_=query(f.store.db,"SELECT revision FROM tasks WHERE task_id='task'")
  if held {
   testing.expect(t,control_held(&f.store,"chain","task"))
   overlay,overlay_ok:=query(f.store.db,"SELECT reason,waiting_on FROM local_controls WHERE chain_id='chain' AND task_id='task'")
   testing.expect(t,overlay_ok && overlay[0][0]=="Keep this hold" && overlay[0][1]=="","budget recovery preserves independent hold reason without its stale waiting target")
   testing.expect_value(t,lease_invoke(f,lease_request(f,lease_child(),"lease.claim","held_denied","next","",rev[0][0],904000),"",lease_child(),902000).code,"invalid_scope")
   testing.expect_value(t,review_human_at(f,"task.release","release",rev[0][0],902000).code,"ok")
   rev,_=query(f.store.db,"SELECT revision FROM tasks WHERE task_id='task'")
  }
  testing.expect_value(t,lease_invoke(f,lease_request(f,lease_child(),"lease.claim","next","next","",rev[0][0],904000),"",lease_child(),902000).code,"ok")
 }
 g:=fixture(t);defer destroy(g);lifecycle_seed(t,g)
 p:=encode(doc(map[string]string{"requirements_revision"="2","body_cipher"=cipher(g,`{"goal":"bounded","acceptance":["done"],"budget":{"max_attempts":1}}`)}))
 testing.expect_value(t,invoke(g,command(g,"requirements.edit","one","task",p,"4"),p).code,"ok")
 r:=lease_invoke(g,lease_request(g,lease_child(),"lease.claim","claim","lease","","5"),"",lease_child())
 p=`{"requirements_revision":"2","summary":"independent human block","next_steps":"answer explicitly","waiting_on":"human"}`
 testing.expect_value(t,attempt_call_test(g,"lease.block","human_block","lease",p,result_cap(r),"5").code,"ok")
 p=encode(doc(map[string]string{"requirements_revision"="3","body_cipher"=cipher(g,`{"goal":"raised","acceptance":["done"],"budget":{"max_attempts":2}}`)}))
 testing.expect_value(t,invoke(g,command(g,"requirements.edit","raise","task",p,"6"),p).code,"ok")
 rows,ok:=query(g.store.db,"SELECT mode,reason FROM local_controls")
 testing.expect(t,ok && rows[0][0]=="blocked" && rows[0][1]=="independent human block")
 testing.expect_value(t,lease_invoke(g,lease_request(g,lease_child(),"lease.claim","not_answered","next","","7"),"",lease_child()).code,"invalid_scope")
 testing.expect_value(t,control_call(g,"task.resolve","answer","7").code,"ok")
 testing.expect_value(t,lease_invoke(g,lease_request(g,lease_child(),"lease.claim","answered","next","","8"),"",lease_child()).code,"ok")
}

safety_review_call :: proc(f:^Fixture,lease,method,op,p,cap,rev:string)->Result {
 c,_:=contracts.owner_parse(lifecycle_raw(f,lifecycle_reviewer(),method,op,p,cap,rev),"lifecycle_command")
 c["lease_id"]=json.String(lease)
 sig,_:=test_sign(&f.owner_priv,"lifecycle_command",c);c["signature"]=json.String(sig)
 return execute_lifecycle(&f.store,encode(c),p,cap,lifecycle_reviewer(),f.owner,1000,Signer{&f.owner_priv,test_sign},Source_Proof{"",true})
}
