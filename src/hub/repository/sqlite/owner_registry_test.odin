package sqlite
import "core:testing"
import "core:fmt"
import domain "odin_test:hub/domain"

@(test)
owner_registry_is_immutable_account_scoped_and_monotonic :: proc(t:^testing.T) {
    conn,opened,_:=open(":memory:")
    if !testing.expect(t,opened) do return
    defer close(&conn)
    migrated,_:=run_migrations(&conn)
    if !testing.expect(t,migrated) do return
    impl:Taskchain_Repo_SQLite
    repo:=new_taskchain_repository(&impl,&conn)
    r:=domain.Owner_Registry_Record{account_id="a",chain_id="chain",owner_bridge_id="owner",owner_key_id="key",creator_id="device",genesis_digest="digest",genesis_json="signed-genesis",registry_json="protected-v1",metadata_revision=1}
    testing.expect_value(t,repo.owner_registry_publish(repo.ctx,r).code,domain.Error_Code.None)
    testing.expect_value(t,repo.owner_registry_publish(repo.ctx,r).code,domain.Error_Code.None)
    r.registry_json="changed"
    testing.expect_value(t,repo.owner_registry_publish(repo.ctx,r).code,domain.Error_Code.Conflict)
    r.metadata_revision=2
    testing.expect_value(t,repo.owner_registry_publish(repo.ctx,r).code,domain.Error_Code.None)
    r.metadata_revision=1;r.registry_json="old"
    testing.expect_value(t,repo.owner_registry_publish(repo.ctx,r).code,domain.Error_Code.None)
    rows,e:=repo.owner_registry_list(repo.ctx,"a","chain","","",10,false)
    testing.expect_value(t,e.code,domain.Error_Code.None)
    testing.expect_value(t,len(rows),1)
    if len(rows)==1 {
        testing.expect_value(t,rows[0].registry_json,"changed")
        testing.expect_value(t,rows[0].metadata_revision,i64(2))
    }
    for &row in rows do owner_registry_destroy(&row)
    delete(rows)
    rows,e=repo.owner_registry_list(repo.ctx,"b","chain","","",10,false)
    testing.expect_value(t,len(rows),0);delete(rows)
    r.account_id="b"
    testing.expect_value(t,repo.owner_registry_publish(repo.ctx,r).code,domain.Error_Code.Conflict)
    r.account_id="a";r.genesis_digest="conflicting-genesis"
    testing.expect_value(t,repo.owner_registry_publish(repo.ctx,r).code,domain.Error_Code.Conflict)
    r.genesis_digest="digest";r.owner_key_id="other-key"
    testing.expect_value(t,repo.owner_registry_publish(repo.ctx,r).code,domain.Error_Code.Conflict)
    r.owner_key_id="key";r.owner_bridge_id="another"
    testing.expect_value(t,repo.owner_registry_publish(repo.ctx,r).code,domain.Error_Code.Conflict)
}

@(test)
owner_registry_header_discovery_is_not_truncated_by_task_titles :: proc(t:^testing.T) {
    conn,opened,_:=open(":memory:")
    if !testing.expect(t,opened) do return
    defer close(&conn)
    migrated,_:=run_migrations(&conn)
    if !testing.expect(t,migrated) do return
    impl:Taskchain_Repo_SQLite
    repo:=new_taskchain_repository(&impl,&conn)
    r:=domain.Owner_Registry_Record{account_id="a",chain_id="chain",owner_bridge_id="owner",owner_key_id="key",creator_id="device",genesis_digest="digest",genesis_json="signed-genesis",registry_json="protected-header",metadata_revision=1}
    testing.expect_value(t,repo.owner_registry_publish(repo.ctx,r).code,domain.Error_Code.None)
    for i in 0..<110 {
        r.task_id=fmt.tprintf("task_%03d",i)
        r.registry_json="protected-task"
        testing.expect_value(t,repo.owner_registry_publish(repo.ctx,r).code,domain.Error_Code.None)
    }
    r.chain_id="z_chain";r.task_id="";r.registry_json="other-header"
    testing.expect_value(t,repo.owner_registry_publish(repo.ctx,r).code,domain.Error_Code.None)
    rows,err:=repo.owner_registry_list(repo.ctx,"a","","","",101,true)
    testing.expect_value(t,err.code,domain.Error_Code.None)
    testing.expect_value(t,len(rows),2)
    if len(rows)==2 do testing.expect(t,rows[0].chain_id=="chain" && rows[1].chain_id=="z_chain" && rows[0].task_id=="" && rows[1].task_id=="")
    for &row in rows do owner_registry_destroy(&row)
    delete(rows)
    rows,err=repo.owner_registry_list(repo.ctx,"a","","chain","",101,true)
    testing.expect(t,len(rows)==1 && rows[0].chain_id=="z_chain")
    for &row in rows do owner_registry_destroy(&row)
    delete(rows)
    rows,err=repo.owner_registry_list(repo.ctx,"b","","","",101,true)
    testing.expect_value(t,len(rows),0)
    delete(rows)
}
