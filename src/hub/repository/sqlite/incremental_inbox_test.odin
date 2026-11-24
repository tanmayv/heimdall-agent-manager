package sqlite

import "core:fmt"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

@(test)
test_incremental_inbox_terminal_retirement_and_cleanup :: proc(t:^testing.T) {
 conn,opened,_:=open(":memory:")
 if !testing.expect(t,opened) do return
 defer close(&conn)
 migrated,_:=run_migrations(&conn)
 if !testing.expect(t,migrated) do return
 // Exercise the migration's one-time upgrade sweep as well as live triggers.
 testing.expect(t,exec(&conn,"DROP TRIGGER event_inbox_terminal_chain; DROP TRIGGER event_inbox_terminal_insert;"))
 for state in ([]string{"active","completed","cancelled","archived"}) {
  testing.expect(t,exec(&conn,fmt.tprintf("INSERT INTO task_chains(chain_id,owner_user_id,title,status,kind,created_at,updated_at) VALUES('%s','alice','test','%s','mixed_work','now','now');",state,state)))
  for source in ([]string{"explicit","role_default"}) {
   testing.expect(t,exec(&conn,fmt.tprintf("INSERT INTO event_subscriptions(subscription_id,owner_user_id,subscriber_agent_id,subscriber_instance_id,chain_id,source,filter_subjects,wake_policy,consumer_name,created_at) VALUES('%s_%s','alice','agent','inst','%s','%s','[]','catalog','%s_%s','now');",state,source,state,source,state,source)))
  }
 }
 // Execute the actual shipped upgrade sweep, not a duplicate test predicate.
 testing.expect_value(t,instance_sub_scalar(&conn,"SELECT COUNT(*) FROM event_subscriptions;"),i64(8))
 migration := string(MIGRATION_EVENTS_009_INCREMENTAL_INBOX)
 sweep_at := strings.index(migration,"DELETE FROM event_subscriptions WHERE EXISTS(")
 sweep := migration[sweep_at:]
 sweep_end := strings.index(sweep,";")+1
 testing.expect(t,exec(&conn,sweep[:sweep_end]))
 testing.expect_value(t,instance_sub_scalar(&conn,"SELECT COUNT(*) FROM event_subscriptions;"),i64(4))
 testing.expect_value(t,instance_sub_scalar(&conn,"SELECT COUNT(*) FROM event_consumer_deletions;"),i64(4))
 testing.expect_value(t,instance_sub_scalar(&conn,"SELECT COUNT(*) FROM event_subscriptions WHERE source='explicit' AND chain_id IN ('completed','cancelled');"),i64(2))
 // Restore shipped live triggers using only their definitions.
 for name in ([]string{"event_inbox_terminal_chain","event_inbox_terminal_insert"}) {
  start:=strings.index(MIGRATION_EVENTS_009_INCREMENTAL_INBOX,fmt.tprintf("CREATE TRIGGER %s",name))
  rest:=migration[start:]
  end:=strings.index(rest,"END;")+4
  testing.expect(t,exec(&conn,rest[:end]))
 }
 testing.expect(t,exec(&conn,"UPDATE task_chains SET status='cancelled' WHERE chain_id='active';"))
 testing.expect_value(t,instance_sub_scalar(&conn,"SELECT COUNT(*) FROM event_subscriptions WHERE chain_id='active' AND source='role_default';"),i64(0))
 testing.expect_value(t,instance_sub_scalar(&conn,"SELECT COUNT(*) FROM event_subscriptions WHERE chain_id='active' AND source='explicit';"),i64(1))
 testing.expect(t,exec(&conn,"UPDATE task_chains SET status='archived' WHERE chain_id='active';"))
 testing.expect_value(t,instance_sub_scalar(&conn,"SELECT COUNT(*) FROM event_subscriptions WHERE chain_id='active';"),i64(0))
 testing.expect_value(t,instance_sub_scalar(&conn,"SELECT COUNT(*) FROM event_consumer_deletions;"),i64(6))
 impl:Event_Subscription_Repo_SQLite
 repo:=new_event_subscription_repository(&impl,&conn)
 repos:=iface.Repositories{event_subscriptions=repo}
 fi:SQLite_Unit_Of_Work_Factory
 factory:=new_unit_of_work_factory(&fi,&conn,&repos)
 count:=0
 install_inbox_notifications(&conn,&count,proc(ctx:rawptr){(^int)(ctx)^+=1})
 uow,began,_:=iface.unit_of_work_begin(&factory)
 if !testing.expect(t,began) do return
 testing.expect_value(t,repo.put(repo.ctx,{subscription_id="late",owner_user_id="alice",subscriber_instance_id="inst",chain_id="completed",source="role_default",filter_subjects="[]",consumer_name="late",created_at="now"}).code,domain.Error_Code.None)
 testing.expect_value(t,instance_sub_scalar(&conn,"SELECT COUNT(*) FROM event_subscriptions WHERE subscription_id='late';"),i64(0))
 testing.expect_value(t,repo.put(repo.ctx,{subscription_id="watch",owner_user_id="alice",subscriber_instance_id="other",chain_id="completed",source="explicit",filter_subjects="[]",consumer_name="watch",created_at="now"}).code,domain.Error_Code.None)
 testing.expect_value(t,count,0)
 iface.unit_of_work_commit(&uow)
 testing.expect_value(t,count,1)

 uow,began,_=iface.unit_of_work_begin(&factory)
 testing.expect(t,began)
 testing.expect_value(t,repo.put(repo.ctx,{subscription_id="archived_watch",owner_user_id="alice",subscriber_instance_id="new_watch",chain_id="active",source="explicit",filter_subjects="[]",consumer_name="archived_watch",created_at="now"}).code,domain.Error_Code.Conflict)
 iface.unit_of_work_rollback(&uow)
 // Rollbacks and rolled-back nested savepoints must not emit a commit wake.
 count=0
 uow,began,_=iface.unit_of_work_begin(&factory)
 testing.expect(t,began)
 nested,nbegan,_:=iface.unit_of_work_begin(&factory)
 testing.expect(t,nbegan)
 testing.expect_value(t,repo.put(repo.ctx,{subscription_id="rollback",owner_user_id="alice",subscriber_instance_id="rollback",chain_id="completed",source="explicit",filter_subjects="[]",consumer_name="rollback",created_at="now"}).code,domain.Error_Code.None)
 iface.unit_of_work_rollback(&nested)
 iface.unit_of_work_commit(&uow)
 testing.expect_value(t,count,0)
 // Reopening a chain reinstates its current role without reviving removed watches.
 testing.expect(t,instance_sub_add_instance(&conn,"inst_coord","agent"))
 testing.expect(t,exec(&conn,"INSERT INTO task_chain_members(chain_id,owner_user_id,agent_id,agent_instance_id,role,created_at) VALUES('active','alice','agent','inst_coord','coordinator','now');"))
 testing.expect_value(t,instance_sub_scalar(&conn,"SELECT COUNT(*) FROM event_subscriptions WHERE chain_id='active';"),i64(0))
 testing.expect(t,exec(&conn,"UPDATE task_chains SET status='active' WHERE chain_id='active';"))
 testing.expect_value(t,instance_sub_scalar(&conn,"SELECT COUNT(*) FROM event_subscriptions WHERE chain_id='active' AND source='role_default';"),i64(1))
}
