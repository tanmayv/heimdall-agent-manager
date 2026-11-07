#+feature dynamic-literals
package main

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:time"
import contracts "odin_test:contracts"
import owner "odin_test:lib/owner_local"

// argv-only, bounded existing VCS runner; suppress repository hooks/signing.
bridge_owner_git :: proc(repo:string,args:[]string) -> (string,bool) {
    argv:=make([dynamic]string,context.temp_allocator)
    append(&argv,"git","-c","core.hooksPath=/dev/null","-c","commit.gpgSign=false","-c","core.fsmonitor=false","-C",repo)
    append(&argv,..args)
    out,ok:=vcs_run(argv[:]);defer delete(out)
    return strings.clone(strings.trim_space(out),context.temp_allocator),ok
}
bridge_owner_paths :: proc(c:json.Object,task:string,check_target:=true) -> bool {
    get:=contracts.owner_string
    if get(c,"merge_policy")=="none" {
        return get(c,"repository")=="" && get(c,"worktree")=="" && get(c,"source_branch")=="" && get(c,"target_branch")=="" && get(c,"base_head")==""
    }
    repo,work:=get(c,"repository"),get(c,"worktree")
    if repo=="" || work!=fmt.tprintf("%s/.heimdall/worktrees/%s",repo,task) || get(c,"source_branch")!=fmt.tprintf("heimdall/%s",task) ||
       get(c,"target_branch")=="" || get(c,"base_head")=="" || get(c,"target_branch")==get(c,"source_branch") { return false }
    canonical,within:=bridge_fs_resolve_within(repo);defer delete(canonical)
    canonical_work,work_within:=bridge_fs_resolve_within(work);defer delete(canonical_work)
    if !within || !work_within || canonical!=repo || canonical_work!=work do return false
    for dir in ([2]string{repo,work}) {
        top,ok:=bridge_owner_git(dir,[]string{"rev-parse","--show-toplevel"})
        if !ok || top!=dir do return false
    }
    common,ok:=bridge_owner_git(repo,[]string{"rev-parse","--path-format=absolute","--git-common-dir"})
    other,other_ok:=bridge_owner_git(work,[]string{"rev-parse","--path-format=absolute","--git-common-dir"})
    if !ok || !other_ok || common!=other do return false
    configuration,config_ok:=bridge_owner_git(repo,[]string{"config","--list"})
    if !config_ok do return false
    for line in strings.split_lines_iterator(&configuration) {
        equal:=strings.index_byte(line,'=')
        if equal<0 do continue
        name:=line[:equal]
        if strings.has_prefix(name,"merge.") && strings.has_suffix(name,".driver") do return false
    }
    for ref in ([2]string{get(c,"source_branch"),get(c,"target_branch")}) {
        if _,ok:=bridge_owner_git(repo,[]string{"check-ref-format","--branch",ref});!ok do return false
    }
    source,source_ok:=bridge_owner_git(work,[]string{"symbolic-ref","--short","HEAD"})
    if !source_ok || source!=get(c,"source_branch") do return false
    base,base_ok:=bridge_owner_git(repo,[]string{"rev-parse","--verify",strings.concatenate({"refs/heads/",get(c,"target_branch"),"^{commit}"},context.temp_allocator)})
    if !base_ok || (check_target && base!=get(c,"base_head")) do return false
    // An atomic ref CAS must not leave a checked-out worktree inconsistent.
    // This bounded slice merges into an explicitly un-checked-out target ref.
    worktrees,list_ok:=bridge_owner_git(repo,[]string{"worktree","list","--porcelain"})
    if !list_ok || strings.contains(worktrees,fmt.tprintf("branch refs/heads/%s\n",get(c,"target_branch"))) ||
       strings.has_suffix(worktrees,fmt.tprintf("branch refs/heads/%s",get(c,"target_branch"))) { return false }
    return true
}
bridge_owner_config_proof :: proc(s:^owner.Store,c:json.Object,chain,task:string,create_worktree:=false) -> owner.Lifecycle_Proof {
    get:=contracts.owner_string
    rows,ok:=owner.query(s.db,"SELECT instance_id FROM local_fleet WHERE chain_id=? AND task_id=?",chain,task)
    if !ok || len(rows)!=1 do return {}
    author,aok:=bridge_owner_child_locked(rows[0][0],"")
    reviewer,rok:=bridge_owner_child_locked(get(c,"reviewer_instance_id"),"")
    if !aok || !rok do return {}
    valid:=true
    if get(c,"merge_policy")=="git" {
        launch,found:=bridge_runtime_get_launch(author.instance)
        if !found do return {}
        project:=bridge_fs_canonicalize_existing(launch.project_path);defer delete(project)
        valid=project==get(c,"repository") || project==get(c,"worktree")
        // Only for the author's own project repository, and only the exact
        // repo/.heimdall/worktrees/<task> path on heimdall/<task>.
        if valid && create_worktree && project==get(c,"repository") do _=bridge_owner_ensure_worktree(c,task)
    }
    valid=valid && bridge_owner_paths(c,task)
    return owner.Lifecycle_Proof{author,reviewer,valid}
}
bridge_owner_source_proof :: proc(s:^owner.Store,chain,task:string) -> owner.Source_Proof {
    config,_,ok:=owner.lifecycle_config(s,chain,task)
    if !ok do return {}
    if contracts.owner_string(config,"merge_policy")=="none" do return {"",true}
    if !bridge_owner_paths(config,task) do return {}
    work:=contracts.owner_string(config,"worktree")
    dirty,checked:=bridge_taskv2_git_dirty(work)
    if !checked || dirty do return {}
    head,found:=bridge_owner_git(work,[]string{"rev-parse","--verify","HEAD^{commit}"})
    if !found do return {}
    if _,ok:=bridge_owner_git(work,[]string{"merge-base",contracts.owner_string(config,"base_head"),head});!ok do return {}
    return {head,true}
}

bridge_owner_merge :: proc(s:^owner.Store,claim:owner.Intent_Claim) -> (bool,string,i64) {
    now:=time.to_unix_nanoseconds(time.now())/1000000
    if !owner.merge_claim_current(s,claim) do return false,"stale_merge",now
    c,ok:=contracts.owner_parse(claim.payload,"lifecycle_config_payload")
    f,valid:=contracts.owner_request_document(claim.fence);fence,obj:=f.(json.Object)
    if !ok || !valid || !obj do return false,"malformed_merge",now
    get:=contracts.owner_string
    repo,target,base,head:=get(c,"repository"),get(c,"target_branch"),get(c,"base_head"),get(fence,"head")
    // Revalidate containment/common directory/refs on every retry, even if the
    // ref already moved. Path validation also checks the expected target below.
    if !bridge_owner_paths(c,get(fence,"task_id"),false) do return false,"invalid_path",now
    current,read:=bridge_owner_git(repo,[]string{"rev-parse","--verify",strings.concatenate({"refs/heads/",target,"^{commit}"},context.temp_allocator)})
    if !read do return false,"target_unavailable",now
    prepared:=owner.merge_prepared(s,claim)
    if prepared!="" && current==prepared do return true,prepared,now
    if current!=base || !bridge_owner_paths(c,get(fence,"task_id")) do return false,"target_changed_or_invalid_path",now
    tip,tip_ok:=bridge_owner_git(repo,[]string{"rev-parse","--verify",strings.concatenate({"refs/heads/",get(c,"source_branch"),"^{commit}"},context.temp_allocator)})
    if !tip_ok || tip!=head do return false,"source_changed",now
    if _,ancestry:=bridge_owner_git(repo,[]string{"merge-base","--is-ancestor",base,head});!ancestry {
        // Divergent commits are merged using the real Git merge machinery.
        tree,merged:=bridge_owner_git(repo,[]string{"merge-tree","--write-tree",base,head})
        if !merged || !contracts.owner_field_valid(tree,"optional_commit") || tree=="" do return false,"merge_conflict",now
        if prepared=="" {
            commit,created:=bridge_owner_git(repo,[]string{"-c","user.name=Heimdall","-c","user.email=heimdall@localhost","commit-tree",tree,"-p",base,"-p",head,"-m",fmt.tprintf("Owner-local merge %s",claim.id)})
            if !created || !contracts.owner_field_valid(commit,"optional_commit") || commit=="" do return false,"merge_commit_failed",now
            prepared=commit
        }
    } else if prepared=="" { prepared=head }
    if !owner.merge_prepare(s,claim,prepared) do return false,"prepare_failed",now
    if _,updated:=bridge_owner_git(repo,[]string{"update-ref",fmt.tprintf("refs/heads/%s",target),prepared,base});!updated do return false,"target_cas_failed",now
    return true,prepared,now
}
