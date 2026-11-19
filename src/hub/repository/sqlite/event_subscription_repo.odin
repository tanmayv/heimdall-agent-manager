package sqlite

import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

Event_Subscription_Repo_SQLite :: struct {
 conn: ^Conn,
}

new_event_subscription_repository :: proc(impl: ^Event_Subscription_Repo_SQLite, conn: ^Conn) -> iface.Event_Subscription_Repository {
 impl.conn = conn
 return {ctx = impl, put = subscription_put, list = subscription_list, remove = subscription_remove}
}

subscription_prepare :: proc(ctx: rawptr, query: cstring) -> (sqlite3_stmt, domain.Domain_Error) {
 impl := (^Event_Subscription_Repo_SQLite)(ctx)
 if impl == nil || impl.conn == nil || impl.conn.db == nil || !outbox_uow_owns(impl.conn) {
  return nil, domain.domain_error(.Internal_Error, "event subscriptions require a unit of work")
 }
 stmt: sqlite3_stmt
 if sqlite3_prepare_v2(impl.conn.db, query, -1, &stmt, nil) != SQLITE_OK {
  return nil, domain.domain_error(.Internal_Error, "failed to prepare event subscription query")
 }
 return stmt, {}
}

subscription_put :: proc(ctx: rawptr, row: domain.Event_Subscription) -> domain.Domain_Error {
 stmt, err := subscription_prepare(ctx,
  "INSERT INTO event_subscriptions(subscription_id,owner_user_id,subscriber_agent_id,chain_id,task_id,source,filter_subjects,wake_policy,consumer_name,created_at) VALUES(?,?,?,?,NULLIF(?,''),?,?,?,?,?) ON CONFLICT DO NOTHING;")
 if err.code != .None do return err
 defer sqlite3_finalize(stmt)
 bind_text(stmt, 1, row.subscription_id); bind_text(stmt, 2, row.owner_user_id)
 bind_text(stmt, 3, row.subscriber_agent_id); bind_text(stmt, 4, row.chain_id)
 bind_text(stmt, 5, row.task_id); bind_text(stmt, 6, row.source)
 bind_text(stmt, 7, row.filter_subjects); bind_text(stmt, 8, row.wake_policy)
 bind_text(stmt, 9, row.consumer_name); bind_text(stmt, 10, row.created_at)
 if sqlite3_step(stmt) != SQLITE_DONE do return domain.domain_error(.Internal_Error, "failed to store event subscription")
 return {}
}

subscription_list :: proc(ctx: rawptr, owner, agent: string) -> ([]domain.Event_Subscription, domain.Domain_Error) {
 stmt, err := subscription_prepare(ctx,
  "SELECT subscription_id,owner_user_id,subscriber_agent_id,chain_id,COALESCE(task_id,''),source,filter_subjects,wake_policy,consumer_name,created_at FROM event_subscriptions WHERE owner_user_id=? AND subscriber_agent_id=? ORDER BY subscription_id;")
 if err.code != .None do return nil, err
 defer sqlite3_finalize(stmt)
 bind_text(stmt, 1, owner); bind_text(stmt, 2, agent)
 rows := make([dynamic]domain.Event_Subscription)
 for {
  rc := sqlite3_step(stmt)
  if rc == SQLITE_DONE do return rows[:], {}
  if rc != SQLITE_ROW {
   for &row in rows do domain.event_subscription_destroy(&row)
   delete(rows)
   return nil, domain.domain_error(.Internal_Error, "failed to list event subscriptions")
  }
  append(&rows, domain.Event_Subscription{
   subscription_id = column_text(stmt, 0), owner_user_id = column_text(stmt, 1),
   subscriber_agent_id = column_text(stmt, 2), chain_id = column_text(stmt, 3),
   task_id = column_text(stmt, 4), source = column_text(stmt, 5),
   filter_subjects = column_text(stmt, 6), wake_policy = column_text(stmt, 7),
   consumer_name = column_text(stmt, 8), created_at = column_text(stmt, 9),
  })
 }
}

subscription_remove :: proc(ctx: rawptr, owner, agent, subscription_id: string) -> domain.Domain_Error {
 stmt, err := subscription_prepare(ctx,
  "DELETE FROM event_subscriptions WHERE owner_user_id=? AND subscriber_agent_id=? AND subscription_id=?;")
 if err.code != .None do return err
 defer sqlite3_finalize(stmt)
 bind_text(stmt, 1, owner); bind_text(stmt, 2, agent); bind_text(stmt, 3, subscription_id)
 if sqlite3_step(stmt) != SQLITE_DONE do return domain.domain_error(.Internal_Error, "failed to remove event subscription")
 return {}
}
