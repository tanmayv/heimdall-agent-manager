#+feature dynamic-literals
package main

// Review leases on chains this Bridge owns.
//
// A task entering in_review (lease submit, task submit-for-review, release,
// recheck, unblock) owes every reviewer its gate still waits on
// (owner.review_targets: the configured reviewer and each brief.reviewers
// member) a review lease. Under the child locks bridge_owner_review_plan picks,
// per owed agent, a live member instance to wake, else a stopped member
// instance to start, else a fresh launch into the chain through the fleet path
// (bridge_owner_launch_into_chain, then a coordinator-signed chain.member.set).
// bridge_owner_review_dispatch carries that out after every lock is released
// (lock order owner -> startup I/O -> token is never held while launching or
// waiting), typing the [taskv2] review-lease line into the reviewer. The
// reviewer's `lease next` then returns the review (bridge_owner_review_next):
// it opens the review session and writes a reviewer TASK.md; `review post`
// records its verdict.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"
import owner "odin_test:lib/owner_local"

Owner_Review_Action :: enum { Nudge, Start, Launch }
Owner_Review_Wake :: struct {
    action:Owner_Review_Action,
    chain,task,lease,agent,instance:string,
    body:string, // Launch: the Hub agent-instances body (fleet row model/provider)
}
// The wakes one verb owes, with the Hub credential a start/launch uses (the
// chain coordinator's, else the caller's) and the coordinator that binds a
// launched reviewer.
Owner_Review_Dispatch :: struct {
    wakes:[dynamic]Owner_Review_Wake,
    rec:Bridge_Local_Agent_Token_Record,
    coordinator:string,
}
Owner_Review_Context :: struct { run_dir,text:string }

// Effects, replaceable by tests; nil members use the real Bridge paths.
Owner_Review_Effects :: struct {
    nudge:proc(instance,line:string) -> bool,
    start:proc(instance,agent:string,rec:Bridge_Local_Agent_Token_Record) -> string,
    launch:proc(body,agent:string,rec:Bridge_Local_Agent_Token_Record) -> (string,string),
    bind:proc(chain,instance,agent,coordinator:string) -> (string,string),
}
bridge_owner_review_effects:Owner_Review_Effects
// Tests run the dispatch on the calling thread.
bridge_owner_review_sync_effects:bool

// Under the child locks: plan a review lease for every reviewer the task's
// gate still owes. Returns what was planned (for the verb's reply).
bridge_owner_review_plan :: proc(ctx:^Owner_Agent_Ctx,chain,task:string) -> json.Array {
    out:=make(json.Array,context.temp_allocator)
    targets,ok:=owner.review_targets(ctx.store,chain,task)
    st,found,read:=owner.agent_task_state(ctx.store,chain,task)
    if !ok || !found || !read || len(targets)==0 do return out
    submitted,_:=owner.query(ctx.store.db,"SELECT lease_id FROM local_submissions WHERE chain_id=? AND task_id=? AND attempt=?",chain,task,st.attempt)
    lease:=submitted[0][0] if len(submitted)==1 else ""
    if ctx.reviews.wakes==nil do ctx.reviews.wakes=make([dynamic]Owner_Review_Wake,context.temp_allocator)
    ctx.reviews.coordinator=owner.chain_coordinator_instance(ctx.store,chain)
    ctx.reviews.rec=ctx.rec
    if ctx.reviews.coordinator!="" && ctx.reviews.coordinator!=ctx.rec.agent_instance_id {
        if rec,has:=bridge_owner_review_token_locked(ctx.reviews.coordinator);has do ctx.reviews.rec=rec
    }
    for target in targets {
        wake:=Owner_Review_Wake{action=.Launch,chain=chain,task=task,lease=lease,agent=target.agent_id}
        for instance in target.instances {
            if child,live:=bridge_owner_live_child(instance);live && child.agent_id==target.agent_id { wake.action=.Nudge;wake.instance=instance;break }
        }
        if wake.action==.Launch && len(target.instances)>0 {
            // A stopped member keeps its membership across a restart.
            wake.action=.Start;wake.instance=target.instances[len(target.instances)-1]
        }
        if wake.action==.Launch {
            body:=map[string]string{"agent_id"=target.agent_id,"chain_id"=chain,"bridge_id"=bridge_config.daemon_id}
            if policy,has,policy_ok:=owner.agent_fleet_policy(ctx.store,chain,target.agent_id);policy_ok && has {
                if policy.provider!="" do body["provider"]=policy.provider
                if policy.model!="" do body["model"]=policy.model
                if policy.provider_profile!="" do body["provider_profile"]=policy.provider_profile
            }
            wake.body=bridge_owner_json(body)
        }
        append(&ctx.reviews.wakes,wake)
        action:=[Owner_Review_Action]string{.Nudge="woken",.Start="starting",.Launch="launching"}
        entry:=json.Object{"agent_id"=json.String(target.agent_id),"action"=json.String(action[wake.action])}
        if wake.instance!="" do entry["instance_id"]=json.String(wake.instance)
        append(&out,entry)
    }
    return out
}

// The current agent token record of an instance (caller holds the token lock).
bridge_owner_review_token_locked :: proc(instance:string) -> (Bridge_Local_Agent_Token_Record,bool) {
    for i:=len(bridge_local_token_records)-1;i>=0;i-=1 {
        r:=bridge_local_token_records[i]
        if r.agent_instance_id==instance && r.role==.Agent && r.invalidated_at_unix_ms==0 && r.instance_token!="" do return r,true
    }
    return {},false
}

// No lock held: wake, start or launch every planned reviewer, on a worker
// thread (a start or launch waits for the live child).
bridge_owner_review_dispatch :: proc(d:Owner_Review_Dispatch) {
    if len(d.wakes)==0 do return
    context.allocator=runtime.heap_allocator()
    owned:=new(Owner_Review_Dispatch)
    owned^=Owner_Review_Dispatch{make([dynamic]Owner_Review_Wake,0,len(d.wakes)),d.rec,strings.clone(d.coordinator)}
    owned.rec.agent_instance_id=strings.clone(d.rec.agent_instance_id);owned.rec.instance_token=strings.clone(d.rec.instance_token);owned.rec.token_hash=strings.clone(d.rec.token_hash)
    for w in d.wakes {
        append(&owned.wakes,Owner_Review_Wake{w.action,strings.clone(w.chain),strings.clone(w.task),strings.clone(w.lease),strings.clone(w.agent),strings.clone(w.instance),strings.clone(w.body)})
    }
    if bridge_owner_review_sync_effects {
        bridge_owner_review_execute(owned)
        return
    }
    thread.run_with_poly_data(owned,proc(d:^Owner_Review_Dispatch) {
        bridge_owner_review_execute(d)
        free_all(context.temp_allocator)
    })
}

// Owns and frees d (heap).
bridge_owner_review_execute :: proc(d:^Owner_Review_Dispatch) {
    context.allocator=runtime.heap_allocator()
    defer {
        for w in d.wakes { delete(w.chain);delete(w.task);delete(w.lease);delete(w.agent);delete(w.instance);delete(w.body) }
        delete(d.wakes);delete(d.coordinator)
        delete(d.rec.agent_instance_id);delete(d.rec.instance_token);delete(d.rec.token_hash)
        free(d)
    }
    e:=bridge_owner_review_effects
    nudge:=e.nudge if e.nudge!=nil else bridge_owner_review_nudge
    start:=e.start if e.start!=nil else bridge_owner_review_start
    launch:=e.launch if e.launch!=nil else bridge_owner_launch_into_chain
    bind:=e.bind if e.bind!=nil else bridge_owner_review_bind
    for w in d.wakes {
        instance:=w.instance
        switch w.action {
        case .Nudge:
        case .Start:
            if failed:=start(instance,w.agent,d.rec);failed!="" { fmt.eprintln("bridge owner review: starting reviewer",w.agent,"failed:",failed);continue }
        case .Launch:
            launched,failed:=launch(w.body,w.agent,d.rec)
            if failed!="" { fmt.eprintln("bridge owner review: launching reviewer",w.agent,"failed:",failed);continue }
            if code,message:=bind(w.chain,launched,w.agent,d.coordinator);code!="ok" { fmt.eprintln("bridge owner review: binding reviewer",launched,"failed:",code,message);continue }
            instance=launched
        }
        line:=bridge_wake_nudge_line(w.lease,w.task,"reviewer");defer delete(line)
        if !nudge(instance,line) do fmt.eprintln("bridge owner review: waking reviewer",instance,"failed")
    }
}

// Types the review-lease line into a live child (no lock held).
bridge_owner_review_nudge :: proc(instance,line:string) -> bool {
    socket,ok:=bridge_pty_host_ensure_daemon()
    if !ok do return false
    defer delete(socket)
    return bridge_pty_host_deliver_line(socket,instance,line)
}

// Starts a stopped member instance through the Hub (as `ham-ctl agents start`
// with the coordinator's credential) and waits, with no lock held, for its
// live child here. Membership binds the instance, so it stays a member.
bridge_owner_review_start :: proc(instance,agent:string,rec:Bridge_Local_Agent_Token_Record) -> string {
    context.allocator=context.temp_allocator
    started:=bridge_local_relay_raw(.POST,route_path("api","v1","agent-instances",instance,"start"),nil,"",rec)
    if !started.ok || started.status<200 || started.status>=300 {
        detail:=started.body
        if len(detail)>300 do detail=detail[:300]
        return fmt.tprintf("starting %s failed (HTTP %d): %s",instance,started.status,detail)
    }
    return bridge_owner_wait_live(instance,agent)
}

// Polls (no lock held between polls) until the instance is a live child of
// the agent here, up to BRIDGE_CHAIN_CREATE_LAUNCH_WAIT_MS.
bridge_owner_wait_live :: proc(instance,agent:string) -> string {
    started:=time.tick_now()
    for {
        sync.mutex_lock(&bridge_startup_io_mutex)
        sync.mutex_lock(&bridge_local_token_mutex)
        child,current:=bridge_owner_child_locked(instance,"")
        sync.mutex_unlock(&bridge_local_token_mutex)
        sync.mutex_unlock(&bridge_startup_io_mutex)
        if current && child.agent_id==agent do return ""
        if time.duration_milliseconds(time.tick_since(started))>=BRIDGE_CHAIN_CREATE_LAUNCH_WAIT_MS do return fmt.tprintf("%s did not start on this Bridge within %ds",instance,BRIDGE_CHAIN_CREATE_LAUNCH_WAIT_MS/1000)
        time.sleep(2*time.Second)
    }
}

// A launched reviewer joins the chain as an enabled worker member, signed for
// the chain's coordinator (the fleet path's binding).
bridge_owner_review_bind :: proc(chain,instance,agent,coordinator:string) -> (string,string) {
    if coordinator=="" do return "invalid_scope","the chain has no bound coordinator"
    return bridge_owner_fleet_bind(bridge_owner_fresh_id("review"),chain,agent,"worker",instance,coordinator,"")
}

// `lease next` with no work: the review this child owes, opened (its review
// session) and delivered as a reviewer TASK.md.
bridge_owner_review_next :: proc(ctx:^Owner_Agent_Ctx) -> string {
    none:=bridge_local_response_data(ctx.request_id,bridge_owner_json(Owner_Agent_Next{status="none",authority=bridge_owner_authority()}))
    chain,task,found,read:=owner.review_pending(ctx.store,ctx.child)
    if !read do return bridge_owner_fail(ctx,"storage_error","owner store could not be read; retry")
    if !found do return none
    st,known,ok:=owner.agent_task_state(ctx.store,chain,task)
    if !ok do return bridge_owner_fail(ctx,"storage_error","owner store could not be read; retry")
    if !known do return none
    opened,lease,code:=bridge_owner_review_open(ctx,st,"approve","review lease")
    if code!="ok" do return bridge_owner_fail(ctx,code,"owner review open refused")
    out:=Owner_Agent_Lease{lease_id=lease,task_id=task,chain_id=chain,requirements_revision=st.requirements_revision,acknowledged="1",
        placement=bridge_owner_placement(st.config,st.configured),role="reviewer",attempt=st.attempt}
    ctx.review_context=Owner_Review_Context{ctx.run_dir,bridge_owner_render_review_context(st,out,ctx.child.instance,opened.body)}
    return bridge_local_response_data(ctx.request_id,bridge_owner_json(Owner_Agent_Next{"granted",out,Owner_Agent_Task_Ref{task,chain},bridge_owner_authority()}))
}

// review.open for the submitted attempt (a fresh session capability).
bridge_owner_review_open :: proc(ctx:^Owner_Agent_Ctx,st:owner.Agent_Task_State,verdict,summary:string) -> (owner.Result,string,string) {
    payload:=bridge_owner_json(map[string]string{"requirements_revision"=st.requirements_revision,"attempt"=st.attempt,"head"=st.head,"verdict"=verdict,"summary"=summary})
    submitted,read:=owner.query(ctx.store.db,"SELECT lease_id FROM local_submissions WHERE chain_id=? AND task_id=? AND attempt=?",st.chain_id,st.task_id,st.attempt)
    if !read || len(submitted)!=1 do return {},"","stale_revision"
    opened:=bridge_owner_run_input(ctx,"review.open",st.chain_id,st.task_id,submitted[0][0],st.configuration_revision,st.task_revision,"",payload)
    return opened,submitted[0][0],opened.code
}

bridge_owner_review_context_write :: proc(c:Owner_Review_Context) -> bool {
    clean:=strings.trim_right(strings.trim_space(c.run_dir),"/")
    if clean=="" || len(c.text)>BRIDGE_TASK_MD_MAX_BYTES do return false
    path:=strings.concatenate({clean,"/TASK.md"},context.temp_allocator)
    sync.mutex_guard(&bridge_taskv2_task_md_mutex)
    return bridge_retry_atomic_write(path,transmute([]byte)c.text)
}

// The reviewer's TASK.md: the submitted attempt, its brief and summary, and
// how to post the verdict. Pure.
bridge_owner_render_review_context :: proc(st:owner.Agent_Task_State,lease:Owner_Agent_Lease,instance,opened:string) -> string {
    result:=bridge_owner_result_object(opened)
    get:=contracts.owner_string
    workdir:=""
    if lease.placement.workdir!="" do workdir=fmt.tprintf("- Workdir: `%s` (branch `%s`, submitted head `%s`). Inspect it; do not commit.\n",lease.placement.workdir,lease.placement.branch,st.head)
    return fmt.tprintf("# Owner-local review of task %s\n\nRole: reviewer\n\n- Chain: %s\n- Lease: %s (review)\n- Attempt: %s\n- Instance: %s\n- Requirements revision: %s\n%s\n## Submitted requirements (complete)\n```json\n%s\n```\n\n## Worker's summary\n%s\n\nThis chain is held by its owner Bridge. Judge the attempt against the brief and the worker's reported checks, then post exactly one verdict:\n`ham-ctl review post --task %s --verdict approve` or `ham-ctl review post --task %s --verdict request_changes --summary <what must change>`. Every reviewer the task names must approve; any request_changes returns it to its worker.\n",
        st.task_id,st.chain_id,lease.lease_id,st.attempt,instance,st.requirements_revision,workdir,get(result,"brief"),get(result,"summary"),st.task_id,st.task_id)
}
