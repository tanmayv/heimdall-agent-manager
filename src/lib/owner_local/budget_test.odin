#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:testing"
import "core:strings"
import contracts "odin_test:contracts"

budget_bundle_test :: proc()->string {
    return string(#load("../../contracts/fixtures/owner-native-budget.json"))
}

@(test)
budget_native_terminal_baseline_reopens_directly_without_count_reset :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    for state in ([2]string{"done","cancelled"}) {
        f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
        bundle,_:=contracts.owner_parse(budget_bundle_test(),"native_history_bundle")
        value,_:=contracts.owner_request_document(field(bundle,"events"));events,_:=value.(json.Array)
        text,_:=events[0].(json.String);event,_:=contracts.owner_parse(string(text),"native_history_event")
        event["payload_json"]=json.String(fmt.tprintf(`{{"state":"%s","published":true,"attempt_no":2}}`,state))
        bundle["events"]=json.String(encode([1]string{encode(event)}));bundle["attempts"]=json.String("[]")
        testing.expect_value(t,native_import_call(f,encode(bundle),"terminal_snapshot","4").code,"ok")
        activation,_:=contracts.owner_parse(budget_activation_test(t,f),"budget_activation_payload")
        activation["native_cutoff"]=json.String("9007199254740993")
        p:=encode(activation)
        testing.expect_value(t,invoke(f,command(f,"budget.activate","terminal_baseline","task",p,"5"),p).code,"ok")
        budget_expect_test(t,f,2,2,"native_terminal")
        testing.expect_value(t,lease_invoke(f,lease_request(f,lease_child(),"lease.claim","terminal_denied","lease","","6"),"",lease_child()).code,"operation_conflict")
        if state=="done" do testing.expect_value(t,control_call(f,"task.cancel","already_done","6").code,"operation_conflict")
        testing.expect_value(t,control_call(f,"task.reopen","native_reopen","6").code,"ok")
        testing.expect_value(t,lease_invoke(f,lease_request(f,lease_child(),"lease.claim","after_reopen","lease","","7"),"",lease_child()).code,"ok")
        budget_expect_test(t,f,3,2,"")
    }
}

@(test)
budget_native_dispatch_refund_validates_original_row_bit_and_outcome :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    bundle,_:=contracts.owner_parse(budget_bundle_test(),"native_history_bundle")
    for kind in ([2]string{"attempt","event"}) {
        plural:=fmt.tprintf("%ss",kind)
        value,_:=contracts.owner_request_document(field(bundle,plural));items,_:=value.(json.Array)
        transformed:=make([dynamic]string,context.temp_allocator)
        for item in items {
            text,_:=item.(json.String);record,_:=contracts.owner_parse(string(text),fmt.tprintf("native_history_%s",kind))
            if kind=="attempt" { record["outcome"]=json.String("dispatch_failed");record["counts_toward_budget"]=json.String("0") }
            if kind=="event" && field(record,"kind")=="handoff" {
                record["kind"]=json.String("blocked");record["payload_json"]=json.String(`{"lease_id":"native_lease","dispatch_failed":true,"waiting_on":{"kind":"agent_not_running"}}`)
            }
            append(&transformed,encode(record))
        }
        bundle[plural]=json.String(encode(transformed))
    }
    testing.expect_value(t,native_import_call(f,encode(bundle),"dispatch_snapshot","4").code,"ok")
    p:=budget_activation_test(t,f)
    testing.expect_value(t,invoke(f,command(f,"budget.activate","dispatch_baseline","task",p,"5"),p).code,"ok")
    budget_expect_test(t,f,5,4,"native_blocked")
    testing.expect_value(t,lease_invoke(f,lease_request(f,lease_child(),"lease.claim","unanswered_refund","lease","","6"),"",lease_child()).code,"operation_conflict")
    testing.expect_value(t,control_call(f,"task.resolve","answer_native_failure","6").code,"ok")
    testing.expect_value(t,lease_invoke(f,lease_request(f,lease_child(),"lease.claim","after_refund","lease","","7"),"",lease_child()).code,"ok")
    budget_expect_test(t,f,6,5,"")
}

@(test)
budget_large_migrated_seeds_remain_explicit_without_fabricated_rows :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    for seed in ([2]i64{1000001,0x7fffffffffffffff}) {
        f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
        bundle,_:=contracts.owner_parse(budget_bundle_test(),"native_history_bundle")
        value,_:=contracts.owner_request_document(field(bundle,"events"));events,_:=value.(json.Array)
        text,_:=events[0].(json.String);event,_:=contracts.owner_parse(string(text),"native_history_event")
        event["payload_json"]=json.String(fmt.tprintf(`{{"state":"ready","published":true,"attempt_no":%d}}`,seed))
        bundle["events"]=json.String(encode([1]string{encode(event)}));bundle["attempts"]=json.String("[]")
        testing.expect_value(t,native_import_call(f,encode(bundle),"large_seed","4").code,"ok")
        activation,_:=contracts.owner_parse(budget_activation_test(t,f),"budget_activation_payload")
        activation["native_cutoff"]=json.String("9007199254740993")
        body:=encode(activation)
        testing.expect_value(t,invoke(f,command(f,"budget.activate","activate_large_seed","task",body,"5"),body).code,"ok")
        budget_expect_test(t,f,seed,seed,"budget_exhausted")
        rows,ok:=query(f.store.db,"SELECT count(*) FROM native_history_records WHERE record_kind='attempt'")
        testing.expect(t,ok && rows[0][0]=="0")
        result:=lease_invoke(f,lease_request(f,lease_child(),"lease.claim","no_overflow","lease","","6"),"",lease_child())
        testing.expect(t,result.code=="budget_exhausted" || result.code=="recovery_required")
    }
}

@(test)
budget_v15_upgrade_collision_commit_rollback_preserves_source_and_live_authority :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f);cap:=lifecycle_ready(t,f)
    keep:="SELECT (SELECT json_group_array(json_array(seq,evidence_json)) FROM local_events),(SELECT json_group_array(json_array(principal_id,operation_id,result_json)) FROM command_receipts),(SELECT capability_json FROM local_leases WHERE retired_seq IS NULL LIMIT 1)"
    before,_:=query(f.store.db,keep)
    close(&f.store)
    db:DB
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    prefix:=string(MIGRATION_015);prefix=prefix[:strings.index(prefix,"CREATE TABLE native_history_records")]
    testing.expect(t,exec(db,"DROP TABLE IF EXISTS local_metadata_retirements; DROP TABLE IF EXISTS local_brief_inputs; DROP TABLE IF EXISTS local_coordinator_revocations; DROP TABLE IF EXISTS local_config_revocations; DROP TABLE IF EXISTS local_chain_directory_versions; DROP TABLE IF EXISTS local_chain_member_versions; DROP TABLE IF EXISTS local_member_chains; DROP TABLE IF EXISTS local_chain_defaults_versions; DROP TABLE IF EXISTS local_chain_summary_versions; DROP TRIGGER IF EXISTS native_history_origin; DROP TABLE IF EXISTS local_fleet_policy_sources; DROP TABLE IF EXISTS native_fleet_policies; DROP TABLE IF EXISTS native_fleet_snapshots; DROP TABLE IF EXISTS local_task_priority_versions; DROP TABLE IF EXISTS native_fact_chain; DROP TABLE IF EXISTS native_fact_task; DROP TABLE IF EXISTS native_fact_comment; DROP TABLE IF EXISTS native_fact_summary; DROP TABLE IF EXISTS native_fact_snapshots; DROP TABLE IF EXISTS native_metadata_members; DROP TABLE IF EXISTS native_metadata_directories; DROP TABLE IF EXISTS native_metadata_snapshots; DROP TABLE IF EXISTS native_metadata_origins; DROP VIEW IF EXISTS local_fleet_policy_current; DROP TABLE IF EXISTS local_fleet_policy_models; DROP TABLE IF EXISTS local_fleet_policy_roles; DROP TABLE IF EXISTS local_fleet_policy_versions; DROP TRIGGER native_budget_snapshot_sealed; DROP TABLE native_budget_overlap; DROP TABLE budget_control_owners; DROP TABLE local_dependency_retirements; DROP TABLE local_budget_evidence; DROP TABLE native_budget_baselines"))
    testing.expect(t,exec(db,prefix))
    testing.expect(t,exec(db,"UPDATE schema_migrations SET version=15; CREATE VIEW native_budget_baselines AS SELECT 1"))
    testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,!open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    rows,_:=query(db,"SELECT schema_version,(SELECT version FROM schema_migrations) FROM runtime_database")
    testing.expect(t,rows[0][0]=="15" && rows[0][1]=="15")
    testing.expect(t,exec(db,`DROP VIEW native_budget_baselines;
      CREATE TABLE budget_parent(id INTEGER PRIMARY KEY);
      CREATE TABLE budget_ref(id INTEGER REFERENCES budget_parent(id) DEFERRABLE INITIALLY DEFERRED);
      CREATE TRIGGER budget_commit_fail AFTER UPDATE ON schema_migrations WHEN NEW.version=16 BEGIN INSERT INTO budget_ref VALUES(1); END;`))
    testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,!open(&f.store,f.path,"account","bridge","bridge_key"))
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    rows,_=query(db,"SELECT schema_version,(SELECT version FROM schema_migrations),(SELECT count(*) FROM sqlite_master WHERE name='native_budget_baselines') FROM runtime_database")
    testing.expect(t,rows[0][0]=="15" && rows[0][1]=="15" && rows[0][2]=="0")
    after,_:=query(db,keep);testing.expect_value(t,encode(after),encode(before))
    testing.expect(t,exec(db,"DROP TRIGGER budget_commit_fail"))
    testing.expect_value(t,sqlite3_close(db),0)
    testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    after,_=query(f.store.db,keep);testing.expect_value(t,encode(after),encode(before))
    testing.expect_value(t,lifecycle_call(f,lease_child(),"requirements.present","after_v16",`{"requirements_revision":"1"}`,cap).code,"ok")
    rows,_=query(f.store.db,"PRAGMA foreign_key_check");testing.expect_value(t,len(rows),0)
}

@(test)
budget_expiry_while_held_preserves_overlay_and_releases_to_exhausted_block :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    p:=encode(doc(map[string]string{"requirements_revision"="2","body_cipher"=cipher(f,`{"goal":"bounded","acceptance":["done"],"budget":{"max_attempts":1,"hard_deadline":1}}`)}))
    testing.expect_value(t,invoke(f,command(f,"requirements.edit","one","task",p,"4"),p).code,"ok")
    testing.expect_value(t,lease_invoke(f,lease_request(f,lease_child(),"lease.claim","first","lease","","5"),"",lease_child()).code,"ok")
    testing.expect_value(t,control_call(f,"task.hold","hold","5").code,"ok")
    testing.expect(t,expire_leases(&f.store,2000))
    budget_expect_test(t,f,1,1,"budget_exhausted")
    p=encode(doc(map[string]string{"body_cipher"=cipher(f,"Release exhausted overlay")}))
    testing.expect_value(t,invoke(f,command(f,"task.release","release","task",p,"6",4000),p,2000).code,"ok")
    rows,ok:=query(f.store.db,"SELECT mode,reason FROM local_controls WHERE task_id='task'")
    testing.expect(t,ok && rows[0][0]=="blocked" && rows[0][1]=="budget_exhausted")
}

budget_activation_test :: proc(t:^testing.T,f:^Fixture)->string {
    digest,counts,ok:=budget_snapshot(&f.store,"chain","task","budget_snapshot")
    testing.expect(t,ok)
    state,read:=query(f.store.db,"SELECT commit_seq FROM runtime_database")
    testing.expect(t,read)
    return encode(contracts.Owner_Budget_Activation_Payload{source_revision="budget_snapshot",snapshot_digest=digest,native_cutoff="9007199254740995",
      local_cutoff=state[0][0],event_count=fmt.tprintf("%d",counts[1]),attempt_count=fmt.tprintf("%d",counts[0]),facet_count=fmt.tprintf("%d",counts[2]),
      requirements_revision="1",configuration_revision="1",execution="standalone",source_gate="0",source_no_review="0"})
}
budget_expect_test :: proc(t:^testing.T,f:^Fixture,n,count:i64,reason:string) {
    _,state,ok:=budget_view(&f.store,"chain","task")
    testing.expect(t,ok)
    testing.expect_value(t,state.attempt_no,fmt.tprintf("%d",n))
    testing.expect_value(t,state.counting_attempts,fmt.tprintf("%d",count))
    testing.expect_value(t,state.reason,reason)
    _,valid:=contracts.owner_parse(encode(state),"budget_state");testing.expect(t,valid)
}

@(test)
budget_activation_migrated_handoff_exhaustion_replay_restart_and_recovery :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    bundle:=budget_bundle_test()
    testing.expect_value(t,native_import_call(f,bundle,"import_budget","4").code,"ok")
    budget_expect_test(t,f,0,0,"activation_required")
    testing.expect_value(t,lease_invoke(f,lease_request(f,lease_child(),"lease.claim","unactivated","lease","","5"),"",lease_child()).code,"recovery_required")
    p:=budget_activation_test(t,f)
    raw:=command(f,"budget.activate","activate","task",p,"5")
    result:=invoke(f,raw,p)
    if !testing.expect_value(t,result.code,"ok") do return
    budget_expect_test(t,f,5,5,"")
    replay:=invoke(f,raw,p,4000000)
    testing.expect(t,replay.code=="ok" && replay.replay)
    testing.expect(t,!exec(f.store.db,"UPDATE native_budget_baselines SET local_cutoff=0"))
    testing.expect(t,!exec(f.store.db,"DELETE FROM native_budget_baselines"))
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    budget_expect_test(t,f,5,5,"")
    claim_raw:=lease_request(f,lease_child(),"lease.claim","continue_native","local_lease","","6")
    claimed:=lease_invoke(f,claim_raw,"",lease_child())
    if !testing.expect_value(t,claimed.code,"ok") do return
    cap:=result_cap(claimed)
    budget_expect_test(t,f,5,5,"")
    p=`{"requirements_revision":"1","summary":"blocked after continuation","next_steps":"recover","waiting_on":"human"}`
    testing.expect_value(t,attempt_call_test(f,"lease.block","budget_block","local_lease",p,cap,"6").code,"ok")
    budget_expect_test(t,f,5,5,"budget_exhausted")
    testing.expect_value(t,lease_invoke(f,lease_request(f,lease_child(),"lease.claim","exhausted","denied_lease","","7"),"",lease_child()).code,"budget_exhausted")
    // Lost claim replies remain historical success without granting authority.
    replay=lease_invoke(f,claim_raw,"",lease_child(),4000000)
    testing.expect(t,replay.code=="ok" && replay.replay)
    rows,ok:=query(f.store.db,"SELECT (SELECT count(*) FROM local_leases WHERE retired_seq IS NULL),(SELECT count(*) FROM local_work_attempts),(SELECT count(*) FROM local_budget_evidence WHERE json_extract(state_json,'$.reason')='budget_exhausted')")
    testing.expect(t,ok && rows[0][0]=="0" && rows[0][1]=="1" && number(rows[0][2])>0)
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
    budget_expect_test(t,f,5,5,"budget_exhausted")
    // A plain answer does not erase the original grant admission limit.
    testing.expect_value(t,control_call(f,"task.resolve","answer","7").code,"ok")
    testing.expect_value(t,lease_invoke(f,lease_request(f,lease_child(),"lease.claim","answered_but_spent","denied_again","","8"),"",lease_child()).code,"budget_exhausted")
    testing.expect_value(t,control_call(f,"task.cancel","cancel","8").code,"ok")
    testing.expect_value(t,control_call(f,"task.reopen","reopen","9").code,"ok")
    claimed=lease_invoke(f,lease_request(f,lease_child(),"lease.claim","noncounting_recovery","recovered","","10"),"",lease_child())
    testing.expect_value(t,claimed.code,"ok")
    budget_expect_test(t,f,6,5,"")
    rows,ok=query(f.store.db,"SELECT (SELECT count(*) FROM native_history_records),(SELECT count(*) FROM local_work_attempts)")
    testing.expect(t,ok && rows[0][0]=="4" && rows[0][1]=="2","no fabricated migrated attempts or renumbered local ordinals")
}

@(test)
budget_activation_pins_manifest_cutoffs_fences_and_rejects_ambiguous_overlap :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    testing.expect_value(t,native_import_call(f,budget_bundle_test(),"import_budget","4").code,"ok")
    raw:=budget_activation_test(t,f)
    for name in ([7]string{"snapshot_digest","local_cutoff","native_cutoff","event_count","requirements_revision","configuration_revision","execution"}) {
        p,_:=contracts.owner_parse(raw,"budget_activation_payload")
        p[name]=json.String(("other_execution" if name=="execution" else ("0000000000000000000000000000000000000000000000000000000000000000" if name=="snapshot_digest" else "999")))
        body:=encode(p)
        r:=invoke(f,command(f,"budget.activate",fmt.tprintf("bad_%s",name),"task",body,"5"),body)
        testing.expect(t,r.code=="recovery_required" || r.code=="stale_revision")
    }
    // A statement failure leaves the prefix unactivated and claim fail-closed.
    testing.expect(t,exec(f.store.db,"CREATE TRIGGER budget_fail BEFORE INSERT ON local_budget_evidence WHEN NEW.seq>5 BEGIN SELECT RAISE(ABORT,'failure'); END"))
    testing.expect_value(t,invoke(f,command(f,"budget.activate","rollback","task",raw,"5"),raw).code,"storage_error")
    rows,ok:=query(f.store.db,"SELECT count(*) FROM native_budget_baselines")
    testing.expect(t,ok && rows[0][0]=="0")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER budget_fail"))
    testing.expect(t,exec(f.store.db,`CREATE TABLE activation_parent(id INTEGER PRIMARY KEY);
      CREATE TABLE activation_ref(id INTEGER REFERENCES activation_parent(id) DEFERRABLE INITIALLY DEFERRED);
      CREATE TRIGGER activation_commit_fail AFTER INSERT ON native_budget_baselines BEGIN INSERT INTO activation_ref VALUES(1); END;`))
    testing.expect_value(t,invoke(f,command(f,"budget.activate","commit_rollback","task",raw,"5"),raw).code,"storage_error")
    rows,ok=query(f.store.db,"SELECT (SELECT count(*) FROM native_budget_baselines),(SELECT revision FROM tasks WHERE task_id='task')")
    testing.expect(t,ok && rows[0][0]=="0" && rows[0][1]=="5")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER activation_commit_fail"))
    testing.expect_value(t,invoke(f,command(f,"budget.activate","activate","task",raw,"5"),raw).code,"ok")
    // New facts cannot be appended to the now sealed selected snapshot.
    b,_:=contracts.owner_parse(budget_bundle_test(),"native_history_bundle")
    value,_:=contracts.owner_request_document(field(b,"events"));events,_:=value.(json.Array)
    text,_:=events[0].(json.String);e,_:=contracts.owner_parse(string(text),"native_history_event")
    e["event_id"]=json.String("9007199254740996")
    b["events"]=json.String(encode([1]string{encode(e)}));b["attempts"]=json.String("[]")
    testing.expect_value(t,native_import_call(f,encode(b),"sealed","6").code,"operation_conflict")
    g:=fixture(t);defer destroy(g);lifecycle_seed(t,g);cap:=lifecycle_ready(t,g)
    testing.expect_value(t,lifecycle_call(g,lease_child(),"lease.handoff","old_local",`{"requirements_revision":"1","summary":"local work","next_steps":""}`,cap).code,"ok")
    testing.expect_value(t,native_import_call(g,budget_bundle_test(),"disjoint","5").code,"ok")
    body:=budget_activation_test(t,g)
    testing.expect_value(t,invoke(g,command(g,"budget.activate","ambiguous","task",body,"6"),body).code,"recovery_required")
}

@(test)
budget_revisions_preserve_spent_counts_and_incomplete_history_denies_claim :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    p:=encode(doc(map[string]string{"requirements_revision"="2","body_cipher"=cipher(f,`{"goal":"bounded","acceptance":["done"],"budget":{"max_attempts":1}}`)}))
    testing.expect_value(t,invoke(f,command(f,"requirements.edit","budget_one","task",p,"4"),p).code,"ok")
    r:=lease_invoke(f,lease_request(f,lease_child(),"lease.claim","only","only_lease","","5"),"",lease_child())
    if !testing.expect_value(t,r.code,"ok") do return
    budget_expect_test(t,f,1,1,"")
    p=`{"requirements_revision":"2","summary":"continue","next_steps":"later"}`
    testing.expect_value(t,attempt_call_test(f,"lease.handoff","handoff","only_lease",p,result_cap(r),"5").code,"ok")
    r=lease_invoke(f,lease_request(f,lease_child(),"lease.claim","continuation","second_lease","","6"),"",lease_child())
    testing.expect_value(t,r.code,"ok")
    budget_expect_test(t,f,1,1,"")
    testing.expect(t,exec(f.store.db,"CREATE TRIGGER expiry_budget_fail BEFORE INSERT ON local_budget_evidence WHEN json_extract(NEW.state_json,'$.reason')='budget_exhausted' BEGIN SELECT RAISE(ABORT,'failure'); END"))
    testing.expect(t,!expire_leases(&f.store,902000))
    budget_expect_test(t,f,1,1,"")
    testing.expect_value(t,lease_invoke(f,lease_request(f,lease_child(),"lease.claim","failed_expiry_cannot_replace","third_lease","","6",904000),"",lease_child(),902000).code,"operation_conflict")
    testing.expect(t,exec(f.store.db,"DROP TRIGGER expiry_budget_fail"))
    testing.expect(t,expire_leases(&f.store,902000))
    budget_expect_test(t,f,1,1,"budget_exhausted")
    // Editing the brief does not reset the consumed logical count.
    p=encode(doc(map[string]string{"requirements_revision"="3","body_cipher"=cipher(f,`{"goal":"new wording","acceptance":["done"],"budget":{"max_attempts":1}}`)}))
    testing.expect_value(t,invoke(f,command(f,"requirements.edit","same_budget","task",p,"6",904000),p,902000).code,"ok")
    budget_expect_test(t,f,1,1,"budget_exhausted")
    testing.expect_value(t,lease_invoke(f,lease_request(f,lease_child(),"lease.claim","still_denied","third","","7",904000),"",lease_child(),902000).code,"budget_exhausted")
    testing.expect(t,exec(f.store.db,`DROP TRIGGER local_events_no_update;
      UPDATE local_events SET evidence_json='',completeness='legacy_tag',actor_kind='unknown',actor_id='',ts_ms=NULL WHERE kind='lease.claim';
      CREATE TRIGGER local_events_no_update BEFORE UPDATE ON local_events BEGIN SELECT RAISE(ABORT,'immutable event'); END;`))
    testing.expect_value(t,lease_invoke(f,lease_request(f,lease_child(),"lease.claim","incomplete","third","","7",904000),"",lease_child(),902000).code,"recovery_required")
}

@(test)
budget_atomic_switch_rejects_exhausted_destination_without_retiring_source :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f);cap:=lifecycle_ready(t,f);control_destination_seed(t,f)
    bundle,_:=contracts.owner_parse(budget_bundle_test(),"native_history_bundle")
    for kind in ([2]string{"attempt","event"}) {
        plural:=fmt.tprintf("%ss",kind)
        value,_:=contracts.owner_request_document(field(bundle,plural));items,_:=value.(json.Array)
        transformed:=make([dynamic]string,context.temp_allocator)
        for item in items {
            text,_:=item.(json.String);record,_:=contracts.owner_parse(string(text),fmt.tprintf("native_history_%s",kind))
            record["task_id"]=json.String("dest")
            if kind=="attempt" do record["outcome"]=json.String("expired:ttl")
            if kind=="event" && field(record,"kind")=="handoff" {
                record["kind"]=json.String("lease_expired");record["payload_json"]=json.String(`{"lease_id":"native_lease","reason":"ttl"}`)
            }
            append(&transformed,encode(record))
        }
        bundle[plural]=json.String(encode(transformed))
    }
    p:=encode(doc(map[string]string{"body_cipher"=cipher(f,encode(bundle))}))
    testing.expect_value(t,invoke(f,command(f,"native.history.import","dest_history","dest",p,"4"),p).code,"ok")
    digest,counts,valid:=budget_snapshot(&f.store,"chain","dest","budget_snapshot");testing.expect(t,valid)
    checkpoint,_:=query(f.store.db,"SELECT commit_seq FROM runtime_database")
    activation:=contracts.Owner_Budget_Activation_Payload{source_revision="budget_snapshot",snapshot_digest=digest,native_cutoff="9007199254740995",local_cutoff=checkpoint[0][0],
      event_count=fmt.tprintf("%d",counts[1]),attempt_count=fmt.tprintf("%d",counts[0]),facet_count=fmt.tprintf("%d",counts[2]),requirements_revision="1",configuration_revision="1",execution="standalone",source_gate="0",source_no_review="0"}
    p=encode(activation)
    testing.expect_value(t,invoke(f,command(f,"budget.activate","dest_baseline","dest",p,"5"),p).code,"ok")
    p=control_switch_payload("6")
    testing.expect_value(t,lifecycle_call(f,lease_child(),"lease.switch","exhausted_destination",p,cap).code,"budget_exhausted")
    rows,ok:=query(f.store.db,"SELECT (SELECT count(*) FROM local_leases WHERE lease_id='lease' AND retired_seq IS NULL),(SELECT count(*) FROM local_leases WHERE task_id='dest'),(SELECT count(*) FROM local_handoffs WHERE kind='lease.switch')")
    testing.expect(t,ok && rows[0][0]=="1" && rows[0][1]=="0" && rows[0][2]=="0")
    budget_expect_test(t,f,1,1,"")
}
