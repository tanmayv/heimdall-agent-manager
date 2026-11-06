#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"

human_gate_revision :: proc(f:^Fixture,task:string)->string {
    rows,_:=query(f.store.db,"SELECT revision FROM tasks WHERE chain_id='chain' AND task_id=?",task)
    return rows[0][0]
}
human_gate_bind :: proc(t:^testing.T,f:^Fixture,task:string,git:bool) {
    child:=lease_child()
    payload:=encode(doc(map[string]string{"instance_id"=child.instance,"configuration_revision"="1","enabled"="1"}))
    testing.expect_value(t,execute(&f.store,command(f,"fleet.edit","gate_fleet",task,payload,human_gate_revision(f,task)),payload,"",f.creator,f.owner,1,"head",1000,&f.kr,Signer{&f.owner_priv,test_sign},child).code,"ok")
    config:=doc(map[string]string{"configuration_revision"="1","author_agent_id"="author","reviewer_agent_id"="reviewer","reviewer_instance_id"="review_instance","directory_id"="directory","merge_policy"="none","repository"="","worktree"="","source_branch"="","target_branch"="","base_head"=""})
    if git {
        config["merge_policy"]=json.String("git");config["repository"]=json.String("/repo");config["worktree"]=json.String("/repo/.heimdall/worktrees/task")
        config["source_branch"]=json.String("heimdall/task");config["target_branch"]=json.String("target");config["base_head"]=json.String(strings.repeat("b",40,context.temp_allocator))
    }
    payload=encode(config)
    testing.expect_value(t,execute(&f.store,command(f,"lifecycle.configure","gate_config",task,payload,human_gate_revision(f,task)),payload,"",f.creator,f.owner,1,"head",1000,&f.kr,Signer{&f.owner_priv,test_sign},{},Lifecycle_Proof{child,lifecycle_reviewer(),true}).code,"ok")
}

@(test)
language_submitted_human_approval_fences_ordinary_static_merge_and_sibling :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    for ordinary in ([2]bool{true,false}) {
        for git in ([2]bool{false,true}) {
            f:=fixture(t);defer destroy(f);seed(t,f)
            testing.expect_value(t,language_test_define(f,"follow",`{"schema":"workflow.v1","stages":[{"key":"follow","title":"Follow {{inputs.summary}}","brief":{"goal":"Follow","acceptance":["done"]}}]}`).code,"ok")
            brief:=`{"goal":"Human-gated producer","acceptance":["done"],"requires_user_approval":true,"on_output":{"workflow":"follow","inputs":{"summary":"{{output.summary}}"}}}`
            task:="task"
            if ordinary {
                payload:=encode(doc(map[string]string{"requirements_revision"="1","body_cipher"=cipher(f,brief)}))
                testing.expect_value(t,invoke(f,command(f,"requirements.edit","human_gate_brief",task,payload,"1"),payload).code,"ok")
            } else {
                stage:=doc(map[string]string{"key"="source","title"="Human-gated static source","body"="Source","brief"=brief,"depends_on"="[]"})
                definition:=encode(doc(map[string]string{"workflow_id"="static","version"="1","title"="Static","stages"=encode([1]json.Object{stage})}))
                testing.expect_value(t,advanced_call(f,"workflow.define","static_define",definition).code,"ok")
                testing.expect_value(t,advanced_call(f,"workflow.run","static_run",`{"run_id":"producer","workflow_id":"static","version":"1"}`).code,"ok")
                task=workflow_task_id("chain","producer","1","source")
            }
            human_gate_bind(t,f,task,git)
            claim:=workflow_lease_raw(f,task,"gate_lease","gate_claim")
            c,_:=contracts.owner_parse(claim,"lease_command")
            c["expected_revision"]=json.String(human_gate_revision(f,task))
            sig,_:=test_sign(&f.owner_priv,"lease_command",c);c["signature"]=json.String(sig)
            claimed:=lease_invoke(f,encode(c),"",lease_child())
            if !testing.expect_value(t,claimed.code,"ok") do return
            cap:=result_cap(claimed)
            for method in ([2]string{"requirements.present","requirements.ack"}) {
                testing.expect_value(t,language_child_call(f,task,"gate_lease",lease_child(),method,method,`{"requirements_revision":"1"}`,cap).code,"ok")
            }
            head:=""
            if git do head=strings.repeat("a",40,context.temp_allocator)
            payload:=encode(doc(map[string]string{"requirements_revision"="1","head"=head,"summary"="Done","output"=`{"summary":"human-bound"}`}))
            raw:=language_child_raw(f,task,"gate_lease",lease_child(),"lease.submit","gate_submit",payload,cap)
            testing.expect_value(t,execute_lifecycle(&f.store,raw,payload,cap,lease_child(),f.owner,1000,Signer{&f.owner_priv,test_sign},Source_Proof{head,true}).code,"ok")
            verdict:=lifecycle_verdict(head)
            opened:=language_child_call(f,task,"gate_lease",lifecycle_reviewer(),"review.open","gate_review_open",verdict,"")
            if !testing.expect_value(t,opened.code,"ok") do return
            testing.expect_value(t,language_child_call(f,task,"gate_lease",lifecycle_reviewer(),"review.post","gate_agent_approve",verdict,result_cap(opened)).code,"ok")
            rows,ok:=query(f.store.db,"SELECT state,(SELECT count(*) FROM runtime_intents WHERE kind='merge'),(SELECT count(*) FROM local_workflow_output_triggers) FROM lifecycle_state WHERE task_id=?",task)
            testing.expect(t,ok && rows[0][0]=="in_review" && rows[0][1]=="0" && rows[0][2]=="0",fmt.tprintf("agent must not release ordinary=%v git=%v",ordinary,git))
            coordinator:=lease_child();coordinator.instance="coord_instance";coordinator.agent_id="coordinator"
            binding:=coordinator_test_config(f,coordinator,"1","human_gate_coordinator")
            if !testing.expect_value(t,binding.code,"ok") do return
            gate_payload:=`{"run_id":"producer","execution":"1","stage_key":"source","verdict":"approve","summary":"Coordinator cannot replace human"}`
            gate_raw:=coordinator_test_raw(f,task,"coordinator_gate_bypass",gate_payload,result_cap(binding),coordinator)
            testing.expect_value(t,execute_lifecycle(&f.store,gate_raw,gate_payload,result_cap(binding),coordinator,f.owner,1000,Signer{&f.owner_priv,test_sign}).code,"invalid_scope")
            testing.expect_value(t,language_child_call(f,task,"gate_lease",coordinator,"review.post","coordinator_review_bypass",verdict,result_cap(opened)).code,"invalid_scope")
            close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
            rows,ok=query(f.store.db,"SELECT state,(SELECT count(*) FROM local_workflow_output_triggers) FROM lifecycle_state WHERE task_id=?",task)
            testing.expect(t,ok && rows[0][0]=="in_review" && rows[0][1]=="0")
            human_raw:=command(f,"review.post","human_gate_approve",task,verdict,human_gate_revision(f,task))
            approved:=invoke(f,human_raw,verdict)
            if !testing.expect_value(t,approved.code,"ok") do return
            rows,ok=query(f.store.db,"SELECT state FROM lifecycle_state WHERE task_id=?",task)
            testing.expect(t,ok && rows[0][0]==("merge_pending" if git else "done"))
            if git {
                claims,read:=intent_claim_due(&f.store,1000)
                testing.expect(t,read)
                merge:Intent_Claim
                for claim in claims { if claim.kind=="merge" do merge=claim }
                if !testing.expect(t,merge.id!="") do return
                rows,_=query(f.store.db,"SELECT count(*) FROM local_workflow_output_triggers")
                testing.expect_value(t,rows[0][0],"0")
                testing.expect(t,merge_prepare(&f.store,merge,head))
                testing.expect(t,intent_result(&f.store,merge,true,head,1000))
            }
            for _ in 0..<2 {
                replay:=invoke(f,human_raw,verdict)
                testing.expect(t,replay.code=="ok" && replay.replay && replay.body==approved.body)
                close(&f.store);testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key"))
                rows,ok=query(f.store.db,"SELECT target_run,consumed FROM local_workflow_output_triggers WHERE source_task=?",task)
                if !testing.expect(t,ok && len(rows)==1 && rows[0][1]=="1") do return
                follow:=language_tasks(f,rows[0][0],"1","follow")
                if testing.expect_value(t,len(follow),1) do testing.expect_value(t,follow[0][1],"Follow human-bound")
            }
        }
    }
}
