#+feature dynamic-literals
package main

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
    _=owner_routing_git(t,repo,"worktree","remove","--force",work)
}
