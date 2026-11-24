package sqlite
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

Event_Webhook_Repo_SQLite :: struct { conn:^Conn }
new_event_webhook_repository :: proc(impl:^Event_Webhook_Repo_SQLite,conn:^Conn)->iface.Event_Webhook_Repository {
 impl.conn=conn
 return {ctx=impl,get=event_webhook_get,list=event_webhook_list,save=event_webhook_save,remove=event_webhook_remove,record_received=event_webhook_record_received}
}
event_webhook_record_received :: proc(ctx:rawptr,id,at:string)->domain.Domain_Error {
 stmt,e:=event_webhook_prepare(ctx,"UPDATE event_webhooks SET last_received_at=? WHERE webhook_id=?;")
 if e.code!=.None do return e
 defer sqlite3_finalize(stmt)
 bind_text(stmt,1,at);bind_text(stmt,2,id)
 if sqlite3_step(stmt)!=SQLITE_DONE do return domain.domain_error(.Internal_Error,"could not record webhook receipt")
 return {}
}
event_webhook_prepare :: proc(ctx:rawptr,sql:cstring)->(sqlite3_stmt,domain.Domain_Error) {
 impl:=(^Event_Webhook_Repo_SQLite)(ctx)
 proxy:=Event_Outbox_Repo_SQLite{conn=impl.conn}
 return outbox_prepare(&proxy,sql)
}
event_webhook_row :: proc(stmt:sqlite3_stmt)->domain.Event_Webhook {
 return {webhook_id=column_text(stmt,0),owner_user_id=column_text(stmt,1),name=column_text(stmt,2),
 token_hash=column_text(stmt,3),enabled=sqlite3_column_int64(stmt,4)!=0,
 created_at=column_text(stmt,5),updated_at=column_text(stmt,6),last_received_at=column_text(stmt,7)}
}
event_webhook_get :: proc(ctx:rawptr,id:string)->(domain.Event_Webhook,bool,domain.Domain_Error) {
 stmt,e:=event_webhook_prepare(ctx,"SELECT webhook_id,owner_user_id,name,token_hash,enabled,created_at,updated_at,last_received_at FROM event_webhooks WHERE webhook_id=?;")
 if e.code!=.None do return {},false,e
 defer sqlite3_finalize(stmt)
 bind_text(stmt,1,id)
 rc:=sqlite3_step(stmt)
 if rc==SQLITE_DONE do return {},false,{}
 if rc!=SQLITE_ROW do return {},false,domain.domain_error(.Internal_Error,"could not read webhook")
 return event_webhook_row(stmt),true,{}
}
event_webhook_list :: proc(ctx:rawptr,owner:string)->([]domain.Event_Webhook,domain.Domain_Error) {
 stmt,e:=event_webhook_prepare(ctx,"SELECT webhook_id,owner_user_id,name,token_hash,enabled,created_at,updated_at,last_received_at FROM event_webhooks WHERE owner_user_id=? ORDER BY webhook_id;")
 if e.code!=.None do return nil,e
 defer sqlite3_finalize(stmt)
 bind_text(stmt,1,owner)
 rows:=make([dynamic]domain.Event_Webhook)
 for {
  rc:=sqlite3_step(stmt)
  if rc==SQLITE_DONE do return rows[:],{}
  if rc!=SQLITE_ROW {domain.event_webhooks_destroy(rows[:]);return nil,domain.domain_error(.Internal_Error,"could not list webhooks")}
  append(&rows,event_webhook_row(stmt))
 }
}
event_webhook_save :: proc(ctx:rawptr,row:domain.Event_Webhook)->domain.Domain_Error {
 stmt,e:=event_webhook_prepare(ctx,"INSERT INTO event_webhooks(webhook_id,owner_user_id,name,token_hash,enabled,created_at,updated_at,last_received_at) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(webhook_id) DO UPDATE SET name=excluded.name,token_hash=excluded.token_hash,enabled=excluded.enabled,updated_at=excluded.updated_at,last_received_at=excluded.last_received_at;")
 if e.code!=.None do return e
 defer sqlite3_finalize(stmt)
 bind_text(stmt,1,row.webhook_id);bind_text(stmt,2,row.owner_user_id);bind_text(stmt,3,row.name);bind_text(stmt,4,row.token_hash)
 sqlite3_bind_int(stmt,5,1 if row.enabled else 0)
 bind_text(stmt,6,row.created_at);bind_text(stmt,7,row.updated_at);bind_text(stmt,8,row.last_received_at)
 if sqlite3_step(stmt)!=SQLITE_DONE do return domain.domain_error(.Internal_Error,"could not save webhook")
 return {}
}
event_webhook_remove :: proc(ctx:rawptr,id:string)->domain.Domain_Error {
 stmt,e:=event_webhook_prepare(ctx,"DELETE FROM event_webhooks WHERE webhook_id=?;")
 if e.code!=.None do return e
 defer sqlite3_finalize(stmt)
 bind_text(stmt,1,id)
 if sqlite3_step(stmt)!=SQLITE_DONE do return domain.domain_error(.Internal_Error,"could not delete webhook")
 return {}
}
