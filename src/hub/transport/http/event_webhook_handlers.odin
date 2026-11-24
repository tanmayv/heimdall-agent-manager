package http

import "core:encoding/json"
import "base:runtime"
import "core:strings"
import "core:sync"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import device_auth "odin_test:hub/service/device_auth"
import webhooks "odin_test:hub/service/webhooks"

Event_Webhook_Handlers :: struct {
 actions:^Action_Handlers,
 service:^webhooks.Service,
 trusted_cidrs:[]string,
 limiter:Event_Webhook_Limiter,
}
Event_Webhook_Limiter :: struct {
 mutex:sync.Mutex,
 window:i64,
 total:int,
 bad,authed:map[string]int,
}
event_webhook_limiter_clear :: proc(l:^Event_Webhook_Limiter) {
 for key in l.bad do delete(key,runtime.heap_allocator())
 for key in l.authed do delete(key,runtime.heap_allocator())
 clear(&l.bad);clear(&l.authed);l.total=0
}
event_webhook_limiter_destroy :: proc(l:^Event_Webhook_Limiter) {
 event_webhook_limiter_clear(l);delete(l.bad);delete(l.authed);l.bad=nil;l.authed=nil
}
event_webhook_window :: proc(l:^Event_Webhook_Limiter,now:i64) {
 if l.window!=now/60 {event_webhook_limiter_clear(l);l.window=now/60}
}
event_webhook_increment :: proc(m:^map[string]int,key:string) {
 if m^==nil do m^=make(map[string]int,runtime.heap_allocator())
 if n,ok:=m^[key];ok {m^[key]=n+1} else {m^[strings.clone(key,runtime.heap_allocator())]=1}
}
event_webhook_pre_auth :: proc(h:^Event_Webhook_Handlers,ip:string,now:i64)->bool {
 l:=&h.limiter;sync.mutex_lock(&l.mutex);defer sync.mutex_unlock(&l.mutex)
 event_webhook_window(l,now)
 limits:=webhooks.effective_limits(h.service)
 if l.total>=limits.pre_auth_per_minute || l.bad[ip]>=limits.failed_auth_per_ip do return false
 l.total+=1
 return true
}
event_webhook_bad_auth :: proc(h:^Event_Webhook_Handlers,ip:string,now:i64) {
 l:=&h.limiter;sync.mutex_lock(&l.mutex);defer sync.mutex_unlock(&l.mutex)
 event_webhook_window(l,now);event_webhook_increment(&l.bad,ip)
}
event_webhook_admit :: proc(ctx:rawptr,id:string)->bool {
 h:=(^Event_Webhook_Handlers)(ctx)
 l:=&h.limiter;sync.mutex_lock(&l.mutex);defer sync.mutex_unlock(&l.mutex)
 event_webhook_window(l,i64(time.tick_since(time.Tick{}))/i64(time.Second))
 if l.authed[id]>=webhooks.effective_limits(h.service).per_webhook_per_minute do return false
 event_webhook_increment(&l.authed,id)
 return true
}
// Called by the server immediately after parsing, and by router entry points for
// in-process callers. Only this private field carries the secret to ingress.
event_webhook_redact :: proc(req:Request)->Request {
 out:=req
 if !strings.has_prefix(req.path,"/api/v1/hooks/") do return out
 tail:=req.path[len("/api/v1/hooks/"):]
 slash:=strings.index_byte(tail,'/')
 if slash<0 do return out
 if !req.hook_redacted {
  out.hook_token=tail[slash+1:]
  out.path=strings.concatenate({"/api/v1/hooks/",tail[:slash],"/[redacted]"})
  out.raw_target=out.path
  out.query=""
  out.hook_redacted=true
 }
 return out
}
event_webhook_status :: proc(status:int,body:string)->Response {
 return {status=status,content_type="application/json",body=body}
}
event_webhook_unauthorized :: proc()->Response {return event_webhook_status(401,`{"error":"unauthorized"}`)}
event_webhook_limited :: proc()->Response {
 response:=event_webhook_status(429,`{"error":"rate_limited"}`)
 response.headers=[]contracts.HTTP_Header{{name="Retry-After",value="60"}}
 return response
}
event_webhook_receive_handler :: proc(ctx:rawptr,req:Request)->Response {
 return event_webhook_receive(ctx,req)
}
// actor is supplied only by the owner-authenticated agent relay, never HTTP input.
event_webhook_receive :: proc(ctx:rawptr,req:Request,actor:="")->Response {
 h:=(^Event_Webhook_Handlers)(ctx)
 safe:=event_webhook_redact(req)
 now:=i64(time.tick_since(time.Tick{}))/i64(time.Second)
 ip:=device_auth.resolve_client_ip(safe.remote_addr,header_value(safe.headers,"X-Forwarded-For"),h.trusted_cidrs)
 if !event_webhook_pre_auth(h,ip,now) do return event_webhook_limited()
 if len(safe.body)>webhooks.effective_limits(h.service).body_bytes do return event_webhook_status(413,`{"error":"body_too_large"}`)
 token:=safe.hook_token
 authorization:=header_value(safe.headers,"Authorization")
 if safe.hook_redacted && authorization!="" {
  event_webhook_bad_auth(h,ip,now)
  return event_webhook_unauthorized()
 }
 if !safe.hook_redacted && ascii_has_prefix_fold(authorization,"Bearer ") do token=strings.trim_space(authorization[len("Bearer "):])
 // Content type and shape are checked after auth so rejected calls share one 401.
 result,outcome:=webhooks.receive(h.service,path_part(safe.path,4),token,safe.body,header_value(safe.headers,"Idempotency-Key"),header_value(safe.headers,"Content-Type"),{ctx=h,admit=event_webhook_admit},actor)
 switch outcome {
 case .Unauthorized: event_webhook_bad_auth(h,ip,now);return event_webhook_unauthorized()
 case .Limited: return event_webhook_limited()
 case .Invalid: return event_webhook_status(400,`{"error":"invalid_payload"}`)
 case .Unsupported: return event_webhook_status(415,`{"error":"unsupported_media_type"}`)
 case .Failed: return event_webhook_status(500,`{"error":"webhook_store_failed"}`)
 case .Accepted:
  defer delete(result.event_id)
  response:=action_response(safe,result,202)
  return response
 }
 return event_webhook_status(500,`{"error":"webhook_store_failed"}`)
}
event_webhook_crud_handler :: proc(ctx:rawptr,req:Request)->Response {
 h:=(^Event_Webhook_Handlers)(ctx)
 owner,ok,response:=action_route_auth(h.actions,req)
 if !ok do return response
 id:=path_part(req.path,4)
 if req.method=="GET" {
  if id=="" {
   rows,e:=webhooks.list(h.service,owner);defer domain.event_webhooks_destroy(rows)
   if e.code!=.None do return action_error(e,req.request_id)
   return action_response(req,rows)
  }
  row,e:=webhooks.get(h.service,owner,id);defer domain.event_webhook_destroy(&row)
  if e.code!=.None do return action_error(e,req.request_id)
  return action_response(req,row)
 }
 operation:="update"
 status:=200
 if req.method=="DELETE" do operation="delete"
 if req.method=="POST" {operation="rotate";if id=="" {operation="create";status=201}}
 input:webhooks.Input
 if req.body!="" {
  value:json.Value
  if json.unmarshal_string(req.body,&value,.JSON,context.temp_allocator)!=nil do return event_webhook_status(400,`{"error":"invalid_payload"}`)
  defer json.destroy_value(value,allocator=context.temp_allocator)
  object,valid:=value.(json.Object)
  if !valid do return event_webhook_status(400,`{"error":"invalid_payload"}`)
  for key,item in object {
   switch key {
   case "name":
    text,ok:=item.(string)
    if !ok do return event_webhook_status(400,`{"error":"invalid_payload"}`)
    input.name=text
   case "enabled":
    enabled,ok:=item.(bool)
    if !ok do return event_webhook_status(400,`{"error":"invalid_payload"}`)
    input.enabled=enabled
   case: return event_webhook_status(400,`{"error":"invalid_payload"}`)
   }
  }
 }
 row,token,e:=webhooks.mutate(h.service,owner,id,operation,input)
 defer domain.event_webhook_destroy(&row)
 defer delete(token)
 if e.code!=.None do return action_error(e,req.request_id)
 if operation=="delete" do return action_response(req,struct{deleted:bool}{true})
 if token!="" {
  result:=action_response(req,struct{webhook:domain.Event_Webhook,token:string}{row,token},status)
  result.sensitive=true
  return result
 }
 return action_response(req,row,status)
}
