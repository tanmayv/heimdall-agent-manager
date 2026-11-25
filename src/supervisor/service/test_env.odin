package service

// Test builds only (-define:HEIMDALL_SUPERVISOR_TEST=true; P2-7 conversion CI).
//
// A bridge started by a service manager (systemd, launchd, Task Scheduler) does not
// inherit the test's environment, yet the conversion e2e must steer the fake release
// origin and the failure hooks in processes the OS starts. test_env reads NAME from the
// environment first, then from `<home>/.heimdall-supervisor-test.env` (KEY=VALUE lines).
// A release build never calls it (every caller is inside `when TEST_BUILD`).

import "core:os"
import "core:strings"

TEST_ENV_FILE :: ".heimdall-supervisor-test.env"

test_env :: proc(name: string, allocator := context.temp_allocator) -> string {
	if v := os.get_env(name, allocator); v != "" do return v
	home, herr := os.user_home_dir(context.temp_allocator)
	if herr != nil do return ""
	data, rerr := os.read_entire_file_from_path(strings.concatenate({home, "/", TEST_ENV_FILE}, context.temp_allocator), context.temp_allocator)
	if rerr != nil do return ""
	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		if strings.has_prefix(l, name) && len(l) > len(name) && l[len(name)] == '=' do return strings.clone(strings.trim_space(l[len(name) + 1:]), allocator)
	}
	return ""
}
