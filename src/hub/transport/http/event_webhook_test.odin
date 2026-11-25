#+feature dynamic-literals
package http

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import "base:runtime"
import "core:c"
import "core:net"
import "core:thread"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import webhooks "odin_test:hub/service/webhooks"
import metrics "odin_test:lib/metrics"

when ODIN_OS==.Windows {foreign import event_webhook_sqlite "system:sqlite3.lib"} else {foreign import event_webhook_sqlite "system:sqlite3"}
foreign event_webhook_sqlite {
 @(link_name="sqlite3_trace_v2")
 event_webhook_trace_v2 :: proc "c" (db:sqlite.sqlite3,mask:c.uint,callback:proc "c" (c.uint,rawptr,rawptr,rawptr)->c.int,ctx:rawptr)->c.int ---
}
Webhook_Query_Count :: struct {total,forbidden:int}
event_webhook_query_trace :: proc "c" (mask:c.uint,ctx,p,x:rawptr)->c.int {
 context=runtime.default_context()
 if mask!=1 do return 0
 count:=(^Webhook_Query_Count)(ctx)
 count.total+=1
 sql:=string(sqlite.sqlite3_sql(sqlite.sqlite3_stmt(p)))
 if strings.contains(sql,"action_") || strings.contains(sql,"pipeline_deliveries") do count.forbidden+=1
 return 0
}

Webhook_Test :: struct {api:^Action_API_Fixture, service:webhooks.Service, h:Event_Webhook_Handlers}
event_webhook_test_setup :: proc(f:^Action_API_Fixture,impl:^sqlite.Event_Webhook_Repo_SQLite)->Webhook_Test {
 f.repos.webhooks=sqlite.new_event_webhook_repository(impl,&f.wire.conn)
 return {api=f,service={factory=f.service.factory,clock=&f.wire.clock,experiments=f.service.experiments}}
}
event_webhook_test_bind :: proc(f:^Webhook_Test) {f.h={service=&f.service,actions=&f.api.handlers}}
event_webhook_test_create :: proc(t:^testing.T,f:^Webhook_Test)->(string,string) {
 r:=event_webhook_crud_handler(&f.h,action_api_request(f.api,"POST","/api/v1/webhooks",`{"name":"CI"}`))
 data:=action_api_data(t,r,201)
 testing.expect(t,r.sensitive)
 row,_:=data["webhook"].(json.Object)
 token,_:=data["token"].(string)
 id,_:=row["webhook_id"].(string)
 testing.expect(t,strings.has_prefix(token,"whsec_") && len(token)==70)
 _,hash_exposed:=row["token_hash"];testing.expect(t,!hash_exposed)
 return id,token
}
event_webhook_test_request :: proc(id,token:string,secret:=false,body:="{}",key:="",ip:="192.0.2.1")->Request {
 path:=fmt.tprintf("/api/v1/hooks/%s",id)
 headers:=make([dynamic]contracts.HTTP_Header,context.temp_allocator)
 append(&headers,contracts.HTTP_Header{name="Content-Type",value="application/json"})
 if secret {path=fmt.tprintf("%s/%s",path,token)} else if token!="" {append(&headers,contracts.HTTP_Header{name="Authorization",value=fmt.tprintf("Bearer %s",token)})}
 if key!="" do append(&headers,contracts.HTTP_Header{name="Idempotency-Key",value=key})
 return {method="POST",path=path,raw_target=path,body=body,headers=headers[:],remote_addr=ip,request_id="req_webhook"}
}
event_webhook_test_send :: proc(f:^Webhook_Test,req:Request)->Response {return event_webhook_receive_handler(&f.h,req)}
@(test)
test_event_webhook_auth_dedupe_rotation_crud :: proc(t:^testing.T) {action_api_test(t,webhook_auth_scenario)}
webhook_auth_scenario :: proc(t:^testing.T,api:^Action_API_Fixture) {
 impl:sqlite.Event_Webhook_Repo_SQLite
 f:=event_webhook_test_setup(api,&impl);event_webhook_test_bind(&f)
 defer event_webhook_limiter_destroy(&f.h.limiter)
 id,token:=event_webhook_test_create(t,&f)
 // Raw DB row contains only the hash; owner-scoped read never exposes it.
 row,e:=webhooks.get(&f.service,string(api.wire.owner),id)
 testing.expect_value(t,e.code,domain.Error_Code.None)
 testing.expect_value(t,row.token_hash,webhooks.hash_token(token))
 testing.expect(t,row.token_hash!=token)
 domain.event_webhook_destroy(&row)
 before:=action_api_backlog(t,api)
 count:Webhook_Query_Count
 event_webhook_trace_v2(api.wire.conn.db,1,event_webhook_query_trace,&count)
 first:=action_api_data(t,event_webhook_test_send(&f,event_webhook_test_request(id,token,body=`{"hello":"world"}`,key="retry")),202)
 event_webhook_trace_v2(api.wire.conn.db,0,nil,nil)
 testing.expect(t,count.total>0)
 testing.expect_value(t,count.forbidden,0)
 again:=action_api_data(t,event_webhook_test_send(&f,event_webhook_test_request(id,token,true,`{"different":true}`,"retry")),202)
 testing.expect_value(t,first["event_id"].(string),again["event_id"].(string))
 testing.expect(t,again["duplicate"].(bool))
 testing.expect_value(t,action_api_backlog(t,api),before+1)
 testing.expect_value(t,event_webhook_test_send(&f,event_webhook_test_request(id,token,true)).status,202)
 testing.expect_value(t,action_api_backlog(t,api),before+2)
 u,ok,_:=iface.unit_of_work_begin(f.service.factory)
 if testing.expect(t,ok) {
  // next_version returns 3 iff the duplicate did not increment the version.
  version,ve:=u.repos.event_outbox.next_version(u.repos.event_outbox.ctx,string(api.wire.owner),"webhook",id)
  testing.expect_value(t,ve.code,domain.Error_Code.None);testing.expect_value(t,version,i64(3))
  for {
   event,found,re:=u.repos.event_outbox.next(u.repos.event_outbox.ctx)
   if !testing.expect(t,re.code==.None && found) do break
   defer domain.event_outbox_row_destroy(&event)
   if event.event_id==first["event_id"].(string) {
    testing.expect_value(t,event.owner_user_id,string(api.wire.owner))
    value:contracts.Event_Envelope
    testing.expect_value(t,json.unmarshal_string(event.envelope_json,&value,.JSON,context.temp_allocator),nil)
    testing.expect_value(t,value.entity.kind,"webhook");testing.expect_value(t,value.entity.id,id)
    testing.expect_value(t,value.entity_version,i64(1));testing.expect_value(t,value.type,"webhook.received")
    testing.expect_value(t,value.actor,fmt.tprintf("webhook:%s",id))
    testing.expect_value(t,value.data["hello"].(string),"world")
    testing.expect(t,!strings.contains(event.envelope_json,token))
    break
   }
   _=u.repos.event_outbox.mark_published(u.repos.event_outbox.ctx,event.outbox_seq,"now")
  }
  iface.unit_of_work_rollback(&u)
 }
 missing:=event_webhook_test_send(&f,event_webhook_test_request(id,""))
 query_only:=event_webhook_test_request(id,"")
 query_only.query=fmt.tprintf("token=%s",token)
 testing.expect_value(t,event_webhook_test_send(&f,query_only).body,missing.body)
 for request in ([]Request{event_webhook_test_request(id,"wrong"),event_webhook_test_request("wh_unknown",token),event_webhook_test_request("wh_unknown","wrong",true)}) {
  rejected:=event_webhook_test_send(&f,request)
  testing.expect_value(t,rejected.status,401);testing.expect_value(t,rejected.body,missing.body)
 }
 both:=event_webhook_test_request(id,token,true)
 both.headers=[]contracts.HTTP_Header{{name="Authorization",value=fmt.tprintf("Bearer %s",token)}}
 testing.expect_value(t,event_webhook_test_send(&f,both).status,401)
 view:=event_webhook_crud_handler(&f.h,action_api_request(api,"GET",fmt.tprintf("/api/v1/webhooks/%s",id),""))
 testing.expect(t,!strings.contains(view.body,token) && !strings.contains(view.body,"token_hash"))
 rotated:=action_api_data(t,event_webhook_crud_handler(&f.h,action_api_request(api,"POST",fmt.tprintf("/api/v1/webhooks/%s/rotate",id),"")))
 new_token,_:=rotated["token"].(string)
 for secret in ([]bool{false,true}) {
  testing.expect_value(t,event_webhook_test_send(&f,event_webhook_test_request(id,token,secret)).status,401)
  testing.expect_value(t,event_webhook_test_send(&f,event_webhook_test_request(id,new_token,secret)).status,202)
 }
 exp:=(^Action_API_Experiment)(f.service.experiments.ctx)
 exp.enabled=false
 testing.expect_value(t,event_webhook_test_send(&f,event_webhook_test_request(id,new_token)).body,missing.body)
 exp.enabled=true
 scheme:=event_webhook_test_request(id,new_token)
 scheme.headers=[]contracts.HTTP_Header{{name="Authorization",value=fmt.tprintf("bEaReR %s",new_token)},{name="Content-Type",value="application/json"}}
 testing.expect_value(t,event_webhook_test_send(&f,scheme).status,202)
 disabled:=event_webhook_crud_handler(&f.h,action_api_request(api,"PATCH",fmt.tprintf("/api/v1/webhooks/%s",id),`{"enabled":false}`))
 testing.expect_value(t,disabled.status,200)
 testing.expect_value(t,event_webhook_test_send(&f,event_webhook_test_request(id,new_token)).body,missing.body)
 for operation in ([]string{"update","rotate","delete"}) {
  other,secret,oe:=webhooks.mutate(&f.service,"other-owner",id,operation)
  domain.event_webhook_destroy(&other);delete(secret)
  testing.expect_value(t,oe.code,domain.Error_Code.Not_Found)
 }
 other,oe:=webhooks.get(&f.service,"other-owner",id);domain.event_webhook_destroy(&other)
 testing.expect_value(t,oe.code,domain.Error_Code.Not_Found)
}
@(test)
test_event_webhook_limits_and_preauth :: proc(t:^testing.T) {action_api_test(t,webhook_limits_scenario)}
webhook_limits_scenario :: proc(t:^testing.T,api:^Action_API_Fixture) {
 impl:sqlite.Event_Webhook_Repo_SQLite
 f:=event_webhook_test_setup(api,&impl);event_webhook_test_bind(&f)
 defer event_webhook_limiter_destroy(&f.h.limiter)
 id,token:=event_webhook_test_create(t,&f)
 id2,token2:=event_webhook_test_create(t,&f)
 for _ in 0..<60 do testing.expect_value(t,event_webhook_test_send(&f,event_webhook_test_request(id,token)).status,202)
 limited:=event_webhook_test_send(&f,event_webhook_test_request(id,token,true))
 testing.expect_value(t,limited.status,429);testing.expect_value(t,header_value(limited.headers,"Retry-After"),"60")
 testing.expect_value(t,event_webhook_test_send(&f,event_webhook_test_request(id2,token2)).status,202)
 for i in 0..<100 {
  bad:=event_webhook_test_send(&f,event_webhook_test_request(id2,"wrong",ip="192.0.2.99"))
  unknown:=event_webhook_test_send(&f,event_webhook_test_request("unknown","wrong",ip="192.0.2.99"))
  testing.expect_value(t,bad.body,unknown.body)
  testing.expect(t,bad.status==401 || bad.status==429)
 }
 testing.expect_value(t,event_webhook_test_send(&f,event_webhook_test_request(id2,token2)).status,202)
 large:=strings.repeat("x",65537,context.temp_allocator)
 count:Webhook_Query_Count
 event_webhook_trace_v2(api.wire.conn.db,1,event_webhook_query_trace,&count)
 testing.expect_value(t,event_webhook_test_send(&f,event_webhook_test_request(id2,token2,true,large)).status,413)
 event_webhook_trace_v2(api.wire.conn.db,0,nil,nil)
 testing.expect_value(t,count.total,0)
 exact:=strings.concatenate({`{"x":"`,strings.repeat("x",65528,context.temp_allocator),`"}`},context.temp_allocator)
 testing.expect_value(t,len(exact),65536)
 testing.expect_value(t,event_webhook_test_send(&f,event_webhook_test_request(id2,token2,true,exact)).status,202)
 for body in ([]string{"[]","null","12","{","{\"x\":[[[[[[[[[[[[[[[[]]]]]]]]]]]]]]]]}"}) do testing.expect_value(t,event_webhook_test_send(&f,event_webhook_test_request(id2,token2,true,body)).status,400)
 wrong_type:=event_webhook_test_request(id2,token2)
 wrong_type.headers=[]contracts.HTTP_Header{{name="Authorization",value=fmt.tprintf("Bearer %s",token2)},{name="Content-Type",value="text/plain"}}
 testing.expect_value(t,event_webhook_test_send(&f,wrong_type).status,415)
 testing.expect_value(t,event_webhook_test_send(&f,event_webhook_test_request(id2,token2,key=strings.repeat("k",129,context.temp_allocator))).status,400)
}
@(test)
test_event_webhook_secret_url_redaction :: proc(t:^testing.T) {action_api_test(t,webhook_redaction_scenario)}
Webhook_Capture :: struct {h:^Event_Webhook_Handlers,path,target:string}
event_webhook_capture_handler :: proc(ctx:rawptr,req:Request)->Response {
 capture:=(^Webhook_Capture)(ctx)
 capture.path=strings.clone(req.path,runtime.heap_allocator())
 capture.target=strings.clone(req.raw_target,runtime.heap_allocator())
 return event_webhook_receive_handler(capture.h,req)
}
webhook_redaction_scenario :: proc(t:^testing.T,api:^Action_API_Fixture) {
 impl:sqlite.Event_Webhook_Repo_SQLite
 f:=event_webhook_test_setup(api,&impl);event_webhook_test_bind(&f)
 defer event_webhook_limiter_destroy(&f.h.limiter)
 id,token:=event_webhook_test_create(t,&f)
 registry:metrics.Registry
 metrics.registry_init(&registry,runtime.heap_allocator())
 old_metrics:=http_metrics
 defer {http_metrics=old_metrics;metrics.registry_destroy(&registry)}
 http_metrics_init(&registry)
 router:=new_router();defer router_free(&router)
 capture:=Webhook_Capture{h=&f.h}
 router_add(&router,"POST","/api/v1/hooks/*/*",&capture,event_webhook_capture_handler)
 // Accepted, invalid token, oversized, limited and forced storage failure.
 for scenario in 0..<5 {
  secret:=token if scenario!=1 else "whsec_rejected_secret"
  request:=event_webhook_test_request(id,secret,true)
  if scenario==2 do request.body=strings.repeat("x",65537,context.temp_allocator)
  if scenario==3 {f.service.limits=webhooks.DEFAULT_LIMITS;f.service.limits.per_webhook_per_minute=1}
  if scenario==4 {
   f.service.limits=webhooks.DEFAULT_LIMITS
   testing.expect(t,sqlite.exec(&api.wire.conn,"DROP TABLE event_outbox;"))
  }
  safe:=event_webhook_redact(request)
  testing.expect_value(t,safe.path,fmt.tprintf("/api/v1/hooks/%s/[redacted]",id))
  testing.expect_value(t,safe.raw_target,safe.path)
  // Exercise the real socket wrapper, including middleware and metrics.
  raw:=fmt.tprintf("POST %s HTTP/1.1\r\nHost: h\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s",request.path,len(request.body),request.body)
  response:=event_webhook_socket_request(t,&router,raw)
  defer delete(response)
  defer delete(capture.path,runtime.heap_allocator())
  defer delete(capture.target,runtime.heap_allocator())
  pattern:="/api/v1/hooks/*/*"
  expected:=[]int{202,401,413,429,500}
  testing.expect(t,strings.has_prefix(response,fmt.tprintf("HTTP/1.1 %d",expected[scenario])),response)
  testing.expect_value(t,capture.path,safe.path);testing.expect_value(t,capture.target,safe.raw_target)
  exposition:=strings.builder_make(context.temp_allocator)
  metrics.gather(&registry,&exposition)
  for recorded in ([]string{capture.path,capture.target,strings.to_string(exposition),response,format_db_slow_request(pattern,"POST","2xx",0,"req_webhook",{},{},context.temp_allocator)}) do testing.expect(t,!strings.contains(recorded,secret),recorded)
 }
}
Webhook_Socket :: struct {router:^Router,socket:net.TCP_Socket,source:net.Endpoint}
event_webhook_socket_thread :: proc(ctx:rawptr) {
 state:=(^Webhook_Socket)(ctx)
 handle_client(state.socket,state.source,state.router)
}
event_webhook_socket_request :: proc(t:^testing.T,router:^Router,raw:string)->string {
 listener,le:=net.listen_tcp({address=net.IP4_Loopback,port=0})
 if le!=nil do testing.fail_now(t,"could not listen")
 defer net.close(listener)
 endpoint,_:=net.bound_endpoint(listener)
 client,ce:=net.dial_tcp(endpoint)
 if ce!=nil do testing.fail_now(t,"could not connect")
 defer net.close(client)
 server,source,se:=net.accept_tcp(listener)
 if se!=nil do testing.fail_now(t,"could not accept")
 state:=Webhook_Socket{router=router,socket=server,source=source}
 worker:=thread.create_and_start_with_data(&state,event_webhook_socket_thread)
 defer {thread.join(worker);thread.destroy(worker)}
 sent:=0
 for sent<len(raw) {
  n,e:=net.send_tcp(client,transmute([]byte)raw[sent:])
  if e!=nil || n<=0 do testing.fail_now(t,"could not send request")
  sent+=n
 }
 buffer:[4096]byte
 n,_:=net.recv_tcp(client,buffer[:])
 return strings.clone(string(buffer[:max(0,n)]))
}

@(test)
test_event_webhook_configured_dedupe_header :: proc(t:^testing.T) {action_api_test(t,webhook_configured_dedupe_scenario)}
webhook_configured_dedupe_scenario :: proc(t:^testing.T,api:^Action_API_Fixture) {
 impl:sqlite.Event_Webhook_Repo_SQLite
 f:=event_webhook_test_setup(api,&impl);event_webhook_test_bind(&f)
 defer event_webhook_limiter_destroy(&f.h.limiter)
 id,token:=event_webhook_test_create(t,&f)
 path:=fmt.tprintf("/api/v1/webhooks/%s",id)
 view:=action_api_data(t,event_webhook_crud_handler(&f.h,action_api_request(api,"GET",path,"")))
 testing.expect_value(t,view["dedupe_header"].(string),"Idempotency-Key")
 patched:=action_api_data(t,event_webhook_crud_handler(&f.h,action_api_request(api,"PATCH",path,`{"dedupe_header":"X-GitHub-Delivery"}`)))
 testing.expect_value(t,patched["dedupe_header"].(string),"X-GitHub-Delivery")
 // Selecting the header is case insensitive; old Idempotency-Key must be ignored.
 request:=event_webhook_test_request(id,token,key="old-header")
 headers:=make([dynamic]contracts.HTTP_Header,context.temp_allocator)
 append(&headers,..request.headers)
 append(&headers,contracts.HTTP_Header{name="x-github-delivery",value="delivery-1"})
 request.headers=headers[:]
 before:=action_api_backlog(t,api)
 first:=action_api_data(t,event_webhook_test_send(&f,request),202)
 again:=action_api_data(t,event_webhook_test_send(&f,request),202)
 testing.expect(t,again["duplicate"].(bool))
 testing.expect_value(t,first["event_id"].(string),again["event_id"].(string))
 testing.expect_value(t,action_api_backlog(t,api),before+1)
 missing:=event_webhook_test_request(id,token,key="old-header")
 testing.expect_value(t,event_webhook_test_send(&f,missing).status,202)
 testing.expect_value(t,event_webhook_test_send(&f,missing).status,202)
 testing.expect_value(t,action_api_backlog(t,api),before+3)
 request.headers[len(request.headers)-1].value=strings.repeat("x",129,context.temp_allocator)
 testing.expect_value(t,event_webhook_test_send(&f,request).status,400)
 bad_auth:=request
 bad_auth.headers=[]contracts.HTTP_Header{{name="Authorization",value="Bearer wrong"},{name="X-GitHub-Delivery",value=strings.repeat("x",129,context.temp_allocator)}}
 testing.expect_value(t,event_webhook_test_send(&f,bad_auth).status,401)
 for name in ([]string{"","bad name","bad:header","é",strings.repeat("x",65,context.temp_allocator)}) {
  body,_:=json.marshal(struct{dedupe_header:string}{name},allocator=context.temp_allocator)
  rejected:=event_webhook_crud_handler(&f.h,action_api_request(api,"PATCH",path,string(body)))
  testing.expect_value(t,rejected.status,422)
  testing.expect(t,strings.contains(rejected.body,"dedupe_header"))
 }
 nonstring:=event_webhook_crud_handler(&f.h,action_api_request(api,"PATCH",path,`{"dedupe_header":null}`))
 testing.expect_value(t,nonstring.status,400)
 row,e:=webhooks.get(&f.service,string(api.wire.owner),id)
 testing.expect_value(t,e.code,domain.Error_Code.None)
 testing.expect_value(t,row.dedupe_header,"X-GitHub-Delivery")
 domain.event_webhook_destroy(&row)
 created:=action_api_data(t,event_webhook_crud_handler(&f.h,action_api_request(api,"POST","/api/v1/webhooks",`{"dedupe_header":"Svix-Id"}`)),201)
 testing.expect_value(t,created["webhook"].(json.Object)["dedupe_header"].(string),"Svix-Id")
 updated:=action_api_data(t,agent_webhook_test_call(&f,"update",strings.concatenate({`{"id":"`,id,`","dedupe_header":"X-Request-Id"}`},context.temp_allocator)))
 testing.expect_value(t,updated["dedupe_header"].(string),"X-Request-Id")
}
