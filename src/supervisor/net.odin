package main

// The real network for the resolver (GitHub API) and the release downloads, over
// src/lib/httpc (libcurl). Only api.github.com and github.com release URLs are ever built
// (resolver.API_BASE, fetch.DOWNLOAD_PREFIX; REQ-SRC-1).
//
// Test builds only (-define:HEIMDALL_SUPERVISOR_TEST=true, never set by the release
// workflow): HEIMDALL_SUPERVISOR_TEST_ORIGIN=http://127.0.0.1:<port> rewrites
// https://api.github.com/<p> to <origin>/api/<p> and https://github.com/<p> to <origin>/gh/<p>,
// so the e2e suite can serve a fake GitHub. A release build ignores the variable.

import "core:fmt"
import "core:os"
import httpc "odin_test:lib/httpc"
import "fetch"
import "resolver"
import "service"

TEST_ORIGIN_ENV :: "HEIMDALL_SUPERVISOR_TEST_ORIGIN"
API_PREFIX :: "https://api.github.com/"
WEB_PREFIX :: "https://github.com/"
USER_AGENT :: "heimdall-supervisor"
API_TIMEOUT_MS :: 30_000
DOWNLOAD_TIMEOUT_MS :: 30 * 60_000
DOWNLOAD_STALL_MS :: 60_000
MAX_BUNDLE_BYTES :: 1 << 30


Net_Ctx :: struct {
	scratch_dir: string, // where downloads are staged before they reach the sink
}

// real_net: the transport for a running supervisor.
real_net :: proc(ctx: ^Net_Ctx) -> service.Net {
	return service.Net {
		get = net_get,
		get_user = ctx,
		download = fetch.Downloader{get = net_download, user = ctx},
	}
}

rewrite_url :: proc(url: string) -> string {
	when service.TEST_BUILD {
		origin := os.get_env(TEST_ORIGIN_ENV, context.temp_allocator)
		if origin != "" {
			for len(origin) > 0 && origin[len(origin) - 1] == '/' do origin = origin[:len(origin) - 1]
			if has_prefix(url, API_PREFIX) do return fmt.tprintf("%s/api/%s", origin, url[len(API_PREFIX):])
			if has_prefix(url, WEB_PREFIX) do return fmt.tprintf("%s/gh/%s", origin, url[len(WEB_PREFIX):])
		}
	}
	return url
}

@(private)
net_get :: proc(req: resolver.Request, user: rawptr) -> (resp: resolver.Response, ok: bool, detail: string) {
	u, uerr := httpc.parse_url(rewrite_url(req.url))
	if uerr != .None do return resp, false, fmt.tprintf("invalid url: %v", uerr)
	headers := make([dynamic]httpc.Header, context.temp_allocator)
	append(&headers, httpc.accept("application/vnd.github+json"), httpc.user_agent(USER_AGENT))
	append(&headers, httpc.Header{"X-GitHub-Api-Version", "2022-11-28"})
	if req.if_none_match != "" do append(&headers, httpc.if_none_match(req.if_none_match))
	if req.if_modified_since != "" do append(&headers, httpc.Header{"If-Modified-Since", req.if_modified_since})
	r, err := httpc.send({method = .GET, url = u, headers = headers[:], timeout_ms = API_TIMEOUT_MS, max_redirects = 5, cancel = &service.g_net_cancel}, context.temp_allocator)
	if err != .None do return resp, false, fmt.tprintf("%v %s", err, r.detail)
	resp.status = r.status
	resp.body = string(r.body)
	h :: proc(r: httpc.Response, name: string) -> string {
		v, _ := httpc.header(r, name)
		return v
	}
	resp.etag = h(r, "etag")
	resp.last_modified = h(r, "last-modified")
	resp.link = h(r, "link")
	resp.retry_after = h(r, "retry-after")
	resp.ratelimit_remaining = h(r, "x-ratelimit-remaining")
	resp.ratelimit_reset = h(r, "x-ratelimit-reset")
	return resp, true, ""
}

// net_download: GET into a scratch file (bounded), then hand it to the sink in chunks.
@(private)
net_download :: proc(user: rawptr, url: string, sink: fetch.Sink) -> (status: int) {
	ctx := (^Net_Ctx)(user)
	u, uerr := httpc.parse_url(rewrite_url(url))
	if uerr != .None {
		service.stderr_log(fmt.tprintf("download %s: invalid url (%v)", url, uerr))
		return 0
	}
	_ = os.make_directory_all(ctx.scratch_dir)
	tmp := fmt.tprintf("%s/net-%d.tmp", ctx.scratch_dir, os.get_pid())
	defer os.remove(tmp)
	st, err := httpc.download_to_file({method = .GET, url = u, headers = {httpc.user_agent(USER_AGENT)}, timeout_ms = DOWNLOAD_TIMEOUT_MS, stall_timeout_ms = DOWNLOAD_STALL_MS, max_response_bytes = MAX_BUNDLE_BYTES, max_redirects = 5, cancel = &service.g_net_cancel}, tmp)
	if err != .None {
		service.stderr_log(fmt.tprintf("download %s: %v", url, err))
		return 0
	}
	if st != 200 do return st
	f, ferr := os.open(tmp)
	if ferr != nil do return 0
	defer os.close(f)
	buf := make([]byte, 64 * 1024, context.temp_allocator)
	for {
		n, rerr := os.read(f, buf)
		if n > 0 && !sink.write(sink.user, buf[:n]) do return 0
		if rerr != nil || n == 0 do break
	}
	return st
}

@(private)
has_prefix :: proc(s, p: string) -> bool {
	return len(s) >= len(p) && s[:len(p)] == p
}
