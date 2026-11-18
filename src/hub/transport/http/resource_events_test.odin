package http

import "core:encoding/json"
import "core:testing"

@(test)
t6_instance_summary_carries_frozen_transport_on_relaunch :: proc(t: ^testing.T) {
    for transport in ([]string{"", "pty", "acp"}) {
        raw := instance_changed_summary_json({runtime_transport = transport, launch_epoch = "epoch_2", run_count = 2})
        defer delete(raw)
        value, err := json.parse(raw)
        if !testing.expect(t, err == nil) do continue
        defer json.destroy_value(value)
        obj, ok := value.(json.Object)
        if !testing.expect(t, ok) do continue
        testing.expect_value(t, string(obj["runtime_transport"].(json.String)), "acp" if transport == "acp" else "pty")
        testing.expect_value(t, string(obj["launch_epoch"].(json.String)), "epoch_2")
    }
}
