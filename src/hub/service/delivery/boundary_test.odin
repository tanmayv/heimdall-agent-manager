package delivery

import "core:mem"
import "core:os"
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
