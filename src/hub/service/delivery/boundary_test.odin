package delivery

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
test_delivery_imports :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	entries, err := os.read_all_directory_by_path(#directory, context.temp_allocator)
	testing.expect(t, err == nil)
	count := 0
	for entry in entries {
		if !strings.has_suffix(entry.name, ".odin") || strings.has_suffix(entry.name, "_test.odin") do continue
		data, re := os.read_entire_file(entry.fullpath, context.temp_allocator)
		if !testing.expect(t, re == nil) do continue
		count += 1
		for line in strings.split_lines(string(data), context.temp_allocator) {
			if !strings.has_prefix(strings.trim_space(line), "import ") do continue
			if entry.name == "result.odin" || entry.name == "offline.odin" {
				testing.expectf(t, !strings.contains(line, "lib/nats"), "callback imports NATS: %s", entry.name)
			}
			for forbidden in ([]string{"actions", "eventinbox", "bots", "taskv2", "taskchain", "agent", "content"}) {
				pattern := strings.concatenate({"hub/service/", forbidden, "\""}, context.temp_allocator)
				testing.expectf(t, !strings.contains(line, pattern), "forbidden import: %s", line)
			}
		}
		testing.expect(t, !strings.contains(string(data), "stopped_" + "by"))
		testing.expect(
			t,
			!strings.contains(string(data), "time.sleep") && !strings.contains(string(data), "thread.sleep"),
		)
	}
	testing.expect(t, count >= 5)
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_pipeline_never_reads_stopped_by :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	entries, err := os.read_all_directory_by_path(#directory, context.temp_allocator)
	testing.expect(t, err == nil)
	for entry in entries {
		if strings.has_suffix(entry.name, ".odin") && !strings.has_suffix(entry.name, "_test.odin") {
			pipeline_check_stop_reads(t, entry.fullpath)
		}
	}
	root := filepath.dir(strings.trim_right(#directory, "/"))
	action_entries,action_err:=os.read_all_directory_by_path(strings.concatenate({root,"/actions"},context.temp_allocator),context.temp_allocator)
 testing.expect(t,action_err==nil)
 for entry in action_entries do if strings.has_suffix(entry.name,".odin") && !strings.has_suffix(entry.name,"_test.odin") do pipeline_check_stop_reads(t,entry.fullpath)
 start_path := strings.concatenate({root, "/agent/start_begin.odin"}, context.temp_allocator)
	if _, stat_err := os.stat(start_path, context.temp_allocator); stat_err == nil {
		pipeline_check_stop_reads(t, start_path)
	}
	testing.expect_value(t, len(track.allocation_map), 0)
}

pipeline_check_stop_reads :: proc(t: ^testing.T, path: string) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if !testing.expect(t, err == nil) do return
	for line in strings.split_lines(string(data), context.temp_allocator) {
		if strings.has_prefix(strings.trim_space(line), "//") do continue
		compact, _ := strings.replace_all(line, " ", "", context.temp_allocator)
		compact, _ = strings.replace_all(compact, "\t", "", context.temp_allocator)
		for needle in ([]string{"stopped_" + "by==", "stopped_" + "by!=", "STOPPED_" + "BY_USER"}) {
			testing.expectf(t, !strings.contains(compact, needle), "stop predicate in %s: %s", path, line)
		}
	}
}
