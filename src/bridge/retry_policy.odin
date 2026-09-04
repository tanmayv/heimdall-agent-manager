package main

import "core:fmt"
import "core:strings"
import "core:time"
import http "odin_test:lib/http_client"

BRIDGE_RETRY_MAX_ATTEMPTS :: 4
BRIDGE_RETRY_BASE_BACKOFF_MS :: 150

// bridge_http_is_retriable reports whether an HTTP response status and transport ok
// flag indicate a transient failure eligible for retry under the Heimdall retry policy:
//   - Transport failure (!ok or status == 0) -> true (retriable)
//   - HTTP 429 (Too Many Requests / Rate Limited) -> true (retriable)
//   - HTTP 5xx (Server Errors: 500, 502, 503, 504, ...) -> true (retriable)
//   - HTTP 4xx (Client / Auth / Validation, except 429) -> false (terminal, non-retriable)
//   - HTTP 2xx / 3xx (Success / Redirect / Not Modified) -> false (terminal, non-retriable)
bridge_http_is_retriable :: proc(status: int, ok: bool) -> bool {
	if !ok || status == 0 do return true
	if status == 429 || status >= 500 do return true
	return false
}

// bridge_http_is_terminal reports whether an HTTP response is terminal (not retriable).
bridge_http_is_terminal :: proc(status: int, ok: bool) -> bool {
	return !bridge_http_is_retriable(status, ok)
}

// bridge_http_backoff_sleep sleeps for base_ms * 2^(attempt-1).
bridge_http_backoff_sleep :: proc(attempt: int, base_ms: int = BRIDGE_RETRY_BASE_BACKOFF_MS) {
	ms := base_ms
	for i in 1..<attempt do ms *= 2
	time.sleep(time.Duration(ms) * time.Millisecond)
}

// bridge_http_request_retry issues an HTTP request with bounded retry and exponential
// backoff for retriable failures. Non-retriable (terminal) responses return immediately.
bridge_http_request_retry :: proc(
	method, hub_url, path, body: string,
	headers: []http.Header,
	timeout_ms: int = http.DEFAULT_TIMEOUT_MS,
	max_attempts: int = BRIDGE_RETRY_MAX_ATTEMPTS,
	base_backoff_ms: int = BRIDGE_RETRY_BASE_BACKOFF_MS,
) -> (http.Response, bool) {
	resp: http.Response
	ok := false
	for attempt in 1..=max_attempts {
		resp, ok = http.request_with_headers_timeout(method, hub_url, path, body, headers, timeout_ms)
		if bridge_http_is_terminal(resp.status, ok) {
			// Log the terminal outcome when it followed at least one retry, so a
			// retried-then-succeeded (or retried-then-failed-hard) sequence is
			// visible in the log rather than trailing off at the last "retry" line.
			if attempt > 1 {
				fmt.println("bridge http retry DONE", "method=", method, "path=", path, "attempts=", attempt, "final_status=", resp.status, "ok=", ok, "outcome=", ok && resp.status >= 200 && resp.status < 300 ? "succeeded_after_retry" : "failed_terminal")
			}
			return resp, ok
		}
		if attempt < max_attempts {
			fmt.println("bridge http retry", "method=", method, "path=", path, "attempt=", attempt, "status=", resp.status, "ok=", ok)
			bridge_http_backoff_sleep(attempt, base_backoff_ms)
		}
	}
	// All attempts were retriable and none terminal-succeeded: retries exhausted.
	fmt.println("bridge http retry EXHAUSTED", "method=", method, "path=", path, "attempts=", max_attempts, "final_status=", resp.status, "ok=", ok)
	return resp, ok
}
