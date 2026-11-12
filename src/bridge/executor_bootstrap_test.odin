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
    prev,had:=bridge_env_lookup("HEIMDALL_HAM_CTL_BIN",context.temp_allocator)
    defer {if had {bridge_test_env_set("HEIMDALL_HAM_CTL_BIN",prev)} else {bridge_test_env_unset("HEIMDALL_HAM_CTL_BIN")}}
    bridge_test_env_set("HEIMDALL_HAM_CTL_BIN","/bin/sh")
    dir:=fmt.tprintf("%s/.cache/heimdall-tests/bootstrap-material-%d",bridge_env_get("HOME",context.temp_allocator),time.to_unix_nanoseconds(time.now()))
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
    // G1: the standard skills a local agent gets, from this Bridge's build.
    for local in BRIDGE_EXECUTOR_SKILLS {
        path:=bridge_bootstrap_skill_relative_path("codex",local.name);defer delete(path)
        written,local_read:=os.read_entire_file(fmt.tprintf("%s/%s",dir,path),context.temp_allocator)
        testing.expectf(t,local_read==nil && string(written)==local.content,"standard skill %s written",local.name)
    }
    shim,shim_read:=os.read_entire_file(fmt.tprintf("%s/bin/ham-ctl",dir),context.temp_allocator)
    testing.expect(t,shim_read==nil && strings.contains(string(shim),"executor-local-test-secret") && strings.contains(string(shim),"unix:/test-executor.sock"))
    marker,marker_read:=os.read_entire_file(fmt.tprintf("%s/heimdall-executor-bootstrap.json",dir),context.temp_allocator)
    testing.expect(t,marker_read==nil && string(marker)==material.bootstrap && !strings.contains(string(marker),material.token_secret))
    testing.expect(t,bridge_prespawn_test_env_has(result.env,"HEIMDALL_AGENT_TOKEN=executor-local-test-secret"))
}
@(test)
test_executor_bootstrap_denies_content_substitution_and_planted_root_symlink :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    dir:=fmt.tprintf("%s/.cache/heimdall-tests/bootstrap-reject-%d",bridge_env_get("HOME",context.temp_allocator),time.to_unix_nanoseconds(time.now()))
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

@(test)
test_executor_bootstrap_notification_identity_ignores_local_token_store :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    material:=bridge_executor_bootstrap_test_material()
    b,parsed:=contracts.executor_parse(material.bootstrap,"bootstrap")
    if !testing.expect(t,parsed) do return
    env:=make([][2]string,4)
    env[0]={strings.clone("KEEP"),strings.clone("value")}
    env[1]={strings.clone("HEIMDALL_NOTIFICATION_EPOCH"),strings.clone("forged_epoch")}
    env[2]={strings.clone("HEIMDALL_NOTIFICATION_RUN_COUNT"),strings.clone("999")}
    env[3]={strings.clone("HEIMDALL_NOTIFICATION_EPOCH"),strings.clone("duplicate_epoch")}
    request:=Pty_Host_Spawn_Request{instance=strings.clone(contracts.owner_string(b,"instance_id")),env=env}
    defer bridge_pty_host_spawn_request_delete(request)
    // A token mismatch must leave the request untouched.
    testing.expect(t,!bridge_executor_bind_notification_spawn(&request,b,"replacement-secret"))
    testing.expect(t,len(request.env)==4 && request.env[1][1]=="forged_epoch")
    wrong:=request;wrong.instance="replacement_instance"
    testing.expect(t,!bridge_executor_bind_notification_spawn(&wrong,b,material.token_secret))
    testing.expect(t,bridge_executor_bind_notification_spawn(&request,b,material.token_secret))
    testing.expect(t,len(request.env)==4 && request.env[0][0]=="KEEP" && request.env[0][1]=="value")
    epochs,counts:=0,0
    for pair in request.env {
        if pair[0]=="HEIMDALL_NOTIFICATION_EPOCH" {
            epochs+=1
            testing.expect_value(t,pair[1],contracts.owner_string(b,"launch_epoch"))
        }
        if pair[0]=="HEIMDALL_NOTIFICATION_RUN_COUNT" {
            counts+=1
            testing.expect_value(t,pair[1],contracts.owner_string(b,"run_count"))
        }
    }
    testing.expect(t,epochs==1 && counts==1,"exactly one identity from the admitted remote bootstrap")
}

// G1: the owner sends the remote agent the normal role instructions (not a
// stub), naming its own task and lease and how ham-ctl reaches the owner.
@(test)
test_executor_owner_agents_md_is_the_role_template :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    p:=make(json.Object,context.temp_allocator)
    for v in ([5][2]string{{"purpose","work"},{"instance_id","inst_r"},{"task_id","task_r"},{"lease_id","lease_r"},{"chain_id","chain_r"}}) do p[v[0]]=json.String(v[1])
    worker:=bridge_owner_executor_agents_md(p,"brg_owner")
    testing.expect(t,strings.contains(worker,BRIDGE_OWNER_REMOTE_WORKER_MD) && strings.contains(worker,"Agent: worker") &&
        strings.contains(worker,"task_r") && strings.contains(worker,"lease_r") && strings.contains(worker,"brg_owner") && strings.contains(worker,"worker-task-management") &&
        strings.contains(worker,"Chat is not available to agents running on a remote Bridge") && strings.contains(worker,"task comment"))
    p["purpose"]=json.String("review")
    reviewer:=bridge_owner_executor_agents_md(p,"brg_owner")
    testing.expect(t,strings.contains(reviewer,BRIDGE_OWNER_REMOTE_REVIEWER_MD) && strings.contains(reviewer,"Agent: reviewer") && strings.contains(reviewer,"remote_chat_unavailable"))
    // Role instructions plus the largest expected TASK.md stay under the
    // owner's bootstrap document cap.
    testing.expect(t,len(worker)<contracts.EXECUTOR_DOCUMENT_MAX/3 && len(reviewer)<contracts.EXECUTOR_DOCUMENT_MAX/3)
}
