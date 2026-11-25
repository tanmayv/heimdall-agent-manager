package sqlite
import "core:testing"
import "core:strings"
import iface "odin_test:hub/repository/iface"
import domain "odin_test:hub/domain"
@(test)
test_webhook_dedupe_header_upgrade :: proc(t:^testing.T) {
 conn,ok,_:=open(":memory:")
 if !testing.expect(t,ok) do return
 defer close(&conn)
 migrated,_:=run_migrations(&conn,stop_before="webhooks_002_dedupe_header.sql")
 if !testing.expect(t,migrated) do return
 testing.expect(t,exec(&conn,"INSERT INTO event_webhooks(webhook_id,owner_user_id,token_hash,created_at,updated_at) VALUES('wh_old','owner','hash','then','then');"))
 migrated,_=run_migrations(&conn)
 if !testing.expect(t,migrated) do return
 impl:Event_Webhook_Repo_SQLite
 repo:=new_event_webhook_repository(&impl,&conn)
 repos:iface.Repositories
 factory_impl:SQLite_Unit_Of_Work_Factory
 factory:=new_unit_of_work_factory(&factory_impl,&conn,&repos)
 u,began,_:=iface.unit_of_work_begin(&factory)
 if !testing.expect(t,began) do return
 defer iface.unit_of_work_rollback(&u)
 row,found,e:=repo.get(repo.ctx,"wh_old")
 if !testing.expect(t,found && e.code==.None) do return
 defer domain.event_webhook_destroy(&row)
 testing.expect_value(t,row.dedupe_header,"Idempotency-Key")
 delete(row.dedupe_header)
 row.dedupe_header=strings.clone("Svix-Id")
 testing.expect_value(t,repo.save(repo.ctx,row).code,domain.Error_Code.None)
 saved,exists,se:=repo.get(repo.ctx,"wh_old")
 defer domain.event_webhook_destroy(&saved)
 testing.expect(t,exists && se.code==.None)
 testing.expect_value(t,saved.dedupe_header,"Svix-Id")
 testing.expect_value(t,saved.token_hash,"hash")
}
