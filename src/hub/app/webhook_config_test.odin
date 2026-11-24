package app
import "core:testing"
import webhooks "odin_test:hub/service/webhooks"
@(test)
test_webhook_config_bounds :: proc(t:^testing.T) {
 config:=Hub_Config{webhook_limits=webhooks.DEFAULT_LIMITS}
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
