package main

import "base:runtime"
import "core:mem"
import "core:sync"
import "core:testing"

@(test)
test_stop_intent_registry_survives_caller_arena_reset :: proc(t:^testing.T) {
    sync.mutex_lock(&bridge_test_config_mutex);defer sync.mutex_unlock(&bridge_test_config_mutex)
    backing:=make([]byte,4096)
    defer delete(backing)
    sync.mutex_lock(&bridge_runtime_mutex)
    saved:=bridge_runtime_instances
    bridge_runtime_instances=nil
    sync.mutex_unlock(&bridge_runtime_mutex)
    defer {
        sync.mutex_lock(&bridge_runtime_mutex)
        current:=bridge_runtime_instances
        bridge_runtime_instances=saved
        sync.mutex_unlock(&bridge_runtime_mutex)
        for record in current do delete(record.agent_instance_id,runtime.heap_allocator())
        delete(current)
    }
    arena:mem.Arena;mem.arena_init(&arena,backing)
    {
        context.allocator=mem.arena_allocator(&arena)
        sync.mutex_lock(&bridge_startup_io_mutex)
        bridge_runtime_mark_stop_intent_io_locked("retained_stop")
        sync.mutex_unlock(&bridge_startup_io_mutex)
    }
    // Destroy the caller's allocation lifetime before checking persistent
    // state. Compare to literals, not another alias into the same freed arena.
    mem.zero_slice(backing)
    free_all(mem.arena_allocator(&arena))
    sync.mutex_lock(&bridge_runtime_mutex)
    testing.expect_value(t,len(bridge_runtime_instances),1)
    if len(bridge_runtime_instances)==1 {
        testing.expect_value(t,bridge_runtime_instances[0].agent_instance_id,"retained_stop")
        testing.expect_value(t,bridge_runtime_instances[0].runtime_status,"stopping")
    }
    sync.mutex_unlock(&bridge_runtime_mutex)
}
