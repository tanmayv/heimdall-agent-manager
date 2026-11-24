package app
import "core:testing"
import "core:os"
import "core:fmt"
import "core:time"
import actions "odin_test:hub/service/actions"
import natstest "odin_test:lib/natstest"
import webhooks "odin_test:hub/service/webhooks"
@(test)
test_webhook_config_bounds :: proc(t:^testing.T) {
 config:Hub_Config
 testing.expect(t,apply_webhook_limits_json(&config,`{"per_owner":2,"body_bytes":1024}`))
 testing.expect_value(t,config.webhook_limits.per_owner,2)
 testing.expect_value(t,config.webhook_limits.body_bytes,1024)
 testing.expect_value(t,config.webhook_limits.per_webhook_per_minute,60)
 before:=config.webhook_limits
 for raw in ([]string{`[]`,`{"unknown":2}`,`{"per_owner":0}`,`{"per_owner":10001}`,`{"body_bytes":1048577}`,`{"failed_auth_per_ip":1.5}`,`{"pre_auth_per_minute":"2"}`}) {
  testing.expect(t,!apply_webhook_limits_json(&config,raw),raw)
  testing.expect_value(t,config.webhook_limits,before)
 }
}
@(test)
test_webhook_graph_default_limits :: proc(t:^testing.T) {
 context.allocator=context.temp_allocator
 invalid_graph:App_Graph
 valid,message:=build_graph(&invalid_graph,Hub_Config{webhook_limits={body_bytes=1}})
 testing.expect(t,!valid && message=="invalid webhook limits")
 testing.expect(t,invalid_graph.db.db==nil)
 graph:=new(App_Graph)
 defer free(graph)
 path:=fmt.tprintf("/tmp/heimdall-webhook-defaults-%d-%d.db",os.get_pid(),time.tick_now()._nsec)
 defer _=os.remove(path)
 defer _=os.remove(fmt.tprintf("%s-wal",path))
 defer _=os.remove(fmt.tprintf("%s-shm",path))
 built,reason:=build_graph(graph,Hub_Config{
  nats_url=natstest.testing_url(t),database_path=path,
  migrations_dir="src/hub/repository/sqlite/migrations",paddle_environment="sandbox",
 })
 if !testing.expect(t,built,reason) do return
 defer shutdown_graph(graph)
 testing.expect_value(t,graph.webhooks.limits,webhooks.DEFAULT_LIMITS)
 advertised:=actions.trigger_types(&graph.actions)
 testing.expect_value(t,advertised.limits.webhook,webhooks.DEFAULT_LIMITS)
}
