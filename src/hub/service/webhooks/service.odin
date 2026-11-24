package webhooks

import "core:crypto/sha2"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import events "odin_test:hub/service/events"

Limits :: struct { body_bytes, pre_auth_per_minute, per_webhook_per_minute, failed_auth_per_ip, per_owner: int }
DEFAULT_LIMITS :: Limits{65536,1200,60,20,50}
limits_valid :: proc(l:Limits)->bool {
 return l.body_bytes>=1 && l.body_bytes<=1048576 && l.pre_auth_per_minute>=1 && l.pre_auth_per_minute<=1000000 &&
 l.per_webhook_per_minute>=1 && l.per_webhook_per_minute<=1000000 && l.failed_auth_per_ip>=1 && l.failed_auth_per_ip<=1000000 && l.per_owner>=1 && l.per_owner<=10000
}
Service :: struct { factory:^iface.Unit_Of_Work_Factory, clock:^platform.Clock, limits:Limits, experiments:^iface.Experiment_Repository }
resolve_limits :: proc(l:Limits)->Limits {return DEFAULT_LIMITS if l==Limits{} else l}
effective_limits :: proc(s:^Service)->Limits {return resolve_limits(s.limits)}
Input :: struct { name:Maybe(string), enabled:Maybe(bool) }
hash_token :: proc(token:string)->string {
 h:sha2.Context_256; digest:[32]byte
 sha2.init_256(&h);sha2.update(&h,transmute([]byte)token);sha2.final(&h,digest[:])
 return platform.hex_encode(digest[:],context.temp_allocator)
}
equal_hash :: proc(a,b:string)->bool {
 if len(a)!=64 || len(b)!=64 do return false
 diff:u8
 for i in 0..<64 do diff |= a[i]~b[i]
 return diff==0
}
new_token :: proc()->(string,domain.Domain_Error) {
 raw,ok:=platform.random_hex(32,context.temp_allocator)
 if !ok do return "",domain.domain_error(.Internal_Error,"could not generate webhook token")
 return fmt.aprintf("whsec_%s",raw),{}
}
owned :: proc(repo:^iface.Event_Webhook_Repository,owner,id:string)->(domain.Event_Webhook,domain.Domain_Error) {
 row,found,e:=repo.get(repo.ctx,id)
 if e.code!=.None {domain.event_webhook_destroy(&row);return {},e}
 if !found || owner=="" || row.owner_user_id!=owner {
  domain.event_webhook_destroy(&row)
  return {},domain.domain_error(.Not_Found,"webhook not found")
 }
 return row,{}
}
list :: proc(s:^Service,owner:string)->([]domain.Event_Webhook,domain.Domain_Error) {
 u,ok,e:=iface.unit_of_work_begin(s.factory)
 if !ok do return nil,e
 defer iface.unit_of_work_rollback(&u)
 return u.repos.webhooks.list(u.repos.webhooks.ctx,owner)
}
get :: proc(s:^Service,owner,id:string)->(domain.Event_Webhook,domain.Domain_Error) {
 u,ok,e:=iface.unit_of_work_begin(s.factory)
 if !ok do return {},e
 defer iface.unit_of_work_rollback(&u)
 return owned(&u.repos.webhooks,owner,id)
}
// Token is returned only by create/rotate; ordinary views omit token_hash.
mutate :: proc(s:^Service,owner,id,operation:string,input:Input={})->(domain.Event_Webhook,string,domain.Domain_Error) {
 row:domain.Event_Webhook
 token:string
 err:domain.Domain_Error
 if owner=="" do return {},"",domain.domain_error(.Unauthenticated,"authentication required")
 u,ok,e:=iface.unit_of_work_begin(s.factory)
 if !ok do return {},"",e
 defer if u.ctx!=nil do iface.unit_of_work_rollback(&u)
 repo:=&u.repos.webhooks
 success:=false
 defer if !success {domain.event_webhook_destroy(&row);delete(token)}
 if operation=="create" {
  rows,le:=repo.list(repo.ctx,owner)
  count:=len(rows);domain.event_webhooks_destroy(rows)
  if le.code!=.None do return {},"",le
  if count>=effective_limits(s).per_owner do return {},"",domain.domain_error(.Conflict,"webhook limit reached")
  row={webhook_id=platform.time_id_generate(nil,"wh_"),owner_user_id=strings.clone(owner),enabled=true,created_at=strings.clone(platform.clock_now(s.clock))}
 } else {
  row,err=owned(repo,owner,id)
  if err.code!=.None do return {},"",err
 }
 if operation=="delete" {
  err=repo.remove(repo.ctx,id)
 } else {
  if name,present:=input.name.?;present {
   if len(name)>256 do return {},"",domain.domain_error(.Validation_Failed,"webhook name exceeds 256 bytes")
   delete(row.name);row.name=strings.clone(name)
  }
  if enabled,present:=input.enabled.?;present do row.enabled=enabled
  if operation=="create" || operation=="rotate" {
   token,err=new_token()
   if err.code!=.None do return {},"",err
   delete(row.token_hash);row.token_hash=strings.clone(hash_token(token))
  }
  delete(row.updated_at);row.updated_at=strings.clone(platform.clock_now(s.clock))
  err=repo.save(repo.ctx,row)
 }
 if err.code!=.None do return {},"",err
 committed,ce:=iface.unit_of_work_commit(&u);u.ctx=nil
 if !committed do return {},"",ce
 success=true
 return row,token,{}
}
Admission :: struct {ctx:rawptr, admit:proc(ctx:rawptr,id:string)->bool}
Receive_Result :: enum { Accepted, Unauthorized, Limited, Invalid, Unsupported, Failed }
Receive :: struct {event_id:string,duplicate:bool}
// The only ingress repository dependencies are webhook, experiment and outbox.
// Authentication, duplicate lookup, version increment and append share one UoW.
receive :: proc(s:^Service,id,token,body,key,content_type:string,admission:Admission,test_actor:="")->(Receive,Receive_Result) {
 u,ok,_:=iface.unit_of_work_begin(s.factory)
 if !ok do return {},.Failed
 defer if u.ctx!=nil do iface.unit_of_work_rollback(&u)
 row,found,e:=u.repos.webhooks.get(u.repos.webhooks.ctx,id)
 defer domain.event_webhook_destroy(&row)
 presented:=hash_token(token)
 want:=row.token_hash if found else "0000000000000000000000000000000000000000000000000000000000000000"
 valid:=equal_hash(presented,want)
 if e.code!=.None do return {},.Failed
 if !valid || !found || !row.enabled || token=="" do return {},.Unauthorized
 exps,ee:=iface.experiment_list_by_owner(s.experiments,row.owner_user_id)
 defer {for exp in exps {delete(exp.owner_user_id);delete(exp.key);delete(exp.updated_at)};delete(exps)}
 if ee.code!=.None || !domain.experiment_enabled_in(exps[:],domain.ACTIONS_EXPERIMENT_KEY) do return {},.Unauthorized
 if admission.admit!=nil && !admission.admit(admission.ctx,id) do return {},.Limited
 media:=strings.trim_space(strings.split(content_type,";",context.temp_allocator)[0])
 if !strings.equal_fold(media,"application/json") do return {},.Unsupported
 if len(key)>128 do return {},.Invalid
 value:json.Value
 if json.unmarshal_string(body,&value,.JSON,context.temp_allocator)!=nil do return {},.Invalid
 defer json.destroy_value(value,allocator=context.temp_allocator)
 if _,is_object:=value.(json.Object);!is_object do return {},.Invalid
 if !depth_valid(value,0) do return {},.Invalid
 event_id:=""
 if key!="" {
  digest:=hash_token(fmt.tprintf("%s|%s",id,key))
  event_id=fmt.tprintf("evt_wh_%s",digest[:32])
  exists,lookup_err:=u.repos.event_outbox.contains(u.repos.event_outbox.ctx,event_id)
  if lookup_err.code!=.None do return {},.Failed
  if exists do return {event_id=strings.clone(event_id),duplicate=true},.Accepted
 }
 actor:=test_actor
 if actor=="" do actor=fmt.tprintf("webhook:%s",id)
 event_id,e=events.emit(&u.repos.event_outbox,s.clock,{owner=row.owner_user_id,type="webhook.received",class="occurrence",entity_kind="webhook",entity_id=id,
  subject=fmt.tprintf("ev.%s.webhook.%s.received",row.owner_user_id,id),actor=actor,data=body,event_id=event_id,append_if_absent=true})
 if e.code!=.None do return {},.Failed
 if e=u.repos.webhooks.record_received(u.repos.webhooks.ctx,id,platform.clock_now(s.clock));e.code!=.None do return {},.Failed
 committed,_:=iface.unit_of_work_commit(&u);u.ctx=nil
 if !committed do return {},.Failed
 return {event_id=strings.clone(event_id)},.Accepted
}
depth_valid :: proc(v:json.Value,depth:int)->bool {
 #partial switch x in v {
 case json.Object:
  if depth>=16 do return false
  for _,child in x do if !depth_valid(child,depth+1) do return false
 case json.Array:
  if depth>=16 do return false
  for child in x do if !depth_valid(child,depth+1) do return false
 }
 return true
}
