#+feature dynamic-literals
package owner_local

import "core:fmt"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"

// Fleet management on an owner chain (user decision): the chain's bound
// coordinator enrolls, re-roles and removes workers and reviewers, sets the
// fleet policy and controls its agents' instances. It never grants the
// coordinator role, never touches its own membership, and grants stay human.

fleet_worker_child :: proc() -> Child { return {"fleet_instance","fleet_epoch",strings.repeat("e",64,context.temp_allocator),1,"fleet_agent"} }

fleet_member_payload :: proc(child:Child,role:string,enabled:="1") -> string {
    return encode(doc(map[string]string{"instance_id"=child.instance,"agent_id"=child.agent_id,"role"=role,"enabled"=enabled}))
}
// chain.member.set as the owner Bridge submits it for `agent`, with the
// Bridge-observed live child of the target instance.
fleet_member_call :: proc(f:^Fixture,agent,observed:Child,op,payload:string) -> Result {
    raw:=agent_command(f,agent,"chain.member.set",op,"",payload,agent_chain_rev(f))
    return execute_agent(&f.store,raw,payload,agent,f.owner,1000,&f.kr,Signer{&f.owner_priv,test_sign},fleet_child=observed)
}
fleet_policy_payload_for :: proc(f:^Fixture,agent,roles,paused:string) -> string {
    policy:=contracts.Owner_Fleet_Policy{task_chain_id="chain",agent_id=agent,capacity=2,min_warm=1,idle_ttl_seconds=600,provider="claude",model="sonnet",
        roles_json=roles,paused_roles_json=paused,bridge_id="bridge",created_at="2026-01-01T00:00:00Z",updated_at="2026-01-02T00:00:00Z"}
    return encode(doc(map[string]string{"body_cipher"=cipher(f,encode(policy))}))
}
fleet_scalar :: proc(f:^Fixture,sql:string) -> string {
    rows,_:=query(f.store.db,sql)
    return rows[0][0] if len(rows)==1 else ""
}

@(test)
fleet_coordinator_enrolls_members_sets_policy_and_keeps_the_limits :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    coord:=agent_coordinator_child();agent_seat_coordinator(t,f,coord)
    fleet,worker,reviewer,stranger:=fleet_worker_child(),lease_child(),lifecycle_reviewer(),agent_stranger()
    agent_add_task(t,f,"fleet_task")
    assign:=encode(doc(map[string]string{"instance_id"=fleet.instance,"configuration_revision"="1","enabled"="1"}))
    assign_call :: proc(f:^Fixture,coord,fleet:Child,op,payload:string) -> Result {
        raw:=agent_command(f,coord,"fleet.edit",op,"fleet_task",payload,agent_task_revision(f,"fleet_task"))
        return execute_agent(&f.store,raw,payload,coord,f.owner,1000,&f.kr,Signer{&f.owner_priv,test_sign},fleet_child=fleet)
    }
    // Assignment stays limited to participants of this chain...
    testing.expect_value(t,assign_call(f,coord,fleet,"assign_outsider",assign).code,"invalid_scope")
    // ...and the coordinator enrolls the agent itself (with a registry republish).
    intents:=fleet_scalar(f,"SELECT count(*) FROM runtime_intents WHERE kind='registry.prepare'")
    testing.expect_value(t,fleet_member_call(f,coord,fleet,"enroll",fleet_member_payload(fleet,"worker")).code,"ok")
    testing.expect(t,fleet_scalar(f,"SELECT count(*) FROM runtime_intents WHERE kind='registry.prepare'")!=intents,"membership change republishes registry_members")
    testing.expect_value(t,fleet_scalar(f,"SELECT actor_kind||':'||actor_id FROM local_events WHERE kind='chain.member.set' ORDER BY seq DESC LIMIT 1"),"agent:coord_instance")
    testing.expect_value(t,assign_call(f,coord,fleet,"assign_member",assign).code,"ok")
    // Re-role (reviewer, a review role) and remove; a disabled row needs no live child.
    testing.expect_value(t,fleet_member_call(f,coord,fleet,"rerole",fleet_member_payload(fleet,"security")).code,"ok")
    testing.expect_value(t,fleet_member_call(f,coord,{},"remove",fleet_member_payload(fleet,"security","0")).code,"ok")
    testing.expect_value(t,fleet_scalar(f,"SELECT enabled FROM local_chain_member_versions WHERE instance_id='fleet_instance' ORDER BY accepted_seq DESC LIMIT 1"),"0")
    // An enabled row needs the Bridge-observed live child of that instance.
    testing.expect_value(t,fleet_member_call(f,coord,{},"no_child",fleet_member_payload(fleet,"worker")).code,"invalid_scope")

    // Never the coordinator role, never itself (remove, disable, demote).
    other:=Child{"other_instance","other_epoch",strings.repeat("f",64,context.temp_allocator),1,"other_agent"}
    testing.expect_value(t,fleet_member_call(f,coord,other,"grant_coord",fleet_member_payload(other,"coordinator")).code,"invalid_scope")
    testing.expect_value(t,fleet_member_call(f,coord,coord,"self_demote",fleet_member_payload(coord,"worker")).code,"invalid_scope")
    testing.expect_value(t,fleet_member_call(f,coord,coord,"self_disable",fleet_member_payload(coord,"coordinator","0")).code,"invalid_scope")
    testing.expect(t,agent_coordinator(&f.store,"chain",coord),"the coordinator keeps its seat")
    // Workers, reviewers and strangers never manage the fleet.
    for who in ([3]Child{worker,reviewer,stranger}) {
        testing.expectf(t,fleet_member_call(f,who,other,fmt.tprintf("%s_enroll",who.instance),fleet_member_payload(other,"worker")).code=="invalid_scope","%s cannot enroll",who.instance)
        r:=agent_run(f,who,"fleet.policy.set",fmt.tprintf("%s_policy",who.instance),"",fleet_policy_payload_for(f,"other_agent",`["worker"]`,""),agent_chain_rev(f))
        testing.expectf(t,r.code=="invalid_scope","%s cannot set fleet policy",who.instance)
    }
    // Grants stay human-only.
    grant:=encode(doc(map[string]string{"principal_id"="device","key_id"="device"}))
    testing.expect_value(t,agent_run(f,coord,"grant.revoke","coord_grant","",grant,agent_chain_rev(f)).code,"invalid_scope")

    // Fleet policy rows: provider/model/bridge/capacity/min-warm/idle-ttl, pause and resume.
    testing.expect_value(t,agent_run(f,coord,"fleet.policy.set","policy","",fleet_policy_payload_for(f,"other_agent",`["worker","reviewer"]`,""),agent_chain_rev(f)).code,"ok")
    testing.expect_value(t,agent_run(f,coord,"fleet.policy.set","pause","",fleet_policy_payload_for(f,"other_agent",`["worker","reviewer"]`,`["*"]`),agent_chain_rev(f)).code,"ok")
    policy,found,ok:=agent_fleet_policy(&f.store,"chain","other_agent")
    testing.expect(t,ok && found && policy.capacity==2 && policy.min_warm==1 && policy.provider=="claude" && policy.model=="sonnet" && policy.bridge_id=="bridge" && policy.paused_roles_json==`["*"]`)
    role,_:=agent_authorize_locked(&f.store,"chain","",coord,"fleet.policy.read")
    testing.expect_value(t,role,Agent_Role.Coordinator)
    policies,members,viewed:=agent_fleet_view(&f.store,"chain")
    testing.expect(t,viewed && len(policies)==1 && len(members)==2,"one policy row; the coordinator and the removed fleet member")

    // A solo row for itself: its own agent's unpaused worker policy.
    _,solo:=agent_solo_standing(&f.store,"chain",coord)
    testing.expect(t,!solo,"no solo row yet")
    testing.expect_value(t,agent_run(f,coord,"fleet.policy.set","solo","",fleet_policy_payload_for(f,coord.agent_id,`["worker"]`,""),agent_chain_rev(f)).code,"ok")
    _,solo=agent_solo_standing(&f.store,"chain",coord)
    testing.expect(t,solo,"its own worker policy row makes the coordinator solo")
    testing.expect_value(t,agent_run(f,coord,"fleet.policy.set","solo_pause","",fleet_policy_payload_for(f,coord.agent_id,`["worker"]`,`["worker"]`),agent_chain_rev(f)).code,"ok")
    _,solo=agent_solo_standing(&f.store,"chain",coord)
    testing.expect(t,!solo,"a paused solo row is not solo")

    // A coordinator of another chain (lifetime binding) is foreign here.
    testing.expect(t,exec(f.store.db,"INSERT INTO task_chains VALUES('elsewhere','device','device','t','d',1); DROP TRIGGER local_member_chains_no_update; UPDATE local_member_chains SET chain_id='elsewhere' WHERE instance_id='coord_instance';"))
    testing.expect_value(t,fleet_member_call(f,coord,other,"foreign_enroll",fleet_member_payload(other,"worker")).code,"invalid_scope")
    testing.expect_value(t,agent_run(f,coord,"fleet.policy.set","foreign_policy","",fleet_policy_payload_for(f,"other_agent",`["worker"]`,""),agent_chain_rev(f)).code,"invalid_scope")
}

@(test)
fleet_instance_control_is_the_chain_coordinators_and_never_stops_itself :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    coord:=agent_coordinator_child();agent_seat_coordinator(t,f,coord)
    fleet:=fleet_worker_child()
    testing.expect_value(t,fleet_member_call(f,coord,fleet,"enroll",fleet_member_payload(fleet,"worker")).code,"ok")
    chains,ok:=agent_instance_chains(&f.store,"fleet_instance")
    testing.expect(t,ok && len(chains)==1 && chains[0]=="chain")
    chains,ok=agent_instance_chains(&f.store,"instance") // a task fleet worker
    testing.expect(t,ok && len(chains)==1 && chains[0]=="chain")
    chains,ok=agent_instance_chains(&f.store,"unrelated")
    testing.expect(t,ok && len(chains)==0)
    for verb in ([3]string{"start","stop","restart"}) {
        testing.expectf(t,agent_instance_control(&f.store,"chain","fleet_instance",verb,coord)=="ok","coordinator may %s its agent",verb)
        for who in ([3]Child{lease_child(),fleet,agent_stranger()}) {
            testing.expectf(t,agent_instance_control(&f.store,"chain","fleet_instance",verb,who)=="invalid_scope","%s may not %s",who.instance,verb)
        }
    }
    testing.expect_value(t,agent_instance_control(&f.store,"chain","coord_instance","stop",coord),"invalid_scope")
    testing.expect_value(t,agent_instance_control(&f.store,"chain","coord_instance","restart",coord),"ok")
    testing.expect_value(t,agent_instance_control(&f.store,"missing","fleet_instance","stop",coord),"invalid_scope")
    testing.expect_value(t,agent_instance_control(&f.store,"chain","unrelated","stop",coord),"invalid_scope")
}
