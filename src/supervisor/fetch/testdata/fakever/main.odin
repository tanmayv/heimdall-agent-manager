package fakever

// Stand-in for ham-bridge / ham-supervisor in the fetch preflight tests
// (src/supervisor/fetch/prepare_test.odin). `<exe> --version` prints
// "<exe name> <contents of fakever.txt next to the exe>". Special contents:
// "hang" sleeps 120 s (timeout path), "fail" exits 3.
// Built by CI before the tests; the path goes in HEIMDALL_FETCH_FAKEVER.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

main :: proc() {
	exe, _ := os.get_executable_path(context.allocator)
	dir := os.dir(exe)
	sep := "\\" if ODIN_OS == .Windows else "/"
	data, err := os.read_entire_file(strings.concatenate({dir, sep, "fakever.txt"}), context.allocator)
	version := strings.trim_space(string(data)) if err == nil else "unknown"
	switch version {
	case "hang":
		time.sleep(120 * time.Second)
	case "fail":
		os.exit(3)
	}
	fmt.printf("%s %s\n", os.base(exe), version)
}
