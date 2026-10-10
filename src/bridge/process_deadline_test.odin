package main

import "core:strings"
import "core:testing"
import "core:time"

@(test)
bridge_process_deadline_captures_both_streams :: proc(t: ^testing.T) {
	out, err_out, ok, timed_out := bridge_process_run_capture([]string{"/bin/sh", "-c", "printf stdout; printf stderr >&2"}, time.Second)
	defer { delete(out); delete(err_out) }
	testing.expect(t, ok && !timed_out)
	testing.expect_value(t, out, "stdout")
	testing.expect_value(t, err_out, "stderr")
}

@(test)
bridge_process_deadline_reports_exit_code :: proc(t: ^testing.T) {
	out, err_out, exit_code, ok, timed_out := bridge_process_run_capture_status(
		[]string{"/bin/sh", "-c", "printf failure >&2; exit 22"},
		time.Second,
	)
	defer { delete(out); delete(err_out) }
	testing.expect(t, !ok && !timed_out)
	testing.expect_value(t, exit_code, 22)
	testing.expect_value(t, err_out, "failure")
}

@(test)
bridge_process_deadline_kills_and_reaps :: proc(t: ^testing.T) {
	started := time.now()
	out, err_out, ok, timed_out := bridge_process_run_capture([]string{"/bin/sh", "-c", "while :; do :; done"}, 50 * time.Millisecond)
	defer { delete(out); delete(err_out) }
	testing.expect(t, !ok && timed_out)
	testing.expect(t, time.diff(started, time.now()) < 2 * time.Second, "timed-out child must be killed and reaped promptly")
	testing.expect(t, !strings.contains(out, "secret") && !strings.contains(err_out, "secret"))
}
