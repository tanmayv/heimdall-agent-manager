package main

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// Only the common command handler and bridge-initiated start-begin path
// may hand a complete Hub launch object to the process launcher.
@(test)
test_one_launcher_two_callers :: proc(t: ^testing.T) {
    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    defer mem.tracking_allocator_destroy(&track)
    context.allocator = mem.tracking_allocator(&track)
    entries, err := os.read_all_directory_by_path(#directory, context.allocator)
    if !testing.expect(t, err == nil) do return
    command_caller, wake_caller := false, false
    for entry in entries {
        if !strings.has_suffix(entry.name, ".odin") || strings.has_suffix(entry.name, "_test.odin") do continue
        data, read_err := os.read_entire_file(entry.fullpath, context.temp_allocator)
        if !testing.expect(t, read_err == nil) do continue
        for raw in strings.split_lines(string(data), context.temp_allocator) {
            line := strings.trim_space(raw)
            if strings.has_prefix(line, "//") || !strings.contains(line, "bridge_runtime_launch_agent(") do continue
            if entry.name == "start_agent.odin" do command_caller = true
            if entry.name == "agent_wake.odin" do wake_caller = true
            testing.expectf(t, entry.name == "start_agent.odin" || entry.name == "agent_wake.odin", "launcher caller outside allow-list: %s: %s", entry.name, line)
        }
    }
    testing.expectf(t, command_caller && wake_caller, "expected both launcher paths under %s", filepath.clean(#directory, context.temp_allocator))
    // Directory records are allocated in the caller's allocator.
    os.file_info_slice_delete(entries, context.allocator)
    testing.expect_value(t, len(track.allocation_map), 0)
}
