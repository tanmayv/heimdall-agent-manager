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

Owner_Review_Action :: enum { Nudge, Start, Launch, Restart, Place, Remote }
Owner_Review_Wake :: struct {
    action:Owner_Review_Action,
    chain,task,lease,agent,instance:string,
    body:string, // Launch/Remote: the Hub agent-instances body (fleet row model/provider)
    // A worker the matcher brings to a ready task (owner_agent_matcher.odin):
    // woken with the work line; a failed start blocks the task agent_not_running.
    worker:bool,
    // Start/Launch of a fleet agent for unassigned work: no wake line; the
    // matcher runs again for the chain once it is live and assigns the task.
    rematch:bool,
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
    // A fresh context for a live worker (its own handoff): restart, wait live.
    restart:proc(instance,agent:string,rec:Bridge_Local_Agent_Token_Record) -> string,
    launch:proc(body,agent:string,rec:Bridge_Local_Agent_Token_Record) -> (string,string),
    bind:proc(chain,instance,agent,coordinator:string) -> (string,string),
    block:proc(task,agent,failure:string) -> bool,
    rematch:proc(chain:string),
    // Place: the task's assignee is placed on its remote run Bridge again
    // (owner_agent_matcher.odin); "" on success, else why it failed.
    place:proc(chain,task,agent:string,rec:Bridge_Local_Agent_Token_Record) -> string,
    // Remote: the reviewer is launched on its run Bridge through the Hub; it
    // is not waited for or bound here. "" on success, else why it failed.
    remote:proc(body,agent,line:string,rec:Bridge_Local_Agent_Token_Record) -> string,
}
@(thread_local)
bridge_owner_review_effects:Owner_Review_Effects
// Tests run the dispatch on the calling thread.
@(thread_local)
bridge_owner_review_sync_effects:bool

// Under the child locks: plan a review lease for every reviewer the task's
// gate still owes. Returns what was planned (for the verb's reply).
//
// Each reviewer of an attempt has one matcher key (bridge_owner_review_key).
// A verb (periodic=false) plans now and marks the key; the matcher's review
// pass (periodic=true, owner_agent_matcher.odin) plans only a reviewer whose
// key is due, so an owed review lost to a failed start/launch, a submit that
// planned nothing (remote lifecycle submit) or a Bridge restart is dispatched
// again after BRIDGE_OWNER_MATCH_RETRY_MS, never twice within it.
bridge_owner_review_plan :: proc(ctx:^Owner_Agent_Ctx,chain,task:string,periodic:=false) -> json.Array {
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
    run_bridge,pinned:=bridge_owner_match_run_bridge(ctx.store,chain,task)
    // Unpinned work reserved on another Bridge (its worker's fleet row there)
    // is reviewed there too: the author's commits stay in that checkout.
    if !pinned {
        if executor,read:=owner.remote_assignment_executor(ctx.store,chain,task);read && executor!="" { run_bridge,pinned=executor,true }
    }
    models:=bridge_owner_brief_agent_models(st.brief)
    for target in targets {
        // A periodic pass leaves a reviewer alone, local or on another
        // Bridge (relayed review.open), while it holds an unexpired review
        // session for this attempt: it is reviewing, so nothing is woken,
        // started or launched again. Only a reviewer with no current session
        // (a failed start/launch, or one that stopped) is retried.
        if periodic {
            rows,read:=owner.query(ctx.store.db,"SELECT 1 FROM local_review_sessions WHERE chain_id=? AND task_id=? AND attempt=? AND json_extract(child,'$.agent_id')=? AND expires_ms>?",
                chain,task,st.attempt,target.agent_id,fmt.tprintf("%d",ctx.now))
            if !read || len(rows)>0 {
                append(&out,json.Object{"agent_id"=json.String(target.agent_id),"action"=json.String("reviewing")})
                continue
            }
        }
        // A reviewer whose task runs on another account Bridge (the task's
        // pin, else its fleet row's Bridge) is launched there through the Hub
        // and reviews over the agent relay; it is never started here.
        if place,code,_:=bridge_owner_remote_target(ctx.store,chain,target.agent_id,run_bridge,pinned,models);code!="" {
            entry:=json.Object{"agent_id"=json.String(target.agent_id),"action"=json.String("remote")}
            if code=="ok" {
                entry["bridge_id"]=json.String(place.executor_bridge)
                // Once per attempt within the matcher back-off: a recheck of
                // the same attempt does not launch a second reviewer.
                if bridge_owner_match_due(bridge_owner_review_key(chain,task,st.attempt,target.agent_id),ctx.now,false) {
                    body:=bridge_owner_json(map[string]string{"agent_id"=target.agent_id,"chain_id"=chain,"bridge_id"=place.executor_bridge,"provider"=place.provider,"model"=place.model})
                    append(&ctx.reviews.wakes,Owner_Review_Wake{action=.Remote,chain=chain,task=task,lease=lease,agent=target.agent_id,body=body})
                    entry["action"]=json.String("launching_remote")
                }
            }
            append(&out,entry)
            continue
        }
        if !bridge_owner_match_due(bridge_owner_review_key(chain,task,st.attempt,target.agent_id),ctx.now,!periodic) {
            append(&out,json.Object{"agent_id"=json.String(target.agent_id),"action"=json.String("owed")})
            continue
        }
        wake:=Owner_Review_Wake{action=.Launch,chain=chain,task=task,lease=lease,agent=target.agent_id}
        // A task override for this reviewer: only a live instance launched with
        // that selection reviews; otherwise a dedicated one is launched with it
        // (a stopped member would restart with its old selection).
        _,overridden:=models[target.agent_id]
        for instance in target.instances {
            if child,live:=bridge_owner_live_child(instance);live && child.agent_id==target.agent_id && bridge_owner_instance_serves(ctx.store,chain,instance,target.agent_id,models) { wake.action=.Nudge;wake.instance=instance;break }
        }
        if wake.action==.Launch && len(target.instances)>0 && !overridden {
            // A stopped member keeps its membership across a restart.
            wake.action=.Start;wake.instance=target.instances[len(target.instances)-1]
        }
        if wake.action==.Launch {
            body:=map[string]string{"agent_id"=target.agent_id,"chain_id"=chain,"bridge_id"=bridge_cfg().daemon_id}
            policy,_,_:=owner.agent_fleet_policy(ctx.store,chain,target.agent_id)
            bridge_owner_launch_body_model(&body,policy,bridge_cfg().daemon_id,target.agent_id,models)
            wake.body=bridge_owner_json(body)
        }
        append(&ctx.reviews.wakes,wake)
        action:=[Owner_Review_Action]string{.Nudge="woken",.Start="starting",.Launch="launching",.Restart="restarting",.Place="placing",.Remote="launching_remote"}
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

// The matcher key of one reviewer owed on one attempt.
bridge_owner_review_key :: proc(chain,task,attempt,agent:string) -> string {
    return fmt.tprintf("%s|%s|%s|%s|review",chain,task,attempt,agent)
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
        append(&owned.wakes,Owner_Review_Wake{w.action,strings.clone(w.chain),strings.clone(w.task),strings.clone(w.lease),strings.clone(w.agent),strings.clone(w.instance),strings.clone(w.body),w.worker,w.rematch})
    }
    if bridge_owner_review_sync_effects {
        bridge_owner_review_execute(owned)
        return
    }
    bridge_thread_run_with_poly_data(owned,proc(d:^Owner_Review_Dispatch) {
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
    restart:=e.restart if e.restart!=nil else bridge_owner_review_restart
    launch:=e.launch if e.launch!=nil else bridge_owner_launch_into_chain
    bind:=e.bind if e.bind!=nil else bridge_owner_review_bind
    block:=e.block if e.block!=nil else bridge_owner_block_not_running
    rematch:=e.rematch if e.rematch!=nil else bridge_owner_match_rerun
    place:=e.place if e.place!=nil else bridge_owner_match_place
    remote:=e.remote if e.remote!=nil else bridge_owner_review_remote_launch
    rematched:=make(map[string]bool,context.temp_allocator)
    for w in d.wakes {
        instance:=w.instance
        switch w.action {
        case .Nudge:
        case .Start:
            if failed:=start(instance,w.agent,d.rec);failed!="" {
                fmt.eprintln("bridge owner dispatch: starting",w.agent,instance,"failed:",failed)
                if w.worker do _=block(w.task,w.agent,failed)
                continue
            }
        case .Restart:
            if failed:=restart(instance,w.agent,d.rec);failed!="" {
                fmt.eprintln("bridge owner dispatch: restarting",w.agent,instance,"failed:",failed)
                if w.worker do _=block(w.task,w.agent,failed)
                continue
            }
        case .Launch:
            launched,failed:=launch(w.body,w.agent,d.rec)
            if failed!="" {
                fmt.eprintln("bridge owner dispatch: launching",w.agent,"failed:",failed)
                if w.worker do _=block(w.task,w.agent,failed)
                continue
            }
            if code,message:=bind(w.chain,launched,w.agent,d.coordinator);code!="ok" { fmt.eprintln("bridge owner dispatch: binding",launched,"failed:",code,message);continue }
            instance=launched
        case .Place:
            // The executor Bridge brings the agent up; the periodic matcher
            // retries a failed placement after its back-off.
            if failed:=place(w.chain,w.task,w.agent,d.rec);failed!="" do fmt.eprintln("bridge owner dispatch: placing",w.agent,"for",w.task,"failed:",failed)
            continue
        case .Remote:
            // The reviewer's bare `lease next` on its Bridge relays here
            // (owner_remote_agent.odin) and gets the review and its TASK.md.
            line:=bridge_wake_nudge_line(w.lease,w.task,"reviewer");defer delete(line)
            if failed:=remote(w.body,w.agent,line,d.rec);failed!="" do fmt.eprintln("bridge owner dispatch: launching reviewer",w.agent,"for",w.task,"on another Bridge failed:",failed)
            continue
        }
        if w.rematch {
            if !rematched[w.chain] { rematched[w.chain]=true;rematch(w.chain) }
            continue
        }
        line:=bridge_owner_work_line(w.task) if w.worker else bridge_wake_nudge_line(w.lease,w.task,"reviewer");defer delete(line)
        if !nudge(instance,line) do fmt.eprintln("bridge owner dispatch: waking",instance,"failed")
    }
}

// Types the review-lease line into a live child (no lock held). The socket is
// the process-global cached path (bridge_pty_host_ensure_daemon): never freed.
bridge_owner_review_nudge :: proc(instance,line:string) -> bool {
    socket,ok:=bridge_pty_host_ensure_daemon()
    if !ok do return false
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

// Restarts a live worker through the Hub so its next task starts with a fresh
// context (origin/main release_in_uow stop_holder on the agent's own
// handoff), then waits for the new run. The handoff reply reaches the caller
// first: the restart waits BRIDGE_OWNER_RESTART_GRACE_MS.
BRIDGE_OWNER_RESTART_GRACE_MS :: 2000
bridge_owner_review_restart :: proc(instance,agent:string,rec:Bridge_Local_Agent_Token_Record) -> string {
    context.allocator=context.temp_allocator
    time.sleep(BRIDGE_OWNER_RESTART_GRACE_MS*time.Millisecond)
    sync.mutex_lock(&bridge_startup_io_mutex)
    sync.mutex_lock(&bridge_local_token_mutex)
    old,_:=bridge_owner_child_locked(instance,"")
    sync.mutex_unlock(&bridge_local_token_mutex)
    sync.mutex_unlock(&bridge_startup_io_mutex)
    restarted:=bridge_local_relay_raw(.POST,route_path("api","v1","agent-instances",instance,"restart"),nil,"{}",rec)
    if !restarted.ok || restarted.status<200 || restarted.status>=300 {
        detail:=restarted.body
        if len(detail)>300 do detail=detail[:300]
        return fmt.tprintf("restarting %s failed (HTTP %d): %s",instance,restarted.status,detail)
    }
    return bridge_owner_wait_live(instance,agent,old.run_count)
}

// Polls (no lock held between polls) until the instance is a live child of
// the agent here with a run after after_run, up to
// BRIDGE_CHAIN_CREATE_LAUNCH_WAIT_MS.
bridge_owner_wait_live :: proc(instance,agent:string,after_run:i64=0) -> string {
    started:=time.tick_now()
    for {
        sync.mutex_lock(&bridge_startup_io_mutex)
        sync.mutex_lock(&bridge_local_token_mutex)
        child,current:=bridge_owner_child_locked(instance,"")
        sync.mutex_unlock(&bridge_local_token_mutex)
        sync.mutex_unlock(&bridge_startup_io_mutex)
        if current && child.run_count>after_run && (agent=="" || child.agent_id==agent) do return ""
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
// session) and delivered as a reviewer TASK.md. A relayed reviewer (remote
// set) is granted only a review whose selection it was launched with
// (bridge_owner_remote_reviewer_serves).
bridge_owner_review_next :: proc(ctx:^Owner_Agent_Ctx,only_chain:="",remote:Owner_Remote_Reviewer_Selection={}) -> string {
    none:=bridge_local_response_data(ctx.request_id,bridge_owner_json(Owner_Agent_Next{status="none",authority=bridge_owner_authority()}))
    pending,read:=owner.review_pending_all(ctx.store,ctx.child,only_chain)
    if !read do return bridge_owner_fail(ctx,"storage_error","owner store could not be read; retry")
    chain,task:string
    found:=false
    for candidate in pending {
        if remote.bridge!="" {
            serves,ok:=bridge_owner_remote_reviewer_serves(ctx.store,candidate.chain,candidate.task,ctx.child.agent_id,remote)
            if !ok do return bridge_owner_fail(ctx,"storage_error","owner store could not be read; retry")
            if !serves do continue
        }
        chain,task,found=candidate.chain,candidate.task,true
        break
    }
    if !found do return none
    st,known,ok:=owner.agent_task_state(ctx.store,chain,task)
    if !ok do return bridge_owner_fail(ctx,"storage_error","owner store could not be read; retry")
    if !known do return none
    opened,lease,code:=bridge_owner_review_open(ctx,st,"approve","review lease")
    if code!="ok" do return bridge_owner_fail(ctx,code,"owner review open refused")
    out:=Owner_Agent_Lease{lease_id=lease,task_id=task,chain_id=chain,requirements_revision=st.requirements_revision,acknowledged="1",
        placement=bridge_owner_placement(st.config,st.configured),role="reviewer",attempt=st.attempt}
    ctx.review_context=Owner_Review_Context{ctx.run_dir,bridge_owner_render_review_context(st,out,ctx.child.instance,opened.body)}
    return bridge_local_response_data(ctx.request_id,bridge_owner_json(Owner_Agent_Next{status="granted",lease=out,task=Owner_Agent_Task_Ref{task,chain},authority=bridge_owner_authority(),read_next=BRIDGE_OWNER_REVIEW_CONTEXT_HINT}))
}

// A relayed reviewer: the Bridge it runs on and the provider/model that Bridge
// launched it with (its launch record, set by the relaying Bridge, never by
// the agent; "" when that Bridge does not know them).
Owner_Remote_Reviewer_Selection :: struct { bridge,provider,model:string }

// Whether a relayed reviewer may take a task's review: the selection it was
// launched with is the one a reviewer of that task is launched with on its
// Bridge (bridge_owner_remote_target with the task's agent_models, as the
// review dispatch launches it). Several instances of one agent may serve a
// chain with different selections (bridge_owner_review_remote_launch), so one
// launched for a model-A task never takes a model-B task's review, and the
// reverse. An instance whose selection its Bridge does not know is not
// second-guessed (bridge_owner_instance_matches).
bridge_owner_remote_reviewer_serves :: proc(s:^owner.Store,chain,task,agent:string,remote:Owner_Remote_Reviewer_Selection) -> (serves,ok:bool) {
    if remote.provider=="" do return true,true
    st,found,read:=owner.agent_task_state(s,chain,task)
    if !read do return false,false
    if !found do return false,true
    place,code,_:=bridge_owner_remote_target(s,chain,agent,remote.bridge,true,bridge_owner_brief_agent_models(st.brief))
    if code=="storage_error" do return false,false
    // No selection for it there (unplaceable): nothing to compare against.
    if code!="ok" do return true,true
    return place.provider==remote.provider && place.model==remote.model,true
}

// review.open for the submitted attempt (a fresh session capability).
bridge_owner_review_open :: proc(ctx:^Owner_Agent_Ctx,st:owner.Agent_Task_State,verdict,summary:string) -> (owner.Result,string,string) {
    payload:=bridge_owner_json(map[string]string{"requirements_revision"=st.requirements_revision,"attempt"=st.attempt,"head"=st.head,"verdict"=verdict,"summary"=summary})
    submitted,read:=owner.query(ctx.store.db,"SELECT lease_id FROM local_submissions WHERE chain_id=? AND task_id=? AND attempt=?",st.chain_id,st.task_id,st.attempt)
    if !read || len(submitted)!=1 do return {},"","stale_revision"
    opened:=bridge_owner_run_input(ctx,"review.open",st.chain_id,st.task_id,submitted[0][0],st.configuration_revision,st.task_revision,"",payload)
    return opened,submitted[0][0],opened.code
}

// The granted review's pointer to its TASK.md, which is written after the
// reply is built (here, or on the relaying Bridge for a remote reviewer).
BRIDGE_OWNER_REVIEW_CONTEXT_HINT :: "Read TASK.md in your run directory now (it was just rewritten for this review): it holds the brief, the worker's summary and checks, and the exact review post command."

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
    // A chain with no project directory runs in scratch Workdirs (F4 A): the
    // author's is its own run directory, so the review says where to work.
    else do workdir="- Workdir: your run directory (this chain has no project directory; nothing is merged back). Judge the attempt from its submit summary, handoff and task comments, and run any checks you need in your run directory.\n"
    return fmt.tprintf("# Owner-local review of task %s\n\nRole: reviewer\n\n- Chain: %s\n- Lease: %s (review)\n- Attempt: %s\n- Instance: %s\n- Requirements revision: %s\n%s\n## Submitted requirements (complete)\n```json\n%s\n```\n\n## Worker's summary\n%s\n\nThis chain is held by its owner Bridge. Judge the attempt against the brief and the worker's reported checks, then post exactly one verdict:\n`ham-ctl review post --task %s --verdict approve` or `ham-ctl review post --task %s --verdict request_changes --summary <what must change>`. Every reviewer the task names must approve; any request_changes returns it to its worker.\n",
        st.task_id,st.chain_id,lease.lease_id,st.attempt,instance,st.requirements_revision,workdir,get(result,"brief"),get(result,"summary"),st.task_id,st.task_id)
}

// A reviewer on another account Bridge, through the Hub with the coordinator's
// credential. One instance serves each (chain, agent, run Bridge, provider,
// model): the first dispatch launches it (POST /api/v1/agent-instances, body
// names that bridge_id, the chain and the selection), and later ones reuse it
// (R1 FIX A, run8 launched three). A task whose agent_models override asks for
// another provider/model gets its own instance launched with that selection,
// never the one launched with the first selection (as instance_serves does for
// local reviewers). A stopped one is started (its bootstrap runs `lease
// next`); a live one gets the review-lease line as an agent message, which
// wakes it. An instance the Hub no longer knows is forgotten and a new one
// launched. Nothing is waited for or bound here: the instance runs there.
//
// Dispatches run on their own threads and the matcher back-off is per task, so
// two tasks can dispatch the same reviewer at once: each key's acquisition
// (lookup, start/launch, remember) holds that key's lock, so the second waits
// and then reuses the instance the first launched; a failed launch remembers
// nothing, so the next dispatch retries it.
bridge_owner_remote_reviewers:map[string]string
// One heap lock per key, never freed (bounded by the keys ever acquired).
bridge_owner_remote_reviewer_locks:map[string]^sync.Mutex
bridge_owner_remote_reviewers_mutex:sync.Mutex
// Tests substitute the Hub calls (all POSTs; an agent verb goes in its
// envelope).
bridge_owner_remote_reviewer_http:proc(path:[]string,body,envelope_method:string,rec:Bridge_Local_Agent_Token_Record) -> Bridge_Local_Relay_Result

bridge_owner_review_remote_launch :: proc(body,agent,line:string,rec:Bridge_Local_Agent_Token_Record) -> string {
    context.allocator=context.temp_allocator
    send:=bridge_owner_remote_reviewer_http if bridge_owner_remote_reviewer_http!=nil else bridge_owner_remote_reviewer_http_default
    p:=bridge_owner_params(body)
    key:=bridge_owner_remote_reviewer_key(bridge_owner_pstr(p,"chain_id"),agent,bridge_owner_pstr(p,"bridge_id"),bridge_owner_pstr(p,"provider"),bridge_owner_pstr(p,"model"))
    lock:=bridge_owner_remote_reviewer_lock(key)
    sync.mutex_lock(lock);defer sync.mutex_unlock(lock)
    known:=bridge_owner_remote_reviewer_get(key)
    if known!="" {
        started:=send(route_path("api","v1","agent-instances",known,"start"),"","",rec)
        if started.ok && started.status>=200 && started.status<300 do return ""
        if started.ok && started.status==409 {
            // Already running: wake it with the review-lease line.
            message:=bridge_owner_json(struct{to,body:string}{known,line})
            sent:=send(route_path("api","v1","agent-actions","chat","send-to-agent"),bridge_agent_rewrite_params("agent.chat.send",message),"agent.chat.send",rec)
            if sent.ok && sent.status>=200 && sent.status<300 do return ""
            return fmt.tprintf("waking reviewer %s failed (HTTP %d)",known,sent.status)
        }
        if !started.ok || started.status>=500 do return fmt.tprintf("starting reviewer %s failed (HTTP %d)",known,started.status)
        // The Hub refused it (gone, or no longer this agent's): launch anew.
        bridge_owner_remote_reviewer_set(key,"")
    }
    launched:=send(route_path("api","v1","agent-instances"),body,"",rec)
    if !launched.ok || launched.status<200 || launched.status>=300 {
        detail:=launched.body
        if len(detail)>300 do detail=detail[:300]
        return fmt.tprintf("launching %s failed (HTTP %d): %s",agent,launched.status,detail)
    }
    created:struct{data:struct{agent_instance_id:string}}
    if json.unmarshal_string(launched.body,&created,.JSON,context.temp_allocator)==nil && created.data.agent_instance_id!="" {
        bridge_owner_remote_reviewer_set(key,created.data.agent_instance_id)
    }
    return ""
}

bridge_owner_remote_reviewer_http_default :: proc(path:[]string,body,envelope_method:string,rec:Bridge_Local_Agent_Token_Record) -> Bridge_Local_Relay_Result {
    if envelope_method!="" do return bridge_local_relay_agent_envelope(path,envelope_method,body,rec)
    return bridge_local_relay_raw(.POST,path,nil,body,rec)
}

// The cache key of one remote reviewer instance: its selection is part of it.
bridge_owner_remote_reviewer_key :: proc(chain,agent,bridge,provider,model:string) -> string {
    return fmt.tprintf("%s|%s|%s|%s|%s",chain,agent,bridge,provider,model)
}

// The acquisition lock of a key (created on first use).
bridge_owner_remote_reviewer_lock :: proc(key:string) -> ^sync.Mutex {
    sync.mutex_lock(&bridge_owner_remote_reviewers_mutex);defer sync.mutex_unlock(&bridge_owner_remote_reviewers_mutex)
    if bridge_owner_remote_reviewer_locks==nil do bridge_owner_remote_reviewer_locks=make(map[string]^sync.Mutex,runtime.heap_allocator())
    if lock,has:=bridge_owner_remote_reviewer_locks[key];has do return lock
    lock:=new(sync.Mutex,runtime.heap_allocator())
    bridge_owner_remote_reviewer_locks[strings.clone(key,runtime.heap_allocator())]=lock
    return lock
}

bridge_owner_remote_reviewer_get :: proc(key:string) -> string {
    sync.mutex_lock(&bridge_owner_remote_reviewers_mutex);defer sync.mutex_unlock(&bridge_owner_remote_reviewers_mutex)
    return strings.clone(bridge_owner_remote_reviewers[key] or_else "",context.temp_allocator)
}

// instance=="" forgets the key.
bridge_owner_remote_reviewer_set :: proc(key,instance:string) {
    sync.mutex_lock(&bridge_owner_remote_reviewers_mutex);defer sync.mutex_unlock(&bridge_owner_remote_reviewers_mutex)
    if bridge_owner_remote_reviewers==nil do bridge_owner_remote_reviewers=make(map[string]string,runtime.heap_allocator())
    if old_key,old:=delete_key(&bridge_owner_remote_reviewers,key);old_key!="" { delete(old_key,runtime.heap_allocator());delete(old,runtime.heap_allocator()) }
    if instance=="" do return
    bridge_owner_remote_reviewers[strings.clone(key,runtime.heap_allocator())]=strings.clone(instance,runtime.heap_allocator())
}
