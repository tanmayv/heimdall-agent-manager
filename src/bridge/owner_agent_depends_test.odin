#+feature dynamic-literals
package main

import "core:crypto/ecdsa"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import owner "odin_test:lib/owner_local"
import vault "odin_test:lib/vault"

// iss_18e698cd6e61895c: `task create --depends-on` on an owner chain records
// every edge before the task can be claimed, refuses an unknown prerequisite
// without creating a task, and removes the new task again when an edge is
// refused, so a create never leaves a dependency-free task behind.
@(test)
test_owner_task_create_depends_on_is_atomic :: proc(t:^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex);defer sync.mutex_unlock(&bridge_test_config_mutex)
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    r:=new(Review_Test,context.temp_allocator)
    priv:ecdsa.Private_Key;defer ecdsa.private_key_clear(&priv)
    r.key=chain_create_test_key(t,&priv,"bridge","bridge_key")
    signer:=owner.Signer{&priv,chain_create_test_sign}
    old_daemon:=bridge_config.daemon_id;bridge_config.daemon_id="bridge"
    bridge_owner_test_signer=signer;bridge_owner_live_probe=review_test_probe
    review_test_live=make([dynamic]owner.Child,context.temp_allocator)
    defer {bridge_config.daemon_id=old_daemon;bridge_owner_test_signer={};bridge_owner_live_probe=nil;review_test_live=nil}
    r.root=fmt.tprintf("%s/.cache/heimdall-tests/owner-create-depends-%d",os.get_env("HOME",context.temp_allocator),time.to_unix_nanoseconds(time.now()))
    testing.expect(t,bridge_make_directory_all(r.root)==nil)
    defer _=os.remove_all(r.root)
    if !testing.expect(t,owner.open(&r.store,fmt.tprintf("%s/runtime.sqlite",r.root),"account","bridge","bridge_key")) do return
    defer owner.close(&r.store)
    vid,_:=vault.vault_id_from_root_sign_pub(r.key.public_key)
    secret:[32]byte;secret[0]=7
    r.kr,_=vault.keyring_from_single_key("account",vid,1,secret[:]);defer vault.keyring_wipe(&r.kr)

    chain:="chain_depends"
    now:=time.to_unix_nanoseconds(time.now())/1000000
    tc,_:=vault.seal_string("depends chain",&r.kr,context.temp_allocator)
    dc,_:=vault.seal_string("",&r.kr,context.temp_allocator)
    g,c,p,built:=bridge_owner_chain_create_documents("account","bridge","bridge_key",chain,"op_depends",tc,dc,now,signer)
    testing.expect(t,built)
    if !testing.expect_value(t,owner.execute(&r.store,c,p,g,r.key,r.key,0,"",now,&r.kr,signer,requested_by="inst_c").code,"ok") do return
    coord:=review_test_child("inst_c","agt_c")
    if !testing.expect_value(t,owner.bind_created_coordinator(&r.store,chain,coord,"inst_c",now).code,"ok") do return
    worker,reviewer:=review_test_child("inst_w","agt_w"),review_test_child("inst_a","agt_a")
    append(&review_test_live,coord,worker,reviewer)
    for m in ([2]owner.Child{worker,reviewer}) {
        ctx:=review_test_ctx(r,coord)
        joined:=bridge_owner_fleet_member(&ctx,chain,m.instance,m.agent_id,"worker",true,m).code
        testing.expectf(t,joined=="ok","%s joins the chain: %s",m.agent_id,joined)
    }
    create :: proc(r:^Review_Test,coord:owner.Child,chain,title,extra:string) -> (string,json.Object) {
        out,_:=review_test_exec(r,coord,"agent.task.create",fmt.tprintf(`{{"chain_id":"%s","title":"%s"%s}}`,chain,title,extra))
        return contracts.owner_string(review_test_data(out),"task_id"),out
    }
    count :: proc(r:^Review_Test,chain:string) -> string {
        rows,_:=owner.query(r.store.db,"SELECT count(*) FROM tasks WHERE chain_id=?",chain)
        return rows[0][0] if len(rows)==1 else ""
    }

    // A backlog prerequisite (unassigned, never started).
    prereq,_:=create(r,coord,chain,"prerequisite","")
    if !testing.expect(t,prereq!="","backlog prerequisite created") do return
    other,_:=create(r,coord,chain,"other","")
    if !testing.expect(t,other!="","second backlog task created") do return

    // The dependent is assigned in the same create; a repeated id is one edge.
    assigned:=`,"brief":{"goal":"Ship it","acceptance":["Tests pass"]},"assignee":"agt_w","reviewers":["agt_a"]`
    dependent,out:=create(r,coord,chain,"dependent",fmt.tprintf(`%s,"depends_on":["%s","%s"]`,assigned,prereq,prereq))
    if !testing.expectf(t,dependent!="","create with --depends-on: %v",out) do return
    st,_,_:=owner.agent_task_state(&r.store,chain,dependent)
    testing.expectf(t,len(st.dependencies)==1 && st.dependencies[0]==prereq,"the edge exists after create: %v",st.dependencies)
    held,_:=review_test_exec(r,worker,"agent.lease.next","{}")
    testing.expectf(t,contracts.owner_string(review_test_data(held),"status")=="none","the dependent is not leasable while its prerequisite is in the backlog: %v",held)
    // Control: the same assignment without a prerequisite is leased at once.
    free,_:=create(r,coord,chain,"free",assigned)
    granted,_:=review_test_exec(r,worker,"agent.lease.next","{}")
    lease,_:=review_test_data(granted)["lease"].(json.Object)
    testing.expectf(t,free!="" && contracts.owner_string(lease,"task_id")==free,"an unblocked task is leased: %v",granted)

    // An unknown prerequisite fails clearly and creates no task.
    before:=count(r,chain)
    missing,refused:=create(r,coord,chain,"orphan",`,"depends_on":["task_missing"]`)
    testing.expectf(t,missing=="" && strings.contains(fmt.tprint(refused),"task_missing is not a task of this chain"),"unknown prerequisite refused: %v",refused)
    testing.expect_value(t,count(r,chain),before)

    // task depend: an unknown prerequisite is named; a repeated edge is kept.
    unknown,_:=review_test_exec(r,coord,"agent.task.depend",fmt.tprintf(`{{"chain_id":"%s","task_id":"%s","depends_on_task_id":"task_missing"}}`,chain,dependent))
    testing.expectf(t,strings.contains(fmt.tprint(unknown),"task_missing is not a task of this chain"),"depend on an unknown task: %v",unknown)
    again,_:=review_test_exec(r,coord,"agent.task.depend",fmt.tprintf(`{{"chain_id":"%s","task_id":"%s","depends_on_task_id":"%s"}}`,chain,dependent,prereq))
    testing.expectf(t,contracts.owner_string(review_test_data(again),"depends_on_task_id")==prereq,"repeated depend is a no-op: %v",again)

    // A refused edge (the second one) removes the first and the new task.
    testing.expect(t,owner.exec(r.store.db,fmt.tprintf("CREATE TEMP TRIGGER refuse_edge BEFORE INSERT ON main.local_dependencies WHEN NEW.prerequisite='%s' BEGIN SELECT RAISE(ABORT,'refused'); END",other)))
    rolled,failed:=create(r,coord,chain,"rolled back",fmt.tprintf(`,"depends_on":["%s","%s"]`,prereq,other))
    testing.expectf(t,rolled=="" && strings.contains(fmt.tprint(failed),"no task created"),"refused edge: %v",failed)
    testing.expect_value(t,count(r,chain),before)
    edges,_:=owner.query(r.store.db,"SELECT count(*) FROM local_dependencies WHERE chain_id=?",chain)
    testing.expect_value(t,edges[0][0],"1")
}
