package app

import "core:testing"
import actions "odin_test:hub/service/actions"

@(test)
test_action_filter_config_bounds :: proc(t:^testing.T) {
 config:Hub_Config
 testing.expect(t,apply_action_filter_limits_json(&config,`{"max_checks":2,"max_depth":3}`))
 testing.expect_value(t,config.action_filter_limits.max_checks,2)
 testing.expect_value(t,config.action_filter_limits.max_nodes,actions.FILTER_DEFAULT_LIMITS.max_nodes)
 before:=config.action_filter_limits
 for raw in ([]string{`[]`,`{"unknown":2}`,`{"max_depth":0}`,`{"max_depth":65}`,`{"max_nodes":1.5}`,`{"max_bytes":1}`,`{"max_values":"3"}`}) {
  testing.expect(t,!apply_action_filter_limits_json(&config,raw),raw)
  testing.expect_value(t,config.action_filter_limits,before)
 }
}
