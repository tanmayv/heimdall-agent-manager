#+build !windows
package main
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import executor "odin_test:lib/executor_local"

bridge_executor_bootstrap_test_material :: proc()->executor.Launch_Material {
    value,_:=contracts.owner_content_document(#load("../contracts/fixtures/executor-child-v1.json",string));f,_:=value.(json.Object)
    b,_:=contracts.executor_parse(contracts.owner_string(f,"bootstrap"),"bootstrap")
    c,_:=contracts.owner_parse(contracts.owner_string(f,"configuration"),"remote_configuration")
    secret:="executor-local-test-secret"
    generation:=contracts.owner_payload_digest(secret)
    b["token_generation"]=json.String(generation);c["token_generation"]=json.String(generation)
    config:=executor.encode(c)
    b["configuration_digest"]=json.String(contracts.owner_payload_digest(config))
    return {executor.encode(b),contracts.owner_string(f,"body"),config,secret}
}
@(test)
test_executor_bootstrap_materializes_owner_content_without_hub_and_local_shim :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    sync.mutex_lock(&bridge_test_config_mutex);defer sync.mutex_unlock(&bridge_test_config_mutex)
    providers:=[]Bridge_Catalog_Provider{{provider="codex",state="active",skill_dir=".agents/skills"}}
    snapshot:=Bridge_Provider_Catalog_Snapshot{providers=providers}
    sync.rw_mutex_lock(&bridge_provider_catalog_mutex)
    saved,loaded:=bridge_provider_catalog_snapshot,bridge_provider_catalog_loaded
    bridge_provider_catalog_snapshot=&snapshot;bridge_provider_catalog_loaded=true
    sync.rw_mutex_unlock(&bridge_provider_catalog_mutex)
    defer {
        sync.rw_mutex_lock(&bridge_provider_catalog_mutex)
        bridge_provider_catalog_snapshot=saved;bridge_provider_catalog_loaded=loaded
        sync.rw_mutex_unlock(&bridge_provider_catalog_mutex)
    }
    prev,had:=os.lookup_env("HEIMDALL_HAM_CTL_BIN",context.temp_allocator)
    defer {if had {_=os.set_env("HEIMDALL_HAM_CTL_BIN",prev)} else {os.unset_env("HEIMDALL_HAM_CTL_BIN")}}
    _=os.set_env("HEIMDALL_HAM_CTL_BIN","/bin/sh")
    dir:=fmt.tprintf("%s/.cache/heimdall-tests/bootstrap-material-%d",os.get_env("HOME",context.temp_allocator),time.to_unix_nanoseconds(time.now()))
    defer bridge_prespawn_rmdir_all(dir)
    bridge_prespawn_test_write(t,dir,"stale.txt","old")
    material:=bridge_executor_bootstrap_test_material()
    result,ok:=bridge_executor_materialize(dir,"unix:/test-executor.sock",material,"codex")
    if !testing.expect(t,ok) do return
    defer bridge_prespawn_result_delete(result)
    bridge_prespawn_test_absent(t,dir,"stale.txt","stale bootstrap removed before first dispatch")
    instructions,read:=os.read_entire_file(fmt.tprintf("%s/%s",dir,bridge_bootstrap_agents_md_name("codex")),context.temp_allocator)
    testing.expect(t,read==nil && strings.contains(string(instructions),"模型🚀"))
    task,task_read:=os.read_entire_file(fmt.tprintf("%s/TASK.md",dir),context.temp_allocator)
    testing.expect(t,task_read==nil && string(task)=="# Assigned task")
    skill:=bridge_bootstrap_skill_relative_path("codex","worker");defer delete(skill)
    skills,skill_read:=os.read_entire_file(fmt.tprintf("%s/%s",dir,skill),context.temp_allocator)
    testing.expect(t,skill_read==nil && strings.contains(string(skills),"模型🚀"))
    shim,shim_read:=os.read_entire_file(fmt.tprintf("%s/bin/ham-ctl",dir),context.temp_allocator)
    testing.expect(t,shim_read==nil && strings.contains(string(shim),"executor-local-test-secret") && strings.contains(string(shim),"unix:/test-executor.sock"))
    marker,marker_read:=os.read_entire_file(fmt.tprintf("%s/heimdall-executor-bootstrap.json",dir),context.temp_allocator)
    testing.expect(t,marker_read==nil && string(marker)==material.bootstrap && !strings.contains(string(marker),material.token_secret))
    testing.expect(t,bridge_prespawn_test_env_has(result.env,"HEIMDALL_AGENT_TOKEN=executor-local-test-secret"))
}
@(test)
test_executor_bootstrap_denies_content_substitution_and_planted_root_symlink :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    dir:=fmt.tprintf("%s/.cache/heimdall-tests/bootstrap-reject-%d",os.get_env("HOME",context.temp_allocator),time.to_unix_nanoseconds(time.now()))
    target:=fmt.tprintf("%s-target",dir)
    defer bridge_prespawn_rmdir_all(dir);defer bridge_prespawn_rmdir_all(target)
    material:=bridge_executor_bootstrap_test_material()
    changed:=material;changed.body="{}"
    _,ok:=bridge_executor_materialize(dir,"unix:/endpoint",changed,"codex")
    testing.expect(t,!ok)
    testing.expect(t,!os.exists(dir),"reject metadata before filesystem mutation")
    testing.expect(t,bridge_make_directory_all(target)==nil)
    bridge_prespawn_test_write(t,target,"keep.txt","untouched")
    testing.expect(t,os.symlink(target,dir)==nil)
    defer _=os.remove(dir)
    _,ok=bridge_executor_materialize(dir,"unix:/endpoint",material,"codex")
    testing.expect(t,!ok,"planted root symlink rejected")
    keep,kept:=os.read_entire_file(fmt.tprintf("%s/keep.txt",target),context.temp_allocator)
    testing.expect(t,kept==nil && string(keep)=="untouched")
}
