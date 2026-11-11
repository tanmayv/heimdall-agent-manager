#+feature dynamic-literals
package main

// Fleet management by the coordinator of a chain this Bridge owns (user
// decision: Hub-chain parity). `ham-ctl task-chain fleet list|set|pause|
// resume|remove` reach the Bridge as agent.task_chain.fleet_*; `ham-ctl agents
// start|stop|restart <inst>` for an instance of an owner chain are gated here
// and then relayed to the Hub with the caller's own token.
//
// Authority is the owner store's (agent_authority.odin): only the chain's
// bound coordinator (exact live child) manages the fleet; it enrolls worker
// members, which tasks then assign or name as reviewers (--reviewer) (never
// the coordinator role), never removes, disables or
// demotes itself, never stops itself; grants stay human-only.
//
// `fleet set` writes the fleet policy row (fleet.policy.set) and, when the
// agent has no enabled member here, launches it on THIS Bridge into the chain
// (Hub POST /agent-instances with chain_id + bridge_id and the caller's token),
// waits with no locks held for the live child, then binds it as an enabled
// member (chain.member.set with the Bridge-observed child), which republishes
// registry_members. A task assigned to the agent then resolves to that member
// (bridge_owner_resolve_agent) and dispatches through its fleet row.
//
// Lock order: bridge_owner_mutex -> bridge_startup_io_mutex ->
// bridge_local_token_mutex; the launch wait holds none of them.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import contracts "odin_test:contracts"
import owner "odin_test:lib/owner_local"
import vault "odin_test:lib/vault"

bridge_owner_fleet_method :: proc(method:string) -> bool {
    switch method {
    case "agent.task_chain.fleet_list","agent.task_chain.fleet_set","agent.task_chain.fleet_pause","agent.task_chain.fleet_resume","agent.task_chain.fleet_remove": return true
    }
    return false
}

// agent.agents.instance_* -> start|stop|restart ("" for any other method).
bridge_owner_instance_verb :: proc(method:string) -> string {
    switch method {
    case "agent.agents.instance_start": return "start"
    case "agent.agents.instance_stop": return "stop"
    case "agent.agents.instance_restart": return "restart"
    }
    return ""
}

// A launch decided under the locks and finished after them.
Owner_Fleet_Launch :: struct {
    active:bool,
    chain,agent,role,body:string,
    reply:json.Object, // the policy result, completed with the instance
    // A dedicated member for a task's provider/model on an EXISTING row: a
    // refused verb stops its instance but never pauses the row.
    dedicated:bool,
}

// `agents start|stop|restart <inst>`: an instance of a chain this Bridge owns
// may be controlled only by that chain's coordinator. Allowed calls return
// handled=false so the ordinary Hub relay runs with the caller's own token;
// instances of no owner chain keep the Hub behaviour unchanged.
bridge_owner_instance_gate :: proc(request_id,verb,params:string,rec:Bridge_Local_Agent_Token_Record) -> (string,bool) {
    target:=bridge_agent_instance_id(params)
    if target=="" do return "",false
    account:=bridge_enrolled_owner_user_id(bridge_cfg().daemon_id)
    if account=="" do return "",false
    key_id,key_ok:=vault.device_id_from_sign_pub(bridge_identity_public_key_hex(bridge_cfg().daemon_id),context.temp_allocator)
    if !key_ok do return "",false
    sync.mutex_lock(&bridge_owner_mutex);defer sync.mutex_unlock(&bridge_owner_mutex)
    if bridge_owner_store.db==nil {
        path:=bridge_owner_store_path(account)
        if path=="" || !os.exists(path) do return "",false
    }
    if !bridge_owner_open(account,key_id) do return bridge_local_response_error(request_id,"storage_error","owner store unavailable"),true
    chains,ok:=owner.agent_instance_chains(&bridge_owner_store,target)
    if !ok do return bridge_local_response_error(request_id,"storage_error","owner store could not be read; retry"),true
    if len(chains)==0 do return "",false
    refused:=fmt.tprintf("agents %s %s: only the coordinator of chain %s may start, stop or restart its agents (and it never stops itself)",verb,target,chains[0])
    if len(chains)>1 do return bridge_local_response_error(request_id,"invalid_scope",refused),true
    sync.mutex_lock(&bridge_startup_io_mutex)
    sync.mutex_lock(&bridge_local_token_mutex)
    child,current:=bridge_owner_child_locked(rec.agent_instance_id,rec.token_hash)
    sync.mutex_unlock(&bridge_local_token_mutex)
    sync.mutex_unlock(&bridge_startup_io_mutex)
    if !current do return bridge_local_response_error(request_id,"invalid_scope","owner chain: current launched child required"),true
    code:=owner.agent_instance_control(&bridge_owner_store,chains[0],target,verb,child)
    if code=="storage_error" do return bridge_local_response_error(request_id,code,"owner store could not be read; retry"),true
    if code!="ok" do return bridge_local_response_error(request_id,code,refused),true
    return "",false
}

bridge_owner_fleet_chain :: proc(ctx:^Owner_Agent_Ctx,p:json.Object) -> string {
    chain:=bridge_owner_pstr(p,"chain_id")
    if chain=="" do chain=owner.agent_home_chain(ctx.store,ctx.child)
    return chain
}

// Coordinator-only (re-checked by the store on every write).
bridge_owner_fleet_authorize :: proc(ctx:^Owner_Agent_Ctx,chain:string) -> string {
    role,code:=owner.agent_authorize_locked(ctx.store,chain,"",ctx.child,"fleet.policy.read")
    if role==.Coordinator do return ""
    if code=="storage_error" do return bridge_owner_fail(ctx,code,"owner store could not be read; retry")
    return bridge_owner_fail(ctx,"invalid_scope","task-chain fleet: only this chain's coordinator manages its fleet")
}

// Fleet rows are worker rows: a task names its reviewer agents in
// brief.reviewers, so a row carries no other role and
// pause/resume act on the whole row.
BRIDGE_OWNER_FLEET_ROLES :: `["worker"]`

bridge_owner_fleet_role_list :: proc(raw:string,paused:bool) -> []string {
    roles,_:=contracts.owner_fleet_roles(raw,paused)
    return roles
}

// The roles a policy row serves now (roles minus paused ones).
bridge_owner_fleet_active_roles :: proc(policy:contracts.Owner_Fleet_Policy) -> []string {
    paused:=bridge_owner_fleet_role_list(policy.paused_roles_json,true)
    if slice.contains(paused,"*") do return nil
    out:=make([dynamic]string,context.temp_allocator)
    for role in bridge_owner_fleet_role_list(policy.roles_json,false) do if !slice.contains(paused,role) do append(&out,role)
    return out[:]
}

bridge_owner_fleet_now :: proc(ctx:^Owner_Agent_Ctx) -> string { return action_scheduler_format_rfc3339_utc(ctx.now) }

// fleet.policy.set of a whole row, signed for the coordinator.
bridge_owner_fleet_write :: proc(ctx:^Owner_Agent_Ctx,chain:string,policy:contracts.Owner_Fleet_Policy) -> (string,string) {
    raw:=bridge_owner_json(policy)
    if _,valid:=contracts.owner_fleet_policy_parse(raw);!valid do return "bad_request","invalid fleet row (capacity >= 1, min-warm/idle-ttl >= 0, roles a-z0-9_-, a provider with a profile)"
    body,sealed:=bridge_owner_cipher(ctx,raw)
    if !sealed do return "vault_locked","cannot seal the fleet row"
    r:=bridge_owner_run_command(ctx,"fleet.policy.set",chain,"",bridge_owner_chain_rev(ctx,chain),bridge_owner_json(map[string]string{"body_cipher"=body}))
    if r.code!="ok" do return r.code,"fleet policy refused by the owner store"
    return "ok",""
}

// chain.member.set for the coordinator; fleet_child is the observed live child
// for an enabled row (unused for a removal).
bridge_owner_fleet_member :: proc(ctx:^Owner_Agent_Ctx,chain,instance,agent,role:string,enabled:bool,child:owner.Child={}) -> owner.Result {
    payload:=bridge_owner_json(map[string]string{"instance_id"=instance,"agent_id"=agent,"role"=role,"enabled"=("1" if enabled else "0")})
    return bridge_owner_run_command(ctx,"chain.member.set",chain,"",bridge_owner_chain_rev(ctx,chain),payload,fleet_child=child)
}

Owner_Fleet_Member_View :: struct { instance_id,agent_id,role:string, enabled,running:bool }

bridge_owner_fleet_members :: proc(ctx:^Owner_Agent_Ctx,chain:string) -> ([]Owner_Fleet_Member_View,bool) {
    _,members,ok:=owner.agent_fleet_view(ctx.store,chain)
    if !ok do return nil,false
    out:=make([]Owner_Fleet_Member_View,len(members),context.temp_allocator)
    for m,i in members {
        _,live:=bridge_owner_child_locked(m.instance_id,"")
        out[i]={m.instance_id,m.agent_id,m.role,m.enabled=="1",live}
    }
    return out,true
}

// Caller holds the owner, startup and token locks (bridge_owner_agent_exec).
bridge_owner_fleet :: proc(ctx:^Owner_Agent_Ctx,method:string,p:json.Object) -> string {
    chain:=bridge_owner_fleet_chain(ctx,p)
    if chain=="" do return bridge_owner_fail(ctx,"bad_request","task-chain fleet: name the chain (<chain-id>)")
    if refused:=bridge_owner_fleet_authorize(ctx,chain);refused!="" do return refused
    if method=="agent.task_chain.fleet_list" {
        policies,_,ok:=owner.agent_fleet_view(ctx.store,chain)
        members,read:=bridge_owner_fleet_members(ctx,chain)
        if !ok || !read do return bridge_owner_fail(ctx,"storage_error","owner store could not be read; retry")
        Fleet_List :: struct { chain_id:string, fleet:[]contracts.Owner_Fleet_Policy, members:[]Owner_Fleet_Member_View, authority:Owner_Agent_Authority }
        return bridge_local_response_data(ctx.request_id,bridge_owner_json(Fleet_List{chain,policies,members,bridge_owner_authority()}))
    }
    agent:=bridge_owner_pstr(p,"agent_id")
    if !contracts.owner_field_valid(agent,"id") do return bridge_owner_fail(ctx,"bad_request","task-chain fleet: --agent <agt_id> is required")
    policy,found,ok:=owner.agent_fleet_policy(ctx.store,chain,agent)
    if !ok do return bridge_owner_fail(ctx,"storage_error","owner store could not be read; retry")
    reply:=make(json.Object,context.temp_allocator)
    reply["chain_id"]=json.String(chain);reply["agent_id"]=json.String(agent);reply["authority"]=json.Object{"kind"=json.String("owner"),"bridge_id"=json.String(bridge_cfg().daemon_id)}
    switch method {
    case "agent.task_chain.fleet_pause","agent.task_chain.fleet_resume":
        if !found do return bridge_owner_fail(ctx,"not_found",fmt.tprintf("no fleet row for %s in this chain; add it with `task-chain fleet set --agent %s`",agent,agent))
        if _,named:=p["roles"];named do return bridge_owner_fail(ctx,"bad_request","task-chain fleet: --roles was removed (fleet rows are worker rows; name reviewers per task with --reviewer)")
        policy.paused_roles_json=`["*"]` if method=="agent.task_chain.fleet_pause" else ""
        policy.updated_at=bridge_owner_fleet_now(ctx)
        if code,message:=bridge_owner_fleet_write(ctx,chain,policy);code!="ok" do return bridge_owner_fail(ctx,code,message)
        reply["fleet"]=bridge_owner_result_object(bridge_owner_json(policy))
        reply["note"]=json.String("pause/resume record the row's dispatch state; live leases continue")
        return bridge_local_response_data(ctx.request_id,bridge_owner_json(reply))
    case "agent.task_chain.fleet_remove":
        members,read:=bridge_owner_fleet_members(ctx,chain)
        if !read do return bridge_owner_fail(ctx,"storage_error","owner store could not be read; retry")
        removed:=make([dynamic]string,context.temp_allocator)
        for m in members {
            // The coordinator never removes itself (nor another coordinator).
            if m.agent_id!=agent || !m.enabled || m.instance_id==ctx.child.instance || m.role=="coordinator" do continue
            r:=bridge_owner_fleet_member(ctx,chain,m.instance_id,m.agent_id,m.role,false)
            if r.code!="ok" do return bridge_owner_fail(ctx,r.code,fmt.tprintf("removing member %s was refused",m.instance_id))
            append(&removed,m.instance_id)
        }
        if found && !strings.contains(policy.paused_roles_json,`"*"`) {
            policy.paused_roles_json=`["*"]`;policy.updated_at=bridge_owner_fleet_now(ctx)
            if code,message:=bridge_owner_fleet_write(ctx,chain,policy);code!="ok" do return bridge_owner_fail(ctx,code,message)
        }
        if !found && len(removed)==0 do return bridge_owner_fail(ctx,"not_found",fmt.tprintf("%s has no fleet row or removable member in this chain (the coordinator never removes itself)",agent))
        list:=make(json.Array,0,len(removed),context.temp_allocator)
        for r in removed do append(&list,json.String(r))
        reply["removed_instances"]=list
        reply["note"]=json.String("removed members stay bound to this chain for life; stop their instances with `ham-ctl agents stop <inst>`")
        return bridge_local_response_data(ctx.request_id,bridge_owner_json(reply))
    }
    // agent.task_chain.fleet_set
    // ensure (task create/update, bridge_owner_task_fleet_ensure): an agent
    // that already has a row keeps it untouched.
    // A task whose selection for this agent (its override, else the row) no
    // live member runs gets a dedicated member launched with it, so the task
    // route binds a matching instance (owner_task_models.odin); a stopped or
    // pending member is waited for, never duplicated.
    ensure_models:=bridge_owner_fleet_ensure_models(ctx,chain,agent,p)
    if found && bridge_owner_pstr(p,"ensure")=="1" {
        if bridge_owner_fleet_ensure_dedicated(ctx,chain,agent,p,ensure_models) {
            role:="worker"
            reply["role"]=json.String(role)
            reply["note"]=json.String("dedicated member for the task's provider/model")
            body:=map[string]string{"agent_id"=agent,"chain_id"=chain,"bridge_id"=bridge_cfg().daemon_id}
            bridge_owner_launch_body_model(&body,policy,bridge_cfg().daemon_id,agent,ensure_models)
            ctx.launch=Owner_Fleet_Launch{true,chain,agent,role,bridge_owner_json(body),reply,true}
            return ""
        }
        reply["note"]=json.String("fleet row exists")
        return bridge_local_response_data(ctx.request_id,bridge_owner_json(reply))
    }
    if !found {
        policy=contracts.Owner_Fleet_Policy{task_chain_id=chain,agent_id=agent,capacity=1,idle_ttl_seconds=600,roles_json=BRIDGE_OWNER_FLEET_ROLES,created_at=bridge_owner_fleet_now(ctx)}
    }
    number :: proc(p:json.Object,key:string,min:i64,out:^i64) -> bool {
        raw:=bridge_owner_pstr(p,key)
        if raw=="" do return true
        n,parsed:=strconv.parse_i64(raw)
        if !parsed || n<min do return false
        out^=n
        return true
    }
    if !number(p,"capacity",1,&policy.capacity) || !number(p,"min_warm",0,&policy.min_warm) || !number(p,"idle_ttl_seconds",0,&policy.idle_ttl_seconds) {
        return bridge_owner_fail(ctx,"bad_request","task-chain fleet set: --capacity >= 1, --min-warm and --idle-ttl >= 0")
    }
    if "provider" in p do policy.provider=bridge_owner_pstr(p,"provider")
    if "model" in p do policy.model=bridge_owner_pstr(p,"model")
    if "provider_profile" in p do policy.provider_profile=bridge_owner_pstr(p,"provider_profile")
    if "bridge_id" in p do policy.bridge_id=bridge_owner_pstr(p,"bridge_id")
    if "bridge_models_json" in p do policy.bridge_models_json=bridge_owner_pstr(p,"bridge_models_json")
    if _,named:=p["roles"];named do return bridge_owner_fail(ctx,"bad_request","task-chain fleet set: --roles was removed (fleet rows are worker rows; name reviewers per task with --reviewer)")
    policy.roles_json=BRIDGE_OWNER_FLEET_ROLES
    policy.updated_at=bridge_owner_fleet_now(ctx)
    if code,message:=bridge_owner_fleet_write(ctx,chain,policy);code!="ok" do return bridge_owner_fail(ctx,code,message)
    reply["fleet"]=bridge_owner_result_object(bridge_owner_json(policy))
    // Launch (or bind a named instance) only when the agent has no enabled
    // member here and the row serves a role now on this Bridge.
    active:=bridge_owner_fleet_active_roles(policy)
    note:=""
    members,read:=bridge_owner_fleet_members(ctx,chain)
    if !read do return bridge_owner_fail(ctx,"storage_error","owner store could not be read; retry")
    if agent==ctx.child.agent_id {
        note="solo row: you work this agent's tasks yourself; nothing launched"
    } else {
        for m in members {
            if m.agent_id!=agent || !m.enabled do continue
            // A running member with another provider/model than the task's is not this task's.
            if m.running && !bridge_owner_instance_serves(ctx.store,chain,m.instance_id,agent,ensure_models) do continue
            reply["instance_id"]=json.String(m.instance_id)
            note=fmt.tprintf("already a member: %s (%s)",m.instance_id,"running" if m.running else "stopped; `ham-ctl agents start` it")
            break
        }
    }
    switch {
    case note!="":
    case policy.bridge_id!="" && policy.bridge_id!=bridge_cfg().daemon_id: note=fmt.tprintf("placement on %s recorded; nothing launched here: a task assigned to %s is reserved on %s (owner_remote_place.odin)",policy.bridge_id,agent,policy.bridge_id)
    case len(active)==0: note="the row is paused; nothing launched"
    // ensure for a task whose run Bridge is another Bridge: its assignee is
    // reserved there (owner_remote_place.odin) and its reviewers are launched
    // there for review (owner_agent_review.odin), never launched here.
    case bridge_owner_fleet_ensure_run_bridge(ctx,chain,p)!="":
        note=fmt.tprintf("the task runs on Bridge %s; nothing launched here",bridge_owner_fleet_ensure_run_bridge(ctx,chain,p))
    }
    if note!="" {
        reply["note"]=json.String(note)
        return bridge_local_response_data(ctx.request_id,bridge_owner_json(reply))
    }
    // Every member a fleet row binds is a worker member; a task's reviewers
    // are such members named in its brief.
    role:="worker"
    reply["role"]=json.String(role)
    if instance:=bridge_owner_pstr(p,"instance_id");instance!="" {
        // Bind an already running instance of the agent instead of launching.
        child,live:=bridge_owner_child_locked(instance,"")
        if !live || child.agent_id!=agent do return bridge_owner_fail(ctx,"invalid_scope",fmt.tprintf("--instance %s is not a running instance of %s on this Bridge",instance,agent))
        r:=bridge_owner_fleet_member(ctx,chain,instance,agent,role,true,child)
        if r.code!="ok" do return bridge_owner_fail(ctx,r.code,fmt.tprintf("binding %s as a %s member was refused (an instance serves one chain for life)",instance,role))
        reply["instance_id"]=json.String(instance)
        return bridge_local_response_data(ctx.request_id,bridge_owner_json(reply))
    }
    body:=map[string]string{"agent_id"=agent,"chain_id"=chain,"bridge_id"=bridge_cfg().daemon_id}
    // ensure for a task: its per-agent override beats the row.
    bridge_owner_launch_body_model(&body,policy,bridge_cfg().daemon_id,agent,ensure_models)
    if project:=bridge_owner_pstr(p,"project_id");project!="" do body["project_id"]=project
    ctx.launch=Owner_Fleet_Launch{true,chain,agent,role,bridge_owner_json(body),reply,false}
    return ""
}

// The overrides an ensure for a task launches agent with: this verb's
// (override_provider, or override_clear = the fleet default), else the
// task's stored ones (task_id). nil outside a task ensure.
bridge_owner_fleet_ensure_models :: proc(ctx:^Owner_Agent_Ctx,chain,agent:string,p:json.Object) -> map[string]Owner_Agent_Model {
    if bridge_owner_pstr(p,"ensure")!="1" do return nil
    if bridge_owner_pstr(p,"override_clear")=="1" do return nil
    if override:=bridge_owner_pstr(p,"override_provider");override!="" {
        models:=make(map[string]Owner_Agent_Model,context.temp_allocator)
        models[agent]=Owner_Agent_Model{override,bridge_owner_pstr(p,"override_model")}
        return models
    }
    if task:=bridge_owner_pstr(p,"task_id");task!="" do return bridge_owner_task_models(ctx.store,chain,task)
    return nil
}

// An ensure for a task that runs here, whose agent has live members but none
// running the task's selection, and no stopped member: launch a dedicated one.
bridge_owner_fleet_ensure_dedicated :: proc(ctx:^Owner_Agent_Ctx,chain,agent:string,p:json.Object,models:map[string]Owner_Agent_Model) -> bool {
    if agent==ctx.child.agent_id || bridge_owner_fleet_ensure_run_bridge(ctx,chain,p)!="" do return false
    members,read:=bridge_owner_fleet_members(ctx,chain)
    if !read do return false
    live,stopped:=0,0
    _,overridden:=models[agent]
    for m in members {
        if m.agent_id!=agent || !m.enabled do continue
        // Live as the matcher and the task route see it (bridge_owner_live_child).
        // A stopped member is waited for only without an override: a restart
        // keeps its old selection, so the matcher never restarts it for one.
        if child,is_live:=bridge_owner_live_child(m.instance_id);!is_live || child.agent_id!=agent {
            if overridden { stopped+=1;continue }
            return false
        }
        if bridge_owner_instance_serves(ctx.store,chain,m.instance_id,agent,models) do return false
        live+=1
    }
    // Overridden with only stopped members: they would restart with the old selection.
    return live>0 || stopped>0
}

// The other Bridge an ensured task runs on ("" = this Bridge): the verb's
// --bridge (run_bridge_id; "" clears the pin), else the task's pin.
bridge_owner_fleet_ensure_run_bridge :: proc(ctx:^Owner_Agent_Ctx,chain:string,p:json.Object) -> string {
    run_bridge:=bridge_owner_pstr(p,"run_bridge_id")
    if _,named:=p["run_bridge_id"];!named {
        if task:=bridge_owner_pstr(p,"task_id");task!="" do run_bridge,_=bridge_owner_match_run_bridge(ctx.store,chain,task)
    }
    if run_bridge==bridge_cfg().daemon_id do return ""
    return run_bridge
}

// The provider, model and profile a fleet row launches with on bridge: its
// per-Bridge entry (`fleet set --bridge-models`), else the row's own.
bridge_owner_fleet_launch_model :: proc(policy:contracts.Owner_Fleet_Policy,bridge:string) -> (provider,model,profile:string) {
    provider,model,profile=policy.provider,policy.model,policy.provider_profile
    if models,valid:=contracts.owner_fleet_models(policy.bridge_models_json);valid {
        if m,pinned:=models[bridge];pinned { provider,model,profile=m.provider,m.model,m.provider_profile }
    }
    return
}

// After the owner route released every lock: launch, wait for the live child,
// then bind it as an enabled member under the locks.
bridge_owner_fleet_launch :: proc(request_id:string,launch:Owner_Fleet_Launch,rec:Bridge_Local_Agent_Token_Record) -> string {
    context.allocator=context.temp_allocator
    instance,launch_error:=bridge_owner_launch_into_chain(launch.body,launch.agent,rec)
    if launch_error!="" do return bridge_local_response_error(request_id,"agent_launch_failed",fmt.tprintf("fleet row saved; %s",launch_error))
    code,message:=bridge_owner_fleet_bind(request_id,launch.chain,launch.agent,launch.role,instance,rec.agent_instance_id,rec.token_hash)
    if code!="ok" do return bridge_local_response_error(request_id,code,fmt.tprintf("fleet row saved and %s launched; %s (it stays running unbound: `ham-ctl task-chain fleet set --agent %s --instance %s` retries, `ham-ctl agents stop %s` stops it)",instance,message,launch.agent,instance,instance))
    reply:=launch.reply
    reply["instance_id"]=json.String(instance)
    reply["launched"]=json.Boolean(true)
    return bridge_local_response_data(request_id,bridge_owner_json(reply))
}

// M1 item 10 (origin/main ensure_fleet_role): `task create|update|split`
// naming agents (--assignee, --reviewer, a split child's assignee or brief
// reviewers) needs no prior `task-chain fleet set`. Before the task route
// runs, every named agent without a fleet row in the chain gets one
// (capacity 1, idle TTL 600s) and, unless it is the coordinator itself (solo
// row) or placed on another Bridge, is launched here and bound as a member,
// exactly as `fleet set` does. The Hub launch refuses unknown, other-account
// and archived agents; their new row is paused so it never dispatches.
// Requests the task route would refuse anyway (a reviewer that is the
// assignee, the coordinator as reviewer) are refused first, so they launch
// nothing; any other refusal of the task verb rolls the ensure back
// (bridge_owner_task_fleet_rollback). The caller holds no lock.
// On task.update (block_failed) a launch failure does not refuse the update:
// it returns the agent and the launch error, and the caller blocks the task
// agent_not_running once the update applied (bridge_owner_block_not_running).
Owner_Fleet_Ensured :: struct {
    chain:string,
    // Agents whose row this ensure created and launched, and their instances.
    // A solo (coordinator) or remote row launches nothing and is kept.
    added,launched:[dynamic]string
}

// Effects, replaceable by tests; nil members use the real Bridge paths.
Owner_Fleet_Ensure_Effects :: struct {
    set:proc(request_id,body:string,rec:Bridge_Local_Agent_Token_Record) -> (string,bool,Owner_Fleet_Launch),
    launch:proc(request_id:string,launch:Owner_Fleet_Launch,rec:Bridge_Local_Agent_Token_Record) -> string,
    pause:proc(request_id,chain,agent:string,rec:Bridge_Local_Agent_Token_Record),
    stop:proc(instance:string,rec:Bridge_Local_Agent_Token_Record) -> bool,
}
@(thread_local)
bridge_owner_fleet_ensure_effects:Owner_Fleet_Ensure_Effects

// The agents a task verb names, and the refusal the task route would give
// for a reviewer that is the assignee or the calling coordinator.
bridge_owner_task_fleet_agents :: proc(method:string,p:json.Object,caller_agent:string) -> (agents:[dynamic]string,code,message:string) {
    agents=make([dynamic]string,context.temp_allocator)
    add :: proc(agents:^[dynamic]string,id:string) {
        if trimmed:=strings.trim_space(id);trimmed!="" && !slice.contains(agents[:],trimmed) do append(agents,trimmed)
    }
    // One task's assignee and reviewers: refused as the task route does.
    task :: proc(agents:^[dynamic]string,assignee:string,reviewers:json.Array,caller_agent:string) -> (string,string) {
        assignee:=strings.trim_space(assignee)
        add(agents,assignee)
        for item in reviewers {
            id,_:=item.(json.String)
            reviewer:=strings.trim_space(string(id))
            if reviewer=="" do continue
            if caller_agent!="" && reviewer==caller_agent do return "invalid_scope","the coordinator never reviews a task of its own chain; name another --reviewer"
            if assignee!="" && reviewer==assignee do return "invalid_scope","a reviewer must be a different agent than the assignee"
            add(agents,reviewer)
        }
        return "",""
    }
    if method=="agent.task.split" {
        list,_:=p["children"].(json.Array)
        for item in list {
            spec,_:=item.(json.Object)
            brief,_:=spec["brief"].(json.Object)
            reviewers,_:=brief["reviewers"].(json.Array)
            if code,message=task(&agents,bridge_owner_pstr(spec,"assignee"),reviewers,caller_agent);code!="" do return
        }
        return
    }
    reviewers,_:=p["reviewers"].(json.Array)
    code,message=task(&agents,bridge_owner_pstr(p,"assignee"),reviewers,caller_agent)
    return
}

bridge_owner_task_fleet_ensure :: proc(request_id,method,params:string,rec:Bridge_Local_Agent_Token_Record,block_failed:=false) -> (refused,failed_agent,failure:string,ensured:Owner_Fleet_Ensured) {
    context.allocator=context.temp_allocator
    e:=bridge_owner_fleet_ensure_effects
    set:=e.set if e.set!=nil else bridge_owner_fleet_ensure_set
    launch:=e.launch if e.launch!=nil else bridge_owner_fleet_launch
    pause:=e.pause if e.pause!=nil else bridge_owner_fleet_ensure_pause
    p:=bridge_owner_params(params)
    caller_agent:=""
    if e.set==nil {
        if l,has:=bridge_runtime_get_launch(rec.agent_instance_id);has do caller_agent=l.agent_id
    }
    agents,code,message:=bridge_owner_task_fleet_agents(method,p,caller_agent)
    if code!="" do return bridge_local_response_error(request_id,code,fmt.tprintf("%s; no agent launched",message)),"","",ensured
    chain:=bridge_owner_pstr(p,"chain_id")
    // A task pinned to another Bridge (this --bridge, else the task's pin read
    // by the fleet route): its assignee and reviewers start there, not here.
    _,named_bridge:=p["bridge_id"]
    run_bridge:=strings.trim_space(bridge_owner_pstr(p,"bridge_id"))
    task_id:=bridge_owner_pstr(p,"task_id")
    if method=="agent.task.split" {named_bridge=false;task_id=""}
    agent_models,_,models_error:=bridge_owner_agent_models_param(p)
    // An invalid --agent-model is refused by the task route: launch nothing for it.
    if models_error!="" do return "","","",Owner_Fleet_Ensured{chain=chain}
    ensured=Owner_Fleet_Ensured{chain=chain,added=make([dynamic]string),launched=make([dynamic]string)}
    for agent in agents {
        // The task route refuses ids that are not agent ids with its own message.
        if !contracts.owner_field_valid(agent,"id") do continue
        body:=map[string]string{"agent_id"=agent,"ensure"="1"}
        if chain!="" do body["chain_id"]=chain
        if named_bridge do body["run_bridge_id"]=run_bridge
        if task_id!="" do body["task_id"]=task_id
        // This verb's --agent-model for the agent (set, or cleared = the fleet
        // default); without one the task's stored override (task_id) applies.
        if m,has:=agent_models[agent];has {
            if m.provider!="" {body["override_provider"]=m.provider;body["override_model"]=m.model} else do body["override_clear"]="1"
        }
        response,handled,l:=set(request_id,bridge_owner_json(body),rec)
        // Not an owner chain, or not the coordinator: the task route decides.
        // A new row whose launch is pending has no reply yet ("").
        if !handled || !(bridge_owner_response_ok(response) || (response=="" && l.active)) do return "","","",ensured
        if out,parsed:=json.parse_string(response,.JSON,true,context.temp_allocator);parsed==nil {
            obj,_:=out.(json.Object);data,_:=obj["data"].(json.Object)
            if contracts.owner_string(data,"note")=="fleet row exists" do continue
            if ensured.chain=="" do ensured.chain=contracts.owner_string(data,"chain_id")
        }
        if ensured.chain=="" do ensured.chain=l.chain
        if !l.active do continue
        launched:=launch(request_id,l,rec)
        if bridge_owner_response_ok(launched) {
            // Only a row this ensure created is paused by a rollback.
            if !l.dedicated do append(&ensured.added,agent)
            if out,parsed:=json.parse_string(launched,.JSON,true,context.temp_allocator);parsed==nil {
                obj,_:=out.(json.Object);data,_:=obj["data"].(json.Object)
                if instance:=contracts.owner_string(data,"instance_id");instance!="" do append(&ensured.launched,instance)
            }
            continue
        }
        if !l.dedicated do pause(request_id,l.chain,agent,rec)
        if !block_failed do return launched,"","",ensured
        message:=launched
        if out,parsed:=json.parse_string(launched,.JSON,true,context.temp_allocator);parsed==nil {
            if obj,is_obj:=out.(json.Object);is_obj {
                if e,has:=obj["error"].(json.Object);has do message=contracts.owner_string(e,"message")
            }
        }
        return "",agent,message,ensured
    }
    return "","","",ensured
}

// The task verb was refused after its agents were ensured: the rows created
// for them are paused (never dispatched) and the instances launched for them
// stopped. A later task naming the agent is refused until the coordinator
// runs `task-chain fleet set --agent <id>` again (the resolve refusal says so).
bridge_owner_task_fleet_rollback :: proc(request_id:string,ensured:Owner_Fleet_Ensured,rec:Bridge_Local_Agent_Token_Record) {
    e:=bridge_owner_fleet_ensure_effects
    pause:=e.pause if e.pause!=nil else bridge_owner_fleet_ensure_pause
    stop:=e.stop if e.stop!=nil else bridge_owner_fleet_ensure_stop
    for agent in ensured.added do pause(request_id,ensured.chain,agent,rec)
    for instance in ensured.launched do if !stop(instance,rec) do fmt.eprintln("bridge owner: stopping",instance,"after a refused task verb failed")
}

bridge_owner_fleet_ensure_set :: proc(request_id,body:string,rec:Bridge_Local_Agent_Token_Record) -> (string,bool,Owner_Fleet_Launch) {
    response,handled,l,_,_:=bridge_owner_agent_route_locked(request_id,"agent.task_chain.fleet_set",body,rec)
    return response,handled,l
}
bridge_owner_fleet_ensure_pause :: proc(request_id,chain,agent:string,rec:Bridge_Local_Agent_Token_Record) {
    body:=map[string]string{"agent_id"=agent}
    if chain!="" do body["chain_id"]=chain
    _,_,_,_,_=bridge_owner_agent_route_locked(request_id,"agent.task_chain.fleet_pause",bridge_owner_json(body),rec)
}
bridge_owner_fleet_ensure_stop :: proc(instance:string,rec:Bridge_Local_Agent_Token_Record) -> bool {
    stopped:=bridge_local_relay_raw(.POST,route_path("api","v1","agent-instances",instance,"stop"),nil,"{}",rec)
    return stopped.ok && stopped.status>=200 && stopped.status<300
}

// Blocks a ready, unleased owner task whose agent could not be launched
// (origin/main taskv2 agent_not_running card). Takes the owner lock; the
// caller holds none. Returns whether the task was blocked.
bridge_owner_block_not_running :: proc(task,agent,failure:string) -> bool {
    detail:=strings.trim_space(failure)
    if detail=="" do detail="launch failed before startup confirmation"
    reason:=fmt.tprintf("Agent %s on bridge %s is not running: %s",agent,bridge_cfg().daemon_id,detail)
    account:=bridge_enrolled_owner_user_id(bridge_cfg().daemon_id)
    key_id,_:=vault.device_id_from_sign_pub(bridge_identity_public_key_hex(bridge_cfg().daemon_id),context.temp_allocator)
    sync.mutex_lock(&bridge_owner_mutex);defer sync.mutex_unlock(&bridge_owner_mutex)
    if !bridge_owner_open(account,key_id) do return false
    st,found,read:=owner.agent_task_state(&bridge_owner_store,"",task)
    if !read || !found do return false
    blocked,_:=owner.block_agent_not_running(&bridge_owner_store,st.chain_id,st.task_id,agent,reason,time.to_unix_nanoseconds(time.now())/1000000)
    return blocked
}

// Binds a launched live instance as an enabled member of the chain, signed
// for the caller (the chain's coordinator; token_hash "" skips the token
// check for a coordinator the Bridge acts for, see owner_agent_review.odin).
// Takes the owner, startup and token locks in that order; the caller holds none.
bridge_owner_fleet_bind :: proc(request_id,chain,agent,role,instance,caller_instance,caller_token_hash:string) -> (string,string) {
    account:=bridge_enrolled_owner_user_id(bridge_cfg().daemon_id)
    key_id,_:=vault.device_id_from_sign_pub(bridge_identity_public_key_hex(bridge_cfg().daemon_id),context.temp_allocator)
    code,message:="storage_error","owner store unavailable"
    sync.mutex_lock(&bridge_owner_mutex);defer sync.mutex_unlock(&bridge_owner_mutex)
    if bridge_owner_open(account,key_id) {
        kr,unlocked:=bridge_read_vault_keyring();defer vault.keyring_wipe(&kr)
        code,message="vault_locked","owner Bridge vault is locked"
        if unlocked {
            pub:=bridge_identity_public_key_hex(bridge_cfg().daemon_id)
            key:=contracts.Owner_Verified_Key{account,bridge_cfg().daemon_id,key_id,pub,"bridge",true,false}
            sync.mutex_lock(&bridge_startup_io_mutex)
            sync.mutex_lock(&bridge_local_token_mutex)
            caller,current:=bridge_owner_child_locked(caller_instance,caller_token_hash)
            child,live:=bridge_owner_child_locked(instance,"")
            code,message="invalid_scope","the launched instance or the calling coordinator is no longer running"
            if current && live && child.agent_id==agent {
                ctx:=Owner_Agent_Ctx{request_id=request_id,store=&bridge_owner_store,child=caller,key=key,kr=&kr,now=time.to_unix_nanoseconds(time.now())/1000000}
                r:=bridge_owner_fleet_member(&ctx,chain,instance,agent,role,true,child)
                code,message=r.code,"binding refused by the owner store"
            }
            sync.mutex_unlock(&bridge_local_token_mutex)
            sync.mutex_unlock(&bridge_startup_io_mutex)
            if code=="ok" do bridge_owner_coordinator_refresh_locked(chain)
        }
        bridge_owner_publish()
    }
    return code,message
}
