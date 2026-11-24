package iface
import domain "odin_test:hub/domain"
// Operations require a unit of work. Reads return caller-owned rows.
Event_Webhook_Repository :: struct {
 ctx: rawptr,
 get: proc(ctx:rawptr,id:string)->(domain.Event_Webhook,bool,domain.Domain_Error),
 list: proc(ctx:rawptr,owner:string)->([]domain.Event_Webhook,domain.Domain_Error),
 save: proc(ctx:rawptr,row:domain.Event_Webhook)->domain.Domain_Error,
 record_received: proc(ctx:rawptr,id,at:string)->domain.Domain_Error,
 remove: proc(ctx:rawptr,id:string)->domain.Domain_Error,
}
