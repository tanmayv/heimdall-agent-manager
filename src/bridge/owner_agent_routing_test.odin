#+feature dynamic-literals
package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import owner "odin_test:lib/owner_local"

owner_routing_git :: proc(t:^testing.T,dir:string,args:..string) -> string {
    argv:=make([dynamic]string,context.temp_allocator)
    append(&argv,"git","-c","user.name=Fixture","-c","user.email=fixture@localhost","-C",dir)
    append(&argv,..args)
    out,ok:=vcs_run(argv[:])
    testing.expectf(t,ok,"git %v failed: %s",args,out)
    trimmed:=strings.clone(strings.trim_space(out),context.temp_allocator)
    delete(out)
    return trimmed
}

@(test)
test_owner_agent_routing_only_owner_verbs_for_agent_tokens :: proc(t:^testing.T) {
    for method in ([8]string{"agent.lease.next","agent.lease.heartbeat","agent.lease.submit","agent.review.post","agent.task.show","agent.task.comment","agent.task_chain.show","agent.task_chain.set_summary"}) {
        testing.expectf(t,bridge_owner_routable(method),"%s is served by the owner when it holds the chain",method)
    }
    for method in ([5]string{"agent.chat.send","agent.memory.list","agent.task_chain.list","agent.workflow.run","agent.owner_local.lease"}) {
        testing.expectf(t,!bridge_owner_routable(method),"%s never consults the owner store",method)
    }
    rec:=Bridge_Local_Agent_Token_Record{agent_instance_id="inst_x",role=.Wrapper}
    _,handled:=bridge_owner_agent_route("r1","agent.lease.next","{}",rec)
    testing.expect(t,!handled,"wrapper tokens never reach owner authority")
    rec.role=.Agent
    _,handled=bridge_owner_agent_route("r2","agent.chat.send","{}",rec)
    testing.expect(t,!handled,"non-owner verbs fall through to the Hub route")
    p:=bridge_owner_params(`{"task_id":" t1 ","acknowledge_requirements_revision":3,"peek":true}`)
    testing.expect_value(t,bridge_owner_pstr(p,"task_id"),"t1")
    testing.expect_value(t,bridge_owner_pstr(p,"acknowledge_requirements_revision"),"3")
    testing.expect_value(t,len(bridge_owner_params("not json")),0)
}

@(test)
test_owner_claim_creates_task_worktree_and_task_md :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    root:=fmt.tprintf("%s/.cache/heimdall-tests/owner-routing-%d",os.get_env("HOME",context.temp_allocator),time.to_unix_nanoseconds(time.now()))
    testing.expect(t,bridge_make_directory_all(fmt.tprintf("%s/repo",root))==nil)
    testing.expect(t,bridge_make_directory_all(fmt.tprintf("%s/run",root))==nil)
    defer _=os.remove_all(root)
    repo:=bridge_fs_canonicalize_existing(fmt.tprintf("%s/repo",root));defer delete(repo)
    canonical_root:=bridge_fs_canonicalize_existing(root);defer delete(canonical_root)
    prior_root:=bridge_fs_root;bridge_fs_root=canonical_root;defer {bridge_fs_root=prior_root}
    owner_routing_git(t,repo,"init","-b","sandbox")
    testing.expect(t,os.write_entire_file(fmt.tprintf("%s/shared.txt",repo),transmute([]byte)string("base\n"))==nil)
    owner_routing_git(t,repo,"add",".")
    owner_routing_git(t,repo,"commit","-m","base")
    owner_routing_git(t,repo,"branch","integration")
    base:=owner_routing_git(t,repo,"rev-parse","integration")
    task:="task_routing"
    work:=fmt.tprintf("%s/.heimdall/worktrees/%s",repo,task)
    config:=owner.doc(map[string]string{"configuration_revision"="1","author_agent_id"="author","reviewer_agent_id"="reviewer","reviewer_instance_id"="review_instance",
        "directory_id"="directory","merge_policy"="git","repository"=repo,"worktree"=work,"source_branch"=fmt.tprintf("heimdall/%s",task),"target_branch"="integration","base_head"=base})
    testing.expect(t,!bridge_taskv2_is_checkout_root(work))
    testing.expect(t,!bridge_owner_paths(config,task),"submit/merge validation requires the worktree")
    testing.expect(t,bridge_owner_paths(config,task,allow_missing_worktree=true),"configuration accepts a not-yet-created, safe worktree path")
    testing.expect(t,!os.exists(fmt.tprintf("%s/.heimdall",repo)),"configuration validation creates nothing")
    testing.expect(t,bridge_owner_ensure_worktree(config,task),"claim creates the deterministic task worktree")
    testing.expect(t,bridge_taskv2_is_checkout_root(work))
    testing.expect_value(t,owner_routing_git(t,work,"symbolic-ref","--short","HEAD"),fmt.tprintf("heimdall/%s",task))
    testing.expect_value(t,owner_routing_git(t,work,"rev-parse","HEAD"),base)
    testing.expect(t,bridge_owner_paths(config,task),"the created checkout passes the owner path validation used by submit and merge")
    testing.expect(t,bridge_owner_ensure_worktree(config,task),"idempotent across attempts")
    excluded,_:=os.read_entire_file(fmt.tprintf("%s/.git/info/exclude",repo),context.temp_allocator)
    testing.expect(t,strings.contains(string(excluded),".heimdall/"),"the worktree stays out of the main checkout status")

    wrong:=owner.doc(map[string]string{"merge_policy"="git","repository"=repo,"worktree"=fmt.tprintf("%s/elsewhere",repo),"source_branch"=fmt.tprintf("heimdall/%s",task),"base_head"=base})
    testing.expect(t,!bridge_owner_ensure_worktree(wrong,task),"only repo/.heimdall/worktrees/<task> is ever created")
    testing.expect(t,!bridge_taskv2_is_checkout_root(fmt.tprintf("%s/elsewhere",repo)))
    none:=owner.doc(map[string]string{"merge_policy"="none"})
    testing.expect(t,bridge_owner_ensure_worktree(none,task),"no checkout for merge_policy none")

    placement:=bridge_owner_placement(config,true)
    testing.expect(t,placement.workdir==work && placement.directory_path==repo && placement.branch==fmt.tprintf("heimdall/%s",task))
    run:=fmt.tprintf("%s/run",root)
    command:=owner.doc(map[string]string{"chain_id"="chain","task_id"=task,"lease_id"="lease_routing","instance_id"="inst","workdir"=placement.workdir,"branch"=placement.branch})
    body:=owner.encode(owner.doc(map[string]string{"requirements_revision"="2","acknowledged"="0","brief"=`{"goal":"Ship it","acceptance":["Tests pass"]}`,"chain_summary"="summary","context_provenance"=`{"source_digest":"d"}`}))
    testing.expect(t,bridge_owner_materialize_context(run,command,body))
    md,read:=os.read_entire_file(fmt.tprintf("%s/TASK.md",run),context.temp_allocator)
    testing.expect(t,read==nil)
    text:=string(md)
    testing.expect(t,strings.contains(text,fmt.tprintf("Workdir: `%s` on branch `heimdall/%s`",work,task)),"TASK.md names the Workdir")
    testing.expect(t,strings.contains(text,"ham-ctl lease heartbeat --lease lease_routing --acknowledge-requirements-revision 2"),"TASK.md gives the exact ACK command")
    testing.expect(t,strings.contains(text,"Ship it") && strings.contains(text,"## Chain summary"))
    // A pending claim whose worktree cannot be created still writes TASK.md,
    // names the problem and reports it; the lease stays for the retry.
    broken_task:="task_broken"
    broken:=owner.doc(map[string]string{"merge_policy"="git","repository"=repo,"worktree"=fmt.tprintf("%s/.heimdall/worktrees/%s",repo,broken_task),"source_branch"=fmt.tprintf("heimdall/%s",broken_task),"target_branch"="integration","base_head"=strings.repeat("0",40,context.temp_allocator)})
    pending:=Owner_Pending_Delivery{active=true,config=broken,configured=true,task=broken_task,present_body=body,
        command=owner.doc(map[string]string{"chain_id"="chain","task_id"=broken_task,"lease_id"="lease_broken","instance_id"="inst","workdir"="x","branch"="y"})}
    reply:=bridge_owner_materialize("req",pending,run)
    testing.expect(t,strings.contains(reply,`"worktree_unavailable"`),"a failed checkout is reported, not hidden")
    failed_md,_:=os.read_entire_file(fmt.tprintf("%s/TASK.md",run),context.temp_allocator)
    testing.expect(t,strings.contains(string(failed_md),"Workdir: unavailable") && strings.contains(string(failed_md),"lease_broken"),"TASK.md says the Workdir is unavailable and how to retry")

    _=owner_routing_git(t,repo,"worktree","remove","--force",work)
}

@(test)
test_owner_worktree_refuses_symlinked_components_and_wrong_branch :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    root:=fmt.tprintf("%s/.cache/heimdall-tests/owner-worktree-safety-%d",os.get_env("HOME",context.temp_allocator),time.to_unix_nanoseconds(time.now()))
    testing.expect(t,bridge_make_directory_all(fmt.tprintf("%s/repo",root))==nil)
    testing.expect(t,bridge_make_directory_all(fmt.tprintf("%s/elsewhere",root))==nil)
    defer _=os.remove_all(root)
    repo:=bridge_fs_canonicalize_existing(fmt.tprintf("%s/repo",root));defer delete(repo)
    owner_routing_git(t,repo,"init","-b","sandbox")
    testing.expect(t,os.write_entire_file(fmt.tprintf("%s/f.txt",repo),transmute([]byte)string("base\n"))==nil)
    owner_routing_git(t,repo,"add",".")
    owner_routing_git(t,repo,"commit","-m","base")
    base:=owner_routing_git(t,repo,"rev-parse","HEAD")
    make_config :: proc(repo,task,base:string) -> json.Object {
        return owner.doc(map[string]string{"merge_policy"="git","repository"=repo,"worktree"=fmt.tprintf("%s/.heimdall/worktrees/%s",repo,task),
            "source_branch"=fmt.tprintf("heimdall/%s",task),"target_branch"="integration","base_head"=base})
    }
    // .heimdall is a symlink to a directory outside the repository.
    testing.expect(t,os.symlink(fmt.tprintf("%s/elsewhere",root),fmt.tprintf("%s/.heimdall",repo))==nil)
    testing.expect(t,!bridge_owner_worktree_path_safe(repo,"task_a"))
    testing.expect(t,!bridge_owner_ensure_worktree(make_config(repo,"task_a",base),"task_a"),"a symlinked .heimdall is refused before mkdir")
    entries,_:=os.read_all_directory_by_path(fmt.tprintf("%s/elsewhere",root),context.temp_allocator)
    testing.expect_value(t,len(entries),0)
    testing.expect(t,os.remove(fmt.tprintf("%s/.heimdall",repo))==nil)
    // worktrees/ itself a symlink.
    testing.expect(t,os.make_directory(fmt.tprintf("%s/.heimdall",repo))==nil)
    testing.expect(t,os.symlink(fmt.tprintf("%s/elsewhere",root),fmt.tprintf("%s/.heimdall/worktrees",repo))==nil)
    testing.expect(t,!bridge_owner_ensure_worktree(make_config(repo,"task_a",base),"task_a"),"a symlinked worktrees directory is refused")
    testing.expect(t,os.remove(fmt.tprintf("%s/.heimdall/worktrees",repo))==nil)
    // An existing worktree on another branch is refused, not reused.
    testing.expect(t,bridge_owner_ensure_worktree(make_config(repo,"task_a",base),"task_a"))
    owner_routing_git(t,fmt.tprintf("%s/.heimdall/worktrees/task_a",repo),"checkout","-b","other")
    testing.expect(t,!bridge_owner_ensure_worktree(make_config(repo,"task_a",base),"task_a"),"a branch mismatch is refused")
    // A plain directory squatting on the path is not adopted.
    testing.expect(t,os.make_directory(fmt.tprintf("%s/.heimdall/worktrees/task_b",repo))==nil)
    testing.expect(t,!bridge_owner_ensure_worktree(make_config(repo,"task_b",base),"task_b"),"a non-checkout directory is refused")
    _=owner_routing_git(t,repo,"worktree","remove","--force",fmt.tprintf("%s/.heimdall/worktrees/task_a",repo))
}

@(test)
test_executor_prepare_run_dir_creates_missing_instances_parent :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    root:=fmt.tprintf("%s/.cache/heimdall-tests/run-dir-%d",os.get_env("HOME",context.temp_allocator),time.to_unix_nanoseconds(time.now()))
    defer _=os.remove_all(root)
    run_dir:=fmt.tprintf("%s/local/instances/inst_fresh",root)
    testing.expect(t,!bridge_os_prepare_private_dir(run_dir),"the plain private mkdir is non-recursive (the fresh-Bridge failure)")
    testing.expect(t,bridge_executor_prepare_run_dir(run_dir),"native startup creates the missing instances parent")
    info,err:=os.lstat(run_dir,context.temp_allocator)
    testing.expect(t,err==nil && info.type==.Directory)
    testing.expect(t,bridge_executor_prepare_run_dir(run_dir),"idempotent for an existing run directory")
}

// H1: a deterministic worktree failure (symlink, squatting non-checkout,
// checkout on another branch) asks for the lease to be blocked at once; a
// retryable one only after OWNER_WORKTREE_MAX_FAILURES consecutive failures
// of the same lease, and a success resets the count.
@(test)
test_owner_materialize_blocks_on_deterministic_or_repeated_worktree_failure :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    defer bridge_owner_worktree_failure_clear()
    root:=fmt.tprintf("%s/.cache/heimdall-tests/owner-worktree-block-%d",os.get_env("HOME",context.temp_allocator),time.to_unix_nanoseconds(time.now()))
    testing.expect(t,bridge_make_directory_all(fmt.tprintf("%s/repo",root))==nil)
    testing.expect(t,bridge_make_directory_all(fmt.tprintf("%s/run",root))==nil)
    testing.expect(t,bridge_make_directory_all(fmt.tprintf("%s/plain",root))==nil)
    testing.expect(t,bridge_make_directory_all(fmt.tprintf("%s/elsewhere",root))==nil)
    defer _=os.remove_all(root)
    repo:=bridge_fs_canonicalize_existing(fmt.tprintf("%s/repo",root));defer delete(repo)
    plain:=bridge_fs_canonicalize_existing(fmt.tprintf("%s/plain",root));defer delete(plain)
    owner_routing_git(t,repo,"init","-b","sandbox")
    testing.expect(t,os.write_entire_file(fmt.tprintf("%s/f.txt",repo),transmute([]byte)string("base\n"))==nil)
    owner_routing_git(t,repo,"add",".")
    owner_routing_git(t,repo,"commit","-m","base")
    base:=owner_routing_git(t,repo,"rev-parse","HEAD")
    run:=fmt.tprintf("%s/run",root)
    body:=owner.encode(owner.doc(map[string]string{"requirements_revision"="1","acknowledged"="0","brief"=`{"goal":"g","acceptance":["a"]}`,"chain_summary"="s","context_provenance"=`{"source_digest":"d"}`}))
    pending :: proc(repo,task,base,lease,body:string) -> Owner_Pending_Delivery {
        config:=owner.doc(map[string]string{"merge_policy"="git","repository"=repo,"worktree"=fmt.tprintf("%s/.heimdall/worktrees/%s",repo,task),
            "source_branch"=fmt.tprintf("heimdall/%s",task),"target_branch"="integration","base_head"=base})
        return Owner_Pending_Delivery{active=true,config=config,configured=true,task=task,present_body=body,
            command=owner.doc(map[string]string{"chain_id"="chain","task_id"=task,"lease_id"=lease,"instance_id"="inst","workdir"="x","branch"="y"})}
    }
    // A plain directory squatting on the worktree path: deterministic.
    testing.expect(t,bridge_make_directory_all(fmt.tprintf("%s/.heimdall/worktrees/task_squat",repo))==nil)
    status,reason:=bridge_owner_prepare_worktree(pending(repo,"task_squat",base,"l1",body).config,"task_squat")
    testing.expect_value(t,status,Owner_Worktree_Status.Deterministic)
    testing.expect(t,strings.contains(reason,"not a git worktree checkout"),reason)
    reply,block:=bridge_owner_materialize_checked("r1",pending(repo,"task_squat",base,"l1",body),run)
    testing.expect(t,block!="" && strings.contains(block,"will not fix itself"),block)
    testing.expect(t,strings.contains(reply,`"worktree_unavailable"`) && strings.contains(reply,"blocked"),reply)
    md,_:=os.read_entire_file(fmt.tprintf("%s/TASK.md",run),context.temp_allocator)
    testing.expect(t,strings.contains(string(md),"Workdir: unavailable"),"TASK.md still says why")
    // A checkout on another branch: deterministic.
    testing.expect(t,bridge_owner_ensure_worktree(pending(repo,"task_branch",base,"l2",body).config,"task_branch"))
    owner_routing_git(t,fmt.tprintf("%s/.heimdall/worktrees/task_branch",repo),"checkout","-b","other")
    status,reason=bridge_owner_prepare_worktree(pending(repo,"task_branch",base,"l2",body).config,"task_branch")
    testing.expect(t,status==.Deterministic && strings.contains(reason,"branch other"),reason)
    _,block=bridge_owner_materialize_checked("r2",pending(repo,"task_branch",base,"l2",body),run)
    testing.expect(t,block!="")
    // A symlinked task path: deterministic.
    testing.expect(t,os.symlink(fmt.tprintf("%s/elsewhere",root),fmt.tprintf("%s/.heimdall/worktrees/task_link",repo))==nil)
    status,_=bridge_owner_prepare_worktree(pending(repo,"task_link",base,"l3",body).config,"task_link")
    testing.expect_value(t,status,Owner_Worktree_Status.Deterministic)
    // A repository that is not (yet) readable as git: retried, and blocked on
    // the third consecutive failure of the same lease.
    status,_=bridge_owner_prepare_worktree(pending(plain,"task_retry",base,"l4",body).config,"task_retry")
    testing.expect_value(t,status,Owner_Worktree_Status.Retry)
    for attempt in 1..=OWNER_WORKTREE_MAX_FAILURES {
        reply,block=bridge_owner_materialize_checked("r4",pending(plain,"task_retry",base,"l4",body),run)
        if attempt<OWNER_WORKTREE_MAX_FAILURES {
            testing.expectf(t,block=="","attempt %d is retried, not blocked",attempt)
            testing.expect(t,strings.contains(reply,"run lease next again") && strings.contains(reply,fmt.tprintf("attempt %d of %d",attempt,OWNER_WORKTREE_MAX_FAILURES)),reply)
        } else do testing.expect(t,block!="" && strings.contains(block,"3 consecutive attempts failed"),block)
    }
    // The count is per lease and a success resets it.
    _,block=bridge_owner_materialize_checked("r5",pending(plain,"task_retry",base,"l5",body),run)
    testing.expect(t,block=="","another lease starts its own count")
    _,block=bridge_owner_materialize_checked("r6",pending(plain,"task_retry",base,"l5",body),run)
    testing.expect(t,block=="")
    ok_reply,ok_block:=bridge_owner_materialize_checked("r7",pending(repo,"task_ok",base,"l5",body),run)
    testing.expect(t,ok_block=="" && !strings.contains(ok_reply,"worktree_unavailable"),ok_reply)
    _,block=bridge_owner_materialize_checked("r8",pending(plain,"task_retry",base,"l5",body),run)
    testing.expect(t,block=="","the success reset the consecutive-failure count")
    for task in ([2]string{"task_branch","task_ok"}) do _=owner_routing_git(t,repo,"worktree","remove","--force",fmt.tprintf("%s/.heimdall/worktrees/%s",repo,task))
}

// Only a git that ran and reported a detached HEAD is deterministic: a git
// that could not be spawned or timed out on `symbolic-ref` is retried. The
// runner intercepts only this test's unique worktree path, so parallel tests
// still reach the real runner.
owner_head_probe_path: string
owner_head_probe_timed_out: bool

@(test)
test_owner_prepare_worktree_detached_head_only_when_git_ran :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    root:=fmt.tprintf("%s/.cache/heimdall-tests/owner-worktree-head-%d",os.get_env("HOME",context.temp_allocator),time.to_unix_nanoseconds(time.now()))
    testing.expect(t,bridge_make_directory_all(fmt.tprintf("%s/repo",root))==nil)
    defer _=os.remove_all(root)
    repo:=bridge_fs_canonicalize_existing(fmt.tprintf("%s/repo",root));defer delete(repo)
    owner_routing_git(t,repo,"init","-b","sandbox")
    testing.expect(t,os.write_entire_file(fmt.tprintf("%s/f.txt",repo),transmute([]byte)string("base\n"))==nil)
    owner_routing_git(t,repo,"add",".")
    owner_routing_git(t,repo,"commit","-m","base")
    base:=owner_routing_git(t,repo,"rev-parse","HEAD")
    task:="task_head"
    work:=fmt.tprintf("%s/.heimdall/worktrees/%s",repo,task)
    config:=owner.doc(map[string]string{"merge_policy"="git","repository"=repo,"worktree"=work,
        "source_branch"=fmt.tprintf("heimdall/%s",task),"target_branch"="integration","base_head"=base})
    testing.expect(t,bridge_owner_ensure_worktree(config,task))
    status,reason:=bridge_owner_prepare_worktree(config,task)
    testing.expect(t,status==.Ok,reason)

    // Hold the runner lock across install -> use -> restore (also guards
    // owner_head_probe_path); defers run LIFO, so the runner is restored
    // before the lock is released.
    vcs_runner_test_lock()
    defer vcs_runner_test_unlock()
    owner_head_probe_path=work
    vcs_process_runner = proc(args: []string, timeout: time.Duration) -> (stdout, stderr: string, ok, timed_out: bool) {
        intercept:=false
        for a,i in args do if a=="-C" && i+1<len(args) && args[i+1]==owner_head_probe_path do intercept=true
        is_symbolic:=false
        for a in args do if a=="symbolic-ref" do is_symbolic=true
        if !intercept || !is_symbolic do return bridge_process_run_capture(args, timeout)
        return "", "", false, owner_head_probe_timed_out
    }
    defer vcs_process_runner = bridge_process_run_capture
    owner_head_probe_timed_out=false
    status,reason=bridge_owner_prepare_worktree(config,task)
    testing.expect(t,status==.Retry && strings.contains(reason,"not started or timed out"),reason)
    owner_head_probe_timed_out=true
    status,reason=bridge_owner_prepare_worktree(config,task)
    testing.expect(t,status==.Retry,reason)
    vcs_process_runner = bridge_process_run_capture

    owner_routing_git(t,work,"checkout","--detach")
    status,reason=bridge_owner_prepare_worktree(config,task)
    testing.expect(t,status==.Deterministic && strings.contains(reason,"detached HEAD"),reason)
    _=owner_routing_git(t,repo,"worktree","remove","--force",work)
}

// P-CS CC-A: coordinator controls are owner verbs mapped 1:1 to owner methods;
// authority itself is decided by the owner store (owner_local tests).
@(test)
test_owner_coordinator_controls_route_to_owner_methods :: proc(t:^testing.T) {
    pairs:=[?][2]string{
        {"agent.task.hold","task.hold"},{"agent.task.release","task.release"},{"agent.task.cancel","task.cancel"},
        {"agent.task.reopen","task.reopen"},{"agent.task.unblock","task.resolve"},{"agent.task.recheck","task.recheck"},
        {"agent.task.escalate","task.escalate"},{"agent.task.merge_retry","merge.retry"},{"agent.task.delete","task.delete"},
        {"agent.task.review_roles","review.roles"},{"agent.lease.revoke","lease.revoke"},{"agent.task_chain.complete","chain.complete"},
        {"agent.work.complete","chain.complete"},{"agent.workflow.retry","workflow.retry"},{"agent.workflow.cancel","workflow.cancel"},
        // P-CS CC-B work operations.
        {"agent.task.submit_review","lifecycle.force_submit"},{"agent.task.complete","task.complete"},{"agent.task.split","task.split"},
    }
    for pair in pairs {
        testing.expectf(t,bridge_owner_routable(pair[0]),"%s is served by the owner when it holds the chain",pair[0])
        testing.expectf(t,bridge_owner_control_method(pair[0])==pair[1],"%s maps to %s",pair[0],pair[1])
        testing.expectf(t,bridge_agent_method_allowed(pair[0]),"%s is dispatchable",pair[0])
    }
    // workflow.gate stays user-only; workflow.run keeps its Hub route.
    for m in ([3]string{"agent.workflow.gate","agent.workflow.run","agent.chain.policy"}) {
        testing.expectf(t,bridge_owner_control_method(m)=="","%s is not a coordinator control",m)
    }
    // revoke names a task; it is not routed by the caller's own lease.
    testing.expect(t,!bridge_owner_lease_method("agent.lease.revoke"))
    testing.expect(t,bridge_owner_lease_method("agent.lease.submit"))
    // On a chain this Bridge does not own the controls fail clearly.
    for m in ([6]string{"agent.task.cancel","agent.lease.revoke","agent.task.unblock","agent.task.submit_review","agent.task.complete","agent.task.split"}) {
        r:=bridge_agent_route(m,`{"task_id":"t1"}`)
        testing.expectf(t,r.kind==.Bad_Request && strings.contains(r.message,"owner_chain_only"),"%s on a Hub chain is a typed owner-only error",m)
    }
    // Reasons are required before anything is sealed or signed (R2-6).
    for m in ([6]string{"task.hold","task.release","task.cancel","task.reopen","task.resolve","lease.revoke"}) {
        _,missing:=bridge_owner_control_fields(m,bridge_owner_params(`{"task_id":"t1"}`))
        testing.expectf(t,missing!="","%s without a reason is refused",m)
    }
    unblock,missing:=bridge_owner_control_fields("task.resolve",bridge_owner_params(`{"note":"repo fixed"}`))
    testing.expect(t,missing=="" && unblock.reason=="repo fixed","unblock takes --note")
    recheck,_:=bridge_owner_control_fields("task.recheck",bridge_owner_params(`{}`))
    testing.expect_value(t,recheck.reason,"recheck")
    revoke,rm:=bridge_owner_control_fields("lease.revoke",bridge_owner_params(`{"reason":"stalled"}`))
    testing.expect(t,rm=="" && revoke.mode=="checkpoint" && revoke.disable_fleet=="0","revoke defaults to a checkpoint, fleet kept")
    revoke,rm=bridge_owner_control_fields("lease.revoke",bridge_owner_params(`{"reason":"reassign","stop":true,"disable_fleet":true}`))
    testing.expect(t,rm=="" && revoke.mode=="stop" && revoke.disable_fleet=="1")
    _,rm=bridge_owner_control_fields("lease.revoke",bridge_owner_params(`{"reason":"x","mode":"kill"}`))
    testing.expect(t,rm!="","unknown revoke mode refused")
    cancel,cm:=bridge_owner_control_fields("task.cancel",bridge_owner_params(`{"reason":"replaced","repoint":"t2"}`))
    testing.expect(t,cm=="" && cancel.dependents=="repoint:t2")
    cancel,cm=bridge_owner_control_fields("task.cancel",bridge_owner_params(`{"reason":"gone","dependents":"drop"}`))
    testing.expect(t,cm=="" && cancel.dependents=="drop")
    _,cm=bridge_owner_control_fields("task.cancel",bridge_owner_params(`{"reason":"x","dependents":"sideways"}`))
    testing.expect(t,cm!="","unknown dependents choice refused")
    _,cm=bridge_owner_control_fields("task.cancel",bridge_owner_params(`{"reason":"x","dependents":"drop","repoint":"t2"}`))
    testing.expect(t,cm!="","conflicting dependents flags refused")
}

// P-CS CC-B: submit-for-review, force-done and split need a reason; the split
// child file is validated and ids are generated before anything is signed.
@(test)
test_owner_coordinator_work_operations_require_reasons_and_valid_children :: proc(t:^testing.T) {
    for m in ([3]string{"lifecycle.force_submit","task.complete","task.split"}) {
        _,missing:=bridge_owner_control_fields(m,bridge_owner_params(`{"task_id":"t1"}`))
        testing.expectf(t,missing!="","%s without a reason is refused",m)
        fields,ok:=bridge_owner_control_fields(m,bridge_owner_params(`{"task_id":"t1","reason":"why"}`))
        testing.expectf(t,ok=="" && fields.reason=="why","%s takes --reason",m)
    }
    testing.expect(t,strings.contains(bridge_owner_control_refusal("lifecycle.force_submit","stale_revision"),"--override-ack"))
    testing.expect(t,strings.contains(bridge_owner_control_refusal("task.split","invalid_content"),"children"))
    ctx:Owner_Agent_Ctx
    observed:=make([dynamic]owner.Child,context.temp_allocator)
    st:owner.Agent_Task_State
    for bad in ([4]string{`{}`,`{"children":[]}`,`{"children":[{"body":"no title"}]}`,`{"children":[{"title":"a"}],"dependents":"sideways"}`}) {
        _,code,_:=bridge_owner_split_body(&ctx,st,bridge_owner_params(bad),"why",&observed)
        testing.expectf(t,code=="bad_request","%s refused",bad)
    }
    _,code,_:=bridge_owner_split_body(&ctx,st,bridge_owner_params(`{"children":[{"title":"a"}],"dependents":"map"}`),"why",&observed)
    testing.expect_value(t,code,"bad_request")
    body,ok_code,_:=bridge_owner_split_body(&ctx,st,bridge_owner_params(`{"children":[{"task_id":"c1","title":"a","description":"d","brief":{"goal":"g","acceptance":["x"]}},{"title":"b","unassigned":true}],"dependents":"last"}`),"why",&observed)
    testing.expect_value(t,ok_code,"ok")
    v,_:=json.parse_string(body,.JSON,true,context.temp_allocator)
    o,_:=v.(json.Object)
    children,_:=o["children"].(json.Array)
    if testing.expect_value(t,len(children),2) {
        first,_:=children[0].(json.Object);second,_:=children[1].(json.Object)
        testing.expect(t,bridge_owner_pstr(first,"task_id")=="c1" && bridge_owner_pstr(first,"body")=="d" && bridge_owner_pobj(first,"brief")!=nil)
        testing.expect(t,strings.has_prefix(bridge_owner_pstr(second,"task_id"),"task_"),"a missing child id is generated")
        flag,_:=second["unassigned"].(json.Boolean)
        testing.expect(t,bool(flag))
    }
    testing.expect(t,bridge_owner_pstr(o,"reason")=="why" && bridge_owner_pstr(o,"dependents")=="last")
}
