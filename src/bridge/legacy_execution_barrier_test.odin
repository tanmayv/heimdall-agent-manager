package main

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import executor "odin_test:lib/executor_local"

bridge_legacy_test_store :: proc(t:^testing.T)->(^executor.Store,string) {
    path:=fmt.tprintf("%s/.cache/heimdall-tests/legacy-physical-%d.sqlite",bridge_env_get("HOME",context.temp_allocator),time.to_unix_nanoseconds(time.now()))
    s:=new(executor.Store,context.temp_allocator)
    if !testing.expect(t,executor.open(s,path,"account","executor","operator")) do testing.fail_now(t,"legacy physical journal")
    return s,path
}
bridge_legacy_test_close :: proc(s:^executor.Store,path:string) {
    executor.close(s)
    for ext in ([4]string{"","-wal","-shm",".writer"}) do _=os.remove(fmt.tprintf("%s%s",path,ext))
}

Legacy_Test_Placement :: struct {directory_path,workdir,branch:string}
bridge_legacy_test_pack :: proc(repo,workdir,task,branch:string,nested:bool=false)->string {
    place:=Legacy_Test_Placement{repo,workdir,branch}
    if nested {
        return executor.encode(struct{task_id:string,lease:struct{placement:Legacy_Test_Placement}}{task,{place}})
    }
    return executor.encode(struct{task_id:string,placement:Legacy_Test_Placement}{task,place})
}

@(test)
bridge_legacy_pack_fences_actual_workdir_before_git_or_task_md :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    repo,ok:=vcs_test_git_repo("legacy_pack");defer vcs_test_rm(repo)
    if !testing.expect(t,ok) do return
    vcs_test_write(repo,"README.md","base\n")
    if !testing.expect(t,vcs_test_git("git","-C",repo,"add","README.md") && vcs_test_git("git","-C",repo,"commit","-m","init")) do return
    s,path:=bridge_legacy_test_store(t);defer bridge_legacy_test_close(s,path)
    workdir:=fmt.tprintf("%s/.heimdall/worktrees/task_pack",repo)
    canonical:=bridge_fs_canonicalize_existing(workdir);defer delete(canonical)
    barrier:=executor.Legacy_Barrier{"source_chain","migration",contracts.owner_payload_digest("selection"),1}
    testing.expect_value(t,bridge_legacy_install_barrier(s,barrier,[]executor.Legacy_Resource{{"workdir_hash",contracts.owner_payload_digest(canonical)}}).code,"ok")
    pack:=bridge_legacy_test_pack(repo,workdir,"claimed_other_task","heimdall/task_pack")
    run_dir:=fmt.tprintf("%s/run",repo)
    testing.expect(t,!bridge_legacy_apply_pack(s,"unfenced_instance",run_dir,pack))
    testing.expect(t,!os.exists(workdir) && !os.exists(run_dir) && !bridge_taskv2_branch_exists(repo,"heimdall/task_pack"),"actual pack target is fenced independent of claimed task or instance")
    // Nested placement uses the same actual-target guard.
    nested:=bridge_legacy_test_pack(repo,workdir,"claimed_other_task","heimdall/task_pack",nested=true)
    testing.expect(t,!bridge_legacy_apply_pack(s,"unfenced_instance",run_dir,nested))
    normal_workdir:=fmt.tprintf("%s/.heimdall/worktrees/task_normal",repo)
    normal:=bridge_legacy_test_pack(repo,normal_workdir,"task_normal","heimdall/task_normal")
    testing.expect(t,bridge_legacy_apply_pack(s,"unfenced_instance",run_dir,normal))
    testing.expect(t,os.exists(fmt.tprintf("%s/README.md",normal_workdir)) && os.exists(fmt.tprintf("%s/TASK.md",run_dir)),"normal unfenced worktree and task context still materialize")
    before,before_err:=os.read_entire_file(fmt.tprintf("%s/TASK.md",run_dir),context.temp_allocator)
    testing.expect(t,before_err==nil)
    canonical_run:=bridge_fs_canonicalize_existing(run_dir);defer delete(canonical_run)
    run_barrier:=executor.Legacy_Barrier{"run_source","run_migration",contracts.owner_payload_digest("run selection"),1}
    testing.expect_value(t,bridge_legacy_install_barrier(s,run_barrier,[]executor.Legacy_Resource{{"workdir_hash",contracts.owner_payload_digest(canonical_run)}}).code,"ok")
    testing.expect(t,!bridge_legacy_apply_pack(s,"other_instance",run_dir,`{"task_id":"different_task"}`),"actual context directory is protected even without placement")
    after,after_err:=os.read_entire_file(fmt.tprintf("%s/TASK.md",run_dir),context.temp_allocator)
    testing.expect(t,after_err==nil && string(before)==string(after),"fenced context remains byte-identical")
}
