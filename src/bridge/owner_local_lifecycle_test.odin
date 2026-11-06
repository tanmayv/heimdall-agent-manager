#+feature dynamic-literals
package main
import "core:fmt"
import "core:os"
import "core:time"
import "core:testing"
import "core:encoding/json"
import owner "odin_test:lib/owner_local"

@(test)
test_owner_local_lifecycle_real_git_paths :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    repo,ok:=vcs_test_git_repo("owner-lifecycle-paths");defer vcs_test_rm(repo)
    if !testing.expect(t,ok) do return
    old_root:=bridge_fs_root;bridge_fs_root="/tmp";defer {bridge_fs_root=old_root}
    vcs_test_write(repo,"shared.txt","base\n")
    testing.expect(t,vcs_test_git("git","-C",repo,"add","."))
    testing.expect(t,vcs_test_git("git","-C",repo,"commit","-m","base"))
    testing.expect(t,vcs_test_git("git","-C",repo,"branch","integration"))
    work:=fmt.tprintf("%s/.heimdall/worktrees/task_local",repo)
    testing.expect(t,vcs_test_git("git","-C",repo,"worktree","add","-b","heimdall/task_local",work))
    base,read:=bridge_owner_git(repo,[]string{"rev-parse","HEAD"});testing.expect(t,read)
    c:=owner.doc(map[string]string{"merge_policy"="git","repository"=repo,"worktree"=work,"source_branch"="heimdall/task_local","target_branch"="integration","base_head"=base})
    testing.expect(t,bridge_owner_paths(c,"task_local"),"canonical same-repo worktree and un-checked-out target accepted")
    // Execute a real durable merge, lose its result, reopen the owner, and
    // recover the exact prepared ref update without merging twice.
    vcs_test_write(work,"feature.txt","submitted\n")
    testing.expect(t,vcs_test_git("git","-C",work,"add","."))
    testing.expect(t,vcs_test_git("git","-C",work,"commit","-m","submitted"))
    head,head_ok:=bridge_owner_git(work,[]string{"rev-parse","HEAD"});testing.expect(t,head_ok)
    c["configuration_revision"]=json.String("1");c["author_agent_id"]=json.String("author")
    c["reviewer_agent_id"]=json.String("reviewer");c["reviewer_instance_id"]=json.String("review_instance");c["directory_id"]=json.String("directory")
    path:=fmt.tprintf("%s/.cache/heimdall-tests/owner-merge-recovery-%d.sqlite",os.get_env("HOME",context.temp_allocator),time.to_unix_nanoseconds(time.now()))
    store:owner.Store
    if !testing.expect(t,owner.open(&store,path,"account","bridge","bridge_key")) do return
    defer {
        owner.close(&store)
        for suffix in ([4]string{"","-wal","-shm",".writer"}) do _=os.remove(fmt.tprintf("%s%s",path,suffix))
    }
    testing.expect(t,owner.exec(store.db,`INSERT INTO task_chains VALUES('chain','device','device','title','description',1);
      INSERT INTO tasks VALUES('chain','task_local','title','body',1);
      INSERT INTO task_requirements VALUES('chain','task_local',1,'{}','cipher','device','requirements');
      INSERT INTO lifecycle_state(chain_id,task_id,state,attempt) VALUES('chain','task_local','merge_pending',1);
      INSERT INTO command_receipts VALUES('review_instance','review','chain','task_local','review.post','digest','bridge_key',2000,'reviewed',1,1000);
      UPDATE runtime_database SET commit_seq=1;`))
    _,inserted:=owner.query(store.db,"INSERT INTO lifecycle_configs VALUES('chain','task_local',1,?,'signed config','device','config','{}','{}')",owner.encode(c))
    testing.expect(t,inserted)
    fence:=owner.encode(owner.doc(map[string]string{"task_id"="task_local","attempt"="1","requirements_revision"="1","head"=head,"configuration_revision"="1"}))
    tx:owner.Transaction
    testing.expect(t,owner.transaction_begin(&store,&tx))
    testing.expect(t,owner.intent_enqueue(&tx,owner.Intent_Input{chain="chain",principal="review_instance",operation="review",seq=1,kind="merge",fence=fence,payload=owner.encode(c)}))
    testing.expect(t,owner.transaction_commit(&tx))
    claims,claimed:=owner.intent_claim_due(&store,1000)
    if !testing.expect(t,claimed && len(claims)==1) do return
    original:=claims[0]
    success,result,_:=bridge_owner_merge(&store,original)
    testing.expect(t,success && result==head,"actual Git CAS succeeds")
    owner.close(&store)
    testing.expect(t,owner.open(&store,path,"account","bridge","bridge_key"))
    claims,claimed=owner.intent_claim_due(&store,1000)
    if !testing.expect(t,claimed && len(claims)==1) do return
    recovered:=claims[0]
    testing.expect(t,recovered.id==original.id && recovered.digest==original.digest && recovered.attempt==original.attempt+1)
    success,result,_=bridge_owner_merge(&store,recovered)
    testing.expect(t,success && result==head,"lost merge result recovers exact prepared commit after owner restart")
    testing.expect(t,owner.intent_result(&store,recovered,true,result,1000))
    rows,read_back:=owner.query(store.db,"SELECT state,merge_receipt,(SELECT commit_seq FROM runtime_database),(SELECT count(*) FROM local_changes) FROM lifecycle_state")
    testing.expect(t,read_back && rows[0][0]=="done" && rows[0][1]==head && rows[0][2]=="2" && rows[0][3]=="1","merge receipt, intent settlement and change sequence fold together")
    testing.expect(t,vcs_test_git("git","-C",repo,"config","merge.custom.driver","false"))
    testing.expect(t,!bridge_owner_paths(c,"task_local"),"custom shell merge drivers reject")
    testing.expect(t,vcs_test_git("git","-C",repo,"config","--unset","merge.custom.driver"))
    c["target_branch"]=json.String("main")
    testing.expect(t,!bridge_owner_paths(c,"task_local"),"checked-out target rejected")
}
