#+feature dynamic-literals
package owner_local
import "core:encoding/json"
import "core:testing"
import contracts "odin_test:contracts"

@(test)
budget_overlap_timestamp_fractional_native_precision :: proc(t:^testing.T) {
 testing.expect(t,overlap_timestamp("1970-01-01T00:00:01.123Z","1123"))
 testing.expect(t,overlap_timestamp("2026-11-06T17:17:00.924Z","1793985420924"))
 testing.expect(t,overlap_timestamp("1970-01-01T05:30:01.123+05:30","1123"))
 testing.expect(t,overlap_timestamp("1970-01-01T00:00:01.12Z","1123"))
 testing.expect(t,!overlap_timestamp("1970-01-01T00:00:01.1231Z","1123"))
 testing.expect(t,!overlap_timestamp("1970-01-01T00:00:01.123Zjunk","1123"))
}

overlap_fixture_bundle :: proc(f:^Fixture,mutation:string="")->string {
 b,_:=contracts.owner_parse(budget_bundle_test(),"native_history_bundle")
 b["owner_user_id"]=json.String(f.store.account)
 for plural in ([2]string{"attempts","events"}) {
  value,_:=contracts.owner_request_document(field(b,plural));items,_:=value.(json.Array)
  records:=make([dynamic]string,context.temp_allocator)
  for item in items {
   text,_:=item.(json.String)
   kind:="native_history_event";if plural=="attempts" do kind="native_history_attempt"
   r,_:=contracts.owner_parse(string(text),kind)
   r["owner_user_id"]=json.String(f.store.account)
   r["provenance_json"]=json.String(`{"requirements_revision":1,"configuration_revision":1}`)
   if plural=="attempts" {
    r["holder_instance_id"]=json.String("instance")
    r["started_at"]=json.String("1970-01-01T00:00:01Z");r["ended_at"]=json.String("1970-01-01T00:00:01Z")
    if mutation=="time" do r["started_at"]=json.String("1970-01-01T00:00:02Z")
    if mutation=="provenance" do r["provenance_json"]=json.String(`{"requirements_revision":2,"configuration_revision":1}`)
   } else {
    r["ts_ms"]=json.String("1000")
    if field(r,"kind")=="lease_granted" {
     r["payload_json"]=json.String(`{"lease_id":"native_lease","instance_id":"instance","bridge_id":"bridge","attempt_no":5}`)
     if mutation=="lease" do r["payload_json"]=json.String(`{"lease_id":"other_lease","instance_id":"instance","attempt_no":5}`)
    }
    if field(r,"kind")=="handoff" {
     r["actor_kind"]=json.String("agent");r["actor_id"]=json.String("instance")
     if mutation=="actor" do r["actor_id"]=json.String("another_instance")
    }
   }
   append(&records,encode(r))
  }
  b[plural]=json.String(encode(records))
 }
 return encode(b)
}
overlap_seed :: proc(t:^testing.T,f:^Fixture) {
 lifecycle_seed(t,f)
 r:=lease_invoke(f,lease_request(f,lease_child(),"lease.claim","overlap_claim","native_lease","","4"),"",lease_child())
 testing.expect_value(t,r.code,"ok")
 p:=`{"requirements_revision":"1","summary":"continue","next_steps":"finish"}`
 testing.expect_value(t,attempt_call_test(f,"lease.handoff","overlap_handoff","native_lease",p,result_cap(r),"4").code,"ok")
}
@(test)
budget_exact_contiguous_overlap_activation_preserves_ids_and_counts_once :: proc(t:^testing.T) {
 context.allocator=context.temp_allocator
 f:=fixture(t);defer destroy(f);overlap_seed(t,f)
 testing.expect_value(t,native_import_call(f,overlap_fixture_bundle(f),"exact_import","5").code,"ok")
 p:=budget_activation_test(t,f)
 raw:=command(f,"budget.activate","exact_activation","task",p,"6")
 testing.expect_value(t,invoke(f,raw,p).code,"ok")
 budget_expect_test(t,f,5,5,"")
 rows,ok:=query(f.store.db,"SELECT (SELECT count(*) FROM native_budget_overlap),(SELECT count(*) FROM local_leases),(SELECT attempt FROM local_work_attempts WHERE lease_id='native_lease')")
 testing.expect(t,ok && rows[0][0]=="2" && rows[0][1]=="1" && rows[0][2]=="1")
 close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
 replay:=invoke(f,raw,p,4000000);testing.expect(t,replay.code=="ok" && replay.replay)
 budget_expect_test(t,f,5,5,"")
 testing.expect_value(t,lease_invoke(f,lease_request(f,lease_child(),"lease.claim","continue_overlap","continued","","7"),"",lease_child()).code,"ok")
 budget_expect_test(t,f,5,5,"")
 testing.expect(t,!exec(f.store.db,"DELETE FROM native_budget_overlap"))
}
@(test)
budget_overlap_conflicts_and_activation_commit_failure_preserve_both_histories :: proc(t:^testing.T) {
 context.allocator=context.temp_allocator
 for mutation in ([4]string{"time","provenance","lease","actor"}) {
  f:=fixture(t);defer destroy(f);overlap_seed(t,f)
  testing.expect_value(t,native_import_call(f,overlap_fixture_bundle(f,mutation),"bad_import","5").code,"ok")
  p:=budget_activation_test(t,f)
  testing.expect_value(t,invoke(f,command(f,"budget.activate","ambiguous","task",p,"6"),p).code,"recovery_required")
  rows,ok:=query(f.store.db,"SELECT (SELECT count(*) FROM native_budget_baselines),(SELECT count(*) FROM native_budget_overlap),(SELECT count(*) FROM local_leases),(SELECT count(*) FROM native_history_records)")
  testing.expect(t,ok && rows[0][0]=="0" && rows[0][1]=="0" && rows[0][2]=="1" && rows[0][3]=="4")
 }
 g:=fixture(t);defer destroy(g);overlap_seed(t,g)
 testing.expect_value(t,native_import_call(g,overlap_fixture_bundle(g),"exact_import","5").code,"ok")
 p:=budget_activation_test(t,g)
 testing.expect(t,exec(g.store.db,`CREATE TABLE overlap_parent(id INTEGER PRIMARY KEY);CREATE TABLE overlap_ref(id INTEGER REFERENCES overlap_parent(id) DEFERRABLE INITIALLY DEFERRED);
 CREATE TRIGGER overlap_fail AFTER INSERT ON native_budget_baselines BEGIN INSERT INTO overlap_ref VALUES(1);END;`))
 testing.expect_value(t,invoke(g,command(g,"budget.activate","rollback_overlap","task",p,"6"),p).code,"storage_error")
 rows,ok:=query(g.store.db,"SELECT (SELECT count(*) FROM native_budget_baselines),(SELECT count(*) FROM native_budget_overlap),(SELECT count(*) FROM local_leases)")
 testing.expect(t,ok && rows[0][0]=="0" && rows[0][1]=="0" && rows[0][2]=="1")
 testing.expect(t,exec(g.store.db,"DROP TRIGGER overlap_fail"))
 testing.expect_value(t,invoke(g,command(g,"budget.activate","retry_overlap","task",p,"6"),p).code,"ok")
}

@(test)
budget_exact_approved_overlap_retains_terminal_gate_and_direct_reopen :: proc(t:^testing.T) {
 context.allocator=context.temp_allocator
 f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
 r:=dependency_claim(f,"task","native_lease","approved_claim","4");cap:=result_cap(r)
 p:=`{"requirements_revision":"1"}`
 testing.expect_value(t,attempt_call_test(f,"requirements.present","present","native_lease",p,cap,"4").code,"ok")
 testing.expect_value(t,attempt_call_test(f,"requirements.ack","ack","native_lease",p,cap,"4").code,"ok")
 p=`{"requirements_revision":"1","head":"","summary":"Done"}`
 testing.expect_value(t,attempt_call_test(f,"lease.submit","submit","native_lease",p,cap,"4").code,"ok")
 p=`{"requirements_revision":"1","attempt":"1","head":"","verdict":"approve","summary":"Approved"}`
 opened:=safety_review_call(f,"native_lease","review.open","review_open",p,"","5")
 testing.expect_value(t,opened.code,"ok")
 testing.expect_value(t,safety_review_call(f,"native_lease","review.post","review",p,result_cap(opened),"5").code,"ok")
 b,_:=contracts.owner_parse(overlap_fixture_bundle(f),"native_history_bundle")
 value,_:=contracts.owner_request_document(field(b,"attempts"));attempts,_:=value.(json.Array)
 text,_:=attempts[0].(json.String);attempt,_:=contracts.owner_parse(string(text),"native_history_attempt")
 attempt["outcome"]=json.String("submitted");b["attempts"]=json.String(encode([1]string{encode(attempt)}))
 value,_=contracts.owner_request_document(field(b,"events"));events,_:=value.(json.Array)
 records:=make([dynamic]string,context.temp_allocator)
 for item in events {
  text,_:=item.(json.String);e,_:=contracts.owner_parse(string(text),"native_history_event")
  if field(e,"kind")=="handoff" do e["kind"]=json.String("submitted")
  append(&records,encode(e))
 }
 append(&records,encode(contracts.Owner_Native_History_Event{event_id="9007199254740996",task_id="task",chain_id="chain",owner_user_id="account",ts_ms="1000",actor_kind="hub",kind="approved",payload_json=`{"attempt_no":5}`,provenance_json=`{"requirements_revision":1,"configuration_revision":1}`}))
 b["events"]=json.String(encode(records))
 testing.expect_value(t,native_import_call(f,encode(b),"approved_import","6").code,"ok")
 activation,_:=contracts.owner_parse(budget_activation_test(t,f),"budget_activation_payload")
 activation["native_cutoff"]=json.String("9007199254740996");p=encode(activation)
 testing.expect_value(t,invoke(f,command(f,"budget.activate","approved_activation","task",p,"7"),p).code,"ok")
 budget_expect_test(t,f,5,5,"native_terminal")
 testing.expect_value(t,control_call(f,"task.reopen","reopen_approved","8").code,"ok")
    review_seq,_:=query(f.store.db,"SELECT seq FROM local_events WHERE operation_id='review'")
    testing.expect(t,overlap_approval_settled(&f.store,"chain","task",review_seq[0][0],review_seq[0][0],"1"),"reopen cannot erase the immutable original gate proof")
 testing.expect_value(t,dependency_claim(f,"task","new_lease","recovered","9").code,"ok")
 budget_expect_test(t,f,6,5,"")
}
