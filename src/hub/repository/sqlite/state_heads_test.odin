package sqlite

import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

@(test)
test_state_heads_upgrade_isolation_and_rollback :: proc(t: ^testing.T) {
 conn, opened, _ := open(":memory:")
 if !testing.expect(t,opened) do return
 defer close(&conn)
 ok, _ := run_migrations(&conn,stop_before="events_008_state_heads.sql")
 if !testing.expect(t,ok) do return
 testing.expect(t,sqlite_object_exists(&conn,"event_entity_versions"))
 testing.expect(t,!sqlite_object_exists(&conn,"event_state_heads"))
 ok, _ = run_migrations(&conn)
 if !testing.expect(t,ok) do return
 testing.expect(t,sqlite_object_exists(&conn,"event_state_heads"))
 impl: Event_Outbox_Repo_SQLite
 repos := iface.Repositories{event_outbox=new_event_outbox_repository(&impl,&conn)}
 factory_impl: SQLite_Unit_Of_Work_Factory
 factory := new_unit_of_work_factory(&factory_impl,&conn,&repos)
 repo := &repos.event_outbox
 testing.expect(t,repo.set_state_head(repo.ctx,"owner","memory","m","memory.state","one",1).code!=.None)
 uow,began,_ := iface.unit_of_work_begin(&factory)
 if !testing.expect(t,began) do return
 testing.expect_value(t,repo.set_state_head(repo.ctx,"owner","memory","m","memory.state","one",1).code,domain.Error_Code.None)
 _,_ = iface.unit_of_work_commit(&uow)
 uow,began,_ = iface.unit_of_work_begin(&factory)
 if !testing.expect(t,began) do return
 current,err := repo.state_head_matches(repo.ctx,"owner","memory","m","memory.state","one")
 testing.expect(t,current && err.code==.None)
 for key in ([][4]string{{"other","memory","m","memory.state"},{"owner","task","m","memory.state"},{"owner","memory","other","memory.state"},{"owner","memory","m","other.state"}}) {
  current,err=repo.state_head_matches(repo.ctx,key[0],key[1],key[2],key[3],"one")
  testing.expect(t,!current && err.code==.None)
 }
 testing.expect_value(t,repo.set_state_head(repo.ctx,"owner","memory","m","memory.state","two",2).code,domain.Error_Code.None)
 current,err=repo.state_head_matches(repo.ctx,"owner","memory","m","memory.state","one")
 testing.expect(t,!current && err.code==.None)
 iface.unit_of_work_rollback(&uow)
 uow,began,_ = iface.unit_of_work_begin(&factory)
 if !testing.expect(t,began) do return
 defer iface.unit_of_work_rollback(&uow)
 current,err=repo.state_head_matches(repo.ctx,"owner","memory","m","memory.state","one")
 testing.expect(t,current && err.code==.None,"rollback retains committed head")
}
