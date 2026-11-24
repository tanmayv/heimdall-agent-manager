package app
import "core:testing"
import actions "odin_test:hub/service/actions"

@(test)
test_action_snapshot_config_bounds :: proc(t:^testing.T) {
 config:Hub_Config
 testing.expect(t,apply_action_snapshot_limits_json(&config,`{"total_bytes":4096,"value_bytes":1024,"json_bytes":2048,"template_paths":12}`))
 testing.expect_value(t,config.action_snapshot_limits,actions.Snapshot_Limits{4096,1024,2048,12})
 before:=config.action_snapshot_limits
 for raw in ([]string{`[]`,`{"unknown":1}`,`{"value_bytes":0}`,`{"value_bytes":8192}`,`{"template_paths":4097}`,`{"total_bytes":1.5}`}) {
  testing.expect(t,!apply_action_snapshot_limits_json(&config,raw),raw)
  testing.expect_value(t,config.action_snapshot_limits,before)
 }
 graph:App_Graph
 ok,reason:=build_graph(&graph,{action_snapshot_limits={total_bytes=1}})
 testing.expect(t,!ok && reason=="invalid action snapshot limits")
}
