package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

bridge_update_test_output_path :: proc(args: []string) -> (string, bool) {
	for i := 0; i + 1 < len(args); i += 1 {
		if args[i] == "--output" do return args[i+1], true
	}
	return "", false
}

bridge_update_test_curl_success :: proc(
	args: []string,
	timeout: time.Duration,
) -> (stdout, stderr: string, exit_code: int, ok, timed_out: bool) {
	output, has_output := bridge_update_test_output_path(args)
	has_fail := false
	has_location := false
	has_separator := false
	for arg in args {
		if arg == "--fail" do has_fail = true
		if arg == "--location" do has_location = true
		if arg == "--" do has_separator = true
	}
	if len(args) == 0 || args[0] != "curl" || !has_output || !has_fail || !has_location || !has_separator || timeout <= 0 {
		return strings.clone(""), strings.clone("invalid curl argv"), 2, false, false
	}
	if os.write_entire_file_from_string(output, "release-bytes") != nil {
		return strings.clone(""), strings.clone("could not write output"), 23, false, false
	}
	return strings.clone(""), strings.clone(""), 0, true, false
}

bridge_update_test_curl_failure :: proc(
	args: []string,
	timeout: time.Duration,
) -> (stdout, stderr: string, exit_code: int, ok, timed_out: bool) {
	if output, found := bridge_update_test_output_path(args); found {
		_ = os.write_entire_file_from_string(output, "partial")
	}
	return strings.clone(""), strings.clone("curl: (22) The requested URL returned error: 404"), 22, false, false
}

bridge_update_test_curl_timeout :: proc(
	args: []string,
	timeout: time.Duration,
) -> (stdout, stderr: string, exit_code: int, ok, timed_out: bool) {
	return strings.clone(""), strings.clone(""), -1, false, true
}

bridge_update_test_path :: proc(label: string) -> string {
	return fmt.aprintf(
		"/tmp/ham-bridge-update-%s-%d-%d.tar.gz",
		label,
		os.get_pid(),
		time.to_unix_nanoseconds(time.now()),
	)
}

@(test)
bridge_update_curl_download_is_atomic :: proc(t: ^testing.T) {
	dest := bridge_update_test_path("success")
	defer { _ = os.remove(dest); delete(dest) }
	ok, detail := bridge_update_download_with_curl(
		"https://github.com/example/repo/releases/download/v1/bundle.tar.gz",
		dest,
		bridge_update_test_curl_success,
	)
	testing.expect(t, ok, detail)
	data, read_err := os.read_entire_file(dest, context.allocator)
	defer delete(data)
	testing.expect(t, read_err == nil)
	testing.expect_value(t, string(data), "release-bytes")
	testing.expect(t, !os.exists(fmt.tprintf("%s.part", dest)), "successful download leaves no .part file")
}

@(test)
bridge_update_curl_download_reports_error_and_removes_partial :: proc(t: ^testing.T) {
	dest := bridge_update_test_path("failure")
	defer { _ = os.remove(dest); delete(dest) }
	ok, detail := bridge_update_download_with_curl(
		"https://github.com/example/repo/releases/download/v1/missing.tar.gz",
		dest,
		bridge_update_test_curl_failure,
	)
	testing.expect(t, !ok)
	testing.expect(t, strings.contains(detail, "curl exited 22"), detail)
	testing.expect(t, strings.contains(detail, "requested URL returned error: 404"), detail)
	testing.expect(t, !os.exists(dest), "failed download must not publish destination")
	testing.expect(t, !os.exists(fmt.tprintf("%s.part", dest)), "failed download removes partial file")
}

@(test)
bridge_update_curl_download_reports_timeout :: proc(t: ^testing.T) {
	dest := bridge_update_test_path("timeout")
	defer { _ = os.remove(dest); delete(dest) }
	ok, detail := bridge_update_download_with_curl(
		"https://github.com/example/repo/releases/download/v1/slow.tar.gz",
		dest,
		bridge_update_test_curl_timeout,
	)
	testing.expect(t, !ok)
	testing.expect(t, strings.contains(detail, "timed out after 120 seconds"), detail)
}
