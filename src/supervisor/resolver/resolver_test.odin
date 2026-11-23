package resolver

import "core:strconv"
import "core:strings"
import "core:testing"

// ---------------------------------------------------------------------------
// Fake GitHub: serves /releases/latest and the paged list from a release set,
// with per-URL overrides for failure injection. JSON is built with
// strings.Builder (fmt treats braces as directives).

TARGET :: "linux-amd64"

titoa :: proc(n: int) -> string {
	return itoa(n, context.temp_allocator)
}
NOW :: i64(1_800_000_000)

Fake_Rel :: struct {
	tag:          string,
	prerelease:   bool,
	draft:        bool,
	no_bundle:    bool,
	no_manifest:  bool,
	no_signature: bool,
	foreign_url:  bool, // bundle served from another repository
}

Fake :: struct {
	rels:        [dynamic]Fake_Rel, // newest-created first, as GitHub lists them
	latest:      string, // tag returned by /releases/latest, "" = 404
	per_page:    int,
	overrides:   map[string]Response, // by URL
	fail_url:    string, // transport failure for this URL
	remaining:   string, // x-ratelimit-remaining on every 200
	reset:       string,
	next_host:   string, // replaces the host of Link next URLs
	loop:        bool, // last page links back to page 1
	etag_pages:  bool, // serve ETags and honour If-None-Match
	requests:    [dynamic]Request,
}

fake_page_url :: proc(f: ^Fake, page: int) -> string {
	host := f.next_host if f.next_host != "" else "https://api.github.com"
	return strings.concatenate({host, "/repositories/42/releases?per_page=100&page=", titoa(page)}, context.temp_allocator)
}

fake_asset :: proc(b: ^strings.Builder, r: Fake_Rel, name: string, first: ^bool) {
	if !first^ do strings.write_string(b, ",")
	first^ = false
	repo := "someone/else" if r.foreign_url && strings.has_prefix(name, "heimdall-local-") else REPO
	strings.write_string(b, `{"name":"`)
	strings.write_string(b, name)
	strings.write_string(b, `","size":1234,"browser_download_url":"https://github.com/`)
	strings.write_string(b, repo)
	strings.write_string(b, "/releases/download/")
	strings.write_string(b, r.tag)
	strings.write_string(b, "/")
	strings.write_string(b, name)
	strings.write_string(b, `"}`)
}

fake_release_json :: proc(b: ^strings.Builder, r: Fake_Rel) {
	strings.write_string(b, `{"tag_name":"`)
	strings.write_string(b, r.tag)
	strings.write_string(b, `","draft":`)
	strings.write_string(b, "true" if r.draft else "false")
	strings.write_string(b, `,"prerelease":`)
	strings.write_string(b, "true" if r.prerelease else "false")
	strings.write_string(b, `,"assets":[`)
	first := true
	fake_asset(b, r, "SHA256SUMS", &first)
	fake_asset(b, r, bundle_asset_name("windows-amd64", r.tag, context.temp_allocator), &first)
	if !r.no_bundle do fake_asset(b, r, bundle_asset_name(TARGET, r.tag, context.temp_allocator), &first)
	if !r.no_manifest do fake_asset(b, r, MANIFEST_ASSET, &first)
	if !r.no_signature do fake_asset(b, r, SIGNATURE_ASSET, &first)
	strings.write_string(b, "]}")
}

fake_get :: proc(req: Request, user: rawptr) -> (resp: Response, ok: bool, detail: string) {
	f := (^Fake)(user)
	append(&f.requests, req)
	if req.url == f.fail_url do return {}, false, "connection reset"
	if o, has := f.overrides[req.url]; has do return o, true, ""
	resp.status = 200
	resp.ratelimit_remaining = f.remaining
	resp.ratelimit_reset = f.reset
	b := strings.builder_make(context.temp_allocator)
	page := 0
	if req.url == LATEST_URL {
		found := false
		for r in f.rels {
			if r.tag == f.latest {
				fake_release_json(&b, r)
				found = true
			}
		}
		if !found do return Response{status = 404, body = `{"message":"Not Found"}`}, true, ""
	} else {
		if req.url == LIST_URL {
			page = 1
		} else {
			i := strings.last_index(req.url, "page=")
			if i < 0 || !strings.has_prefix(req.url, fake_page_url(f, 0)[:len(fake_page_url(f, 0)) - 1]) do return Response{status = 404}, true, ""
			n, _ := strconv.parse_int(req.url[i + 5:])
			page = n
		}
		per := f.per_page if f.per_page > 0 else 100
		lo, hi := (page - 1) * per, min(page * per, len(f.rels))
		strings.write_string(&b, "[")
		for idx in lo ..< max(lo, hi) {
			if idx > lo do strings.write_string(&b, ",")
			fake_release_json(&b, f.rels[idx])
		}
		strings.write_string(&b, "]")
		if hi < len(f.rels) {
			resp.link = strings.concatenate({`<`, fake_page_url(f, page + 1), `>; rel="next", <`, fake_page_url(f, 99), `>; rel="last"`}, context.temp_allocator)
		} else if f.loop {
			resp.link = strings.concatenate({`<`, fake_page_url(f, 1), `>; rel="next"`}, context.temp_allocator)
		}
	}
	resp.body = strings.to_string(b)
	if f.etag_pages {
		resp.etag = strings.concatenate({`W/"`, titoa(len(resp.body)), `"`}, context.temp_allocator)
		if req.if_none_match == resp.etag do return Response{status = 304, etag = resp.etag, ratelimit_remaining = f.remaining, ratelimit_reset = f.reset}, true, ""
	}
	return resp, true, ""
}

// 250 releases (3 pages of 100): many prereleases created after the newest
// stable, so the stable release sits on page 3 and the highest prerelease on page 2.
fake_many :: proc(f: ^Fake) {
	f.rels = make([dynamic]Fake_Rel, context.temp_allocator)
	f.overrides = make(map[string]Response, context.temp_allocator)
	f.requests = make([dynamic]Request, context.temp_allocator)
	for i := 0; i < 120; i += 1 {
		append(&f.rels, Fake_Rel{tag = strings.concatenate({"v0.6.0-canary.", titoa(200 - i)}, context.temp_allocator), prerelease = true})
	}
	append(&f.rels, Fake_Rel{tag = "v0.7.0-rc.150", prerelease = true})
	append(&f.rels, Fake_Rel{tag = "v0.7.0-rc.9", prerelease = true})
	for i := 0; i < 125; i += 1 {
		append(&f.rels, Fake_Rel{tag = strings.concatenate({"v0.5.80-rc.", titoa(i + 1)}, context.temp_allocator), prerelease = true})
	}
	append(&f.rels, Fake_Rel{tag = "v0.5.80"})
	append(&f.rels, Fake_Rel{tag = "v0.5.79"})
	append(&f.rels, Fake_Rel{tag = "v0.5.78"})
	f.latest = "v0.5.80"
}

fake_small :: proc(f: ^Fake, rels: ..Fake_Rel) {
	f.rels = make([dynamic]Fake_Rel, context.temp_allocator)
	f.overrides = make(map[string]Response, context.temp_allocator)
	f.requests = make([dynamic]Request, context.temp_allocator)
	append(&f.rels, ..rels)
}

new_cache :: proc() -> Cache {
	return Cache{pages = make([dynamic]Cached_Page, context.temp_allocator)}
}

// ---------------------------------------------------------------------------
// >100 releases

@(test)
test_fast_pages_to_exhaustion_over_100_releases :: proc(t: ^testing.T) {
	f: Fake
	fake_many(&f)
	testing.expect_value(t, len(f.rels), 250)
	c := new_cache()
	res := resolve(.Fast, TARGET, &c, fake_get, &f, NOW, context.temp_allocator)
	testing.expect_value(t, res.status, Status.Candidate)
	testing.expect_value(t, res.candidate.tag, "v0.7.0-rc.150")
	testing.expect_value(t, res.from_stable, false)
	testing.expect_value(t, res.candidate.bundle.name, "heimdall-local-linux-amd64-v0.7.0-rc.150.tar.gz")
	testing.expect_value(t, res.candidate.manifest.url, DOWNLOAD_PREFIX + "v0.7.0-rc.150/" + MANIFEST_ASSET)
	// latest + 3 list pages.
	testing.expect_value(t, res.requests, 4)
	testing.expect_value(t, len(f.requests), 4)
	testing.expect_value(t, f.requests[0].url, LATEST_URL)
	testing.expect_value(t, f.requests[3].url, "https://api.github.com/repositories/42/releases?per_page=100&page=3")
}

@(test)
test_stable_uses_latest_endpoint_only :: proc(t: ^testing.T) {
	f: Fake
	fake_many(&f)
	c := new_cache()
	res := resolve(.Stable, TARGET, &c, fake_get, &f, NOW, context.temp_allocator)
	testing.expect_value(t, res.status, Status.Candidate)
	testing.expect_value(t, res.candidate.tag, "v0.5.80")
	testing.expect_value(t, len(f.requests), 1)
	testing.expect_value(t, f.requests[0].url, LATEST_URL)
}

@(test)
test_stable_latest_without_bundle_is_no_candidate_not_older :: proc(t: ^testing.T) {
	f: Fake
	fake_small(&f, Fake_Rel{tag = "v0.5.81", no_bundle = true}, Fake_Rel{tag = "v0.5.80"})
	f.latest = "v0.5.81"
	c := new_cache()
	res := resolve(.Stable, TARGET, &c, fake_get, &f, NOW, context.temp_allocator)
	testing.expect_value(t, res.status, Status.No_Candidate)
	testing.expect_value(t, res.code, "no_candidate")
	testing.expect(t, strings.contains(res.detail, "v0.5.81"), res.detail)
	testing.expect_value(t, res.candidate.tag, "")

	for mod in ([]Fake_Rel{{tag = "v0.5.81", no_manifest = true}, {tag = "v0.5.81", no_signature = true}, {tag = "v0.5.81", foreign_url = true}, {tag = "v0.5.81", prerelease = true}, {tag = "release-81"}}) {
		fake_small(&f, mod, Fake_Rel{tag = "v0.5.80"})
		f.latest = mod.tag
		c2 := new_cache()
		r2 := resolve(.Stable, TARGET, &c2, fake_get, &f, NOW, context.temp_allocator)
		testing.expectf(t, r2.status == .No_Candidate, "%v: %v", mod, r2.status)
	}

	// No stable release at all (404) is no_candidate too.
	fake_small(&f, Fake_Rel{tag = "v0.6.0-rc.1", prerelease = true})
	c3 := new_cache()
	r3 := resolve(.Stable, TARGET, &c3, fake_get, &f, NOW, context.temp_allocator)
	testing.expect_value(t, r3.status, Status.No_Candidate)
}

@(test)
test_fast_ignores_drafts_non_semver_and_incomplete_releases :: proc(t: ^testing.T) {
	f: Fake
	fake_small(&f,
		Fake_Rel{tag = "v9.0.0-rc.1", prerelease = true, draft = true},
		Fake_Rel{tag = "v8.0.0-rc.1", prerelease = true, no_bundle = true},
		Fake_Rel{tag = "v7.0.0-rc.1", prerelease = true, no_signature = true},
		Fake_Rel{tag = "v6.0.0-rc.1", prerelease = true, foreign_url = true},
		Fake_Rel{tag = "v5.0.0-rc.01", prerelease = true}, // leading zero: not SemVer
		Fake_Rel{tag = "nightly-99", prerelease = true},
		Fake_Rel{tag = "v1.0.0-rc.2", prerelease = true},
		Fake_Rel{tag = "v1.0.0-rc.10", prerelease = true},
		Fake_Rel{tag = "v0.9.0"},
	)
	f.latest = "v0.9.0"
	c := new_cache()
	res := resolve(.Fast, TARGET, &c, fake_get, &f, NOW, context.temp_allocator)
	testing.expect_value(t, res.status, Status.Candidate)
	testing.expect_value(t, res.candidate.tag, "v1.0.0-rc.10")
}

@(test)
test_fast_takes_stable_when_it_is_higher :: proc(t: ^testing.T) {
	f: Fake
	fake_small(&f, Fake_Rel{tag = "v0.6.0"}, Fake_Rel{tag = "v0.6.0-rc.3", prerelease = true}, Fake_Rel{tag = "v0.5.9-rc.1", prerelease = true})
	f.latest = "v0.6.0"
	c := new_cache()
	res := resolve(.Fast, TARGET, &c, fake_get, &f, NOW, context.temp_allocator)
	testing.expect_value(t, res.candidate.tag, "v0.6.0")
	testing.expect_value(t, res.from_stable, true)
}

// ---------------------------------------------------------------------------
// Partial pages: never pick from a partial list

expect_incomplete :: proc(t: ^testing.T, res: Result, loc := #caller_location) {
	testing.expect_value(t, res.status, Status.Incomplete, loc)
	testing.expect_value(t, res.code, "resolve_incomplete", loc)
	testing.expect_value(t, res.candidate.tag, "", loc)
}

@(test)
test_fast_partial_pages_keep_installed :: proc(t: ^testing.T) {
	cases := []struct {
		name: string,
		set:  proc(f: ^Fake),
	}{
		{"500 on page 2", proc(f: ^Fake) {f.overrides["https://api.github.com/repositories/42/releases?per_page=100&page=2"] = Response{status = 500}}},
		{"transport error on page 3", proc(f: ^Fake) {f.fail_url = "https://api.github.com/repositories/42/releases?per_page=100&page=3"}},
		{"non-list body", proc(f: ^Fake) {f.overrides["https://api.github.com/repositories/42/releases?per_page=100&page=2"] = Response{status = 200, body = `{"message":"oops"}`}}},
		{"not json", proc(f: ^Fake) {f.overrides["https://api.github.com/repositories/42/releases?per_page=100&page=3"] = Response{status = 200, body = `<html>`}}},
		{"404 on page 2", proc(f: ^Fake) {f.overrides["https://api.github.com/repositories/42/releases?per_page=100&page=2"] = Response{status = 404}}},
		{"304 without cache", proc(f: ^Fake) {f.overrides["https://api.github.com/repositories/42/releases?per_page=100&page=2"] = Response{status = 304}}},
		{"foreign next link", proc(f: ^Fake) {f.next_host = "https://evil.example"}},
		{"loop", proc(f: ^Fake) {f.loop = true}},
		{"latest fails", proc(f: ^Fake) {f.overrides[LATEST_URL] = Response{status = 502}}},
	}
	for tc in cases {
		f: Fake
		fake_many(&f)
		if tc.name == "loop" {
			// Fit everything on one page so the loop link comes from the last page.
			f.per_page = 300
		}
		tc.set(&f)
		c := new_cache()
		res := resolve(.Fast, TARGET, &c, fake_get, &f, NOW, context.temp_allocator)
		testing.expectf(t, res.status == .Incomplete && res.candidate.tag == "", "%s: status %v candidate %q", tc.name, res.status, res.candidate.tag)
		testing.expectf(t, res.code == "resolve_incomplete", "%s: code %q", tc.name, res.code)
		testing.expectf(t, !res.rate_limited, "%s: not a rate limit", tc.name)
	}
}

@(test)
test_page_cap :: proc(t: ^testing.T) {
	f: Fake
	fake_small(&f)
	for i := 0; i < MAX_PAGES + 1; i += 1 {
		append(&f.rels, Fake_Rel{tag = strings.concatenate({"v0.1.0-rc.", titoa(i + 1)}, context.temp_allocator), prerelease = true})
	}
	f.per_page = 1
	f.latest = ""
	c := new_cache()
	res := resolve(.Fast, TARGET, &c, fake_get, &f, NOW, context.temp_allocator)
	expect_incomplete(t, res)
	testing.expect(t, strings.contains(res.detail, "100 pages"), res.detail)
}

// ---------------------------------------------------------------------------
// Rate limits

@(test)
test_rate_limit_403_with_reset :: proc(t: ^testing.T) {
	f: Fake
	fake_many(&f)
	reset := NOW + 1800
	f.overrides["https://api.github.com/repositories/42/releases?per_page=100&page=2"] = Response{status = 403, ratelimit_remaining = "0", ratelimit_reset = titoa(int(reset))}
	c := new_cache()
	res := resolve(.Fast, TARGET, &c, fake_get, &f, NOW, context.temp_allocator)
	expect_incomplete(t, res)
	testing.expect_value(t, res.rate_limited, true)
	testing.expect_value(t, res.retry_at, reset)
	testing.expect_value(t, c.rate_limit_reset_at, reset)

	// Nothing is requested before the reset, on either channel.
	n := len(f.requests)
	res = resolve(.Stable, TARGET, &c, fake_get, &f, NOW + 60, context.temp_allocator)
	expect_incomplete(t, res)
	testing.expect_value(t, res.rate_limited, true)
	testing.expect_value(t, len(f.requests), n)
	testing.expect_value(t, check_due(c, NOW + 60), false)

	schedule_after(&c, res, NOW + 60, 0.5)
	testing.expect(t, c.next_check_at >= reset && c.next_check_at <= reset + RATE_LIMIT_SPREAD)
	testing.expect_value(t, c.backoff_s, i64(0))

	// After the reset, requests resume.
	delete_key(&f.overrides, "https://api.github.com/repositories/42/releases?per_page=100&page=2")
	res = resolve(.Fast, TARGET, &c, fake_get, &f, reset, context.temp_allocator)
	testing.expect_value(t, res.status, Status.Candidate)
}

@(test)
test_rate_limit_429_retry_after :: proc(t: ^testing.T) {
	f: Fake
	fake_many(&f)
	f.overrides[LATEST_URL] = Response{status = 429, retry_after = "120"}
	c := new_cache()
	res := resolve(.Stable, TARGET, &c, fake_get, &f, NOW, context.temp_allocator)
	expect_incomplete(t, res)
	testing.expect_value(t, res.rate_limited, true)
	testing.expect_value(t, res.retry_at, NOW + 120)

	// Secondary limit: 403 + retry-after, with remaining > 0.
	f2: Fake
	fake_many(&f2)
	f2.overrides[LIST_URL] = Response{status = 403, retry_after = "30", ratelimit_remaining = "12"}
	c2 := new_cache()
	res = resolve(.Fast, TARGET, &c2, fake_get, &f2, NOW, context.temp_allocator)
	testing.expect_value(t, res.rate_limited, true)
	testing.expect_value(t, res.retry_at, NOW + 30)

	// 403 without any limit signal is an ordinary error (backoff, not a reset wait).
	f3: Fake
	fake_many(&f3)
	f3.overrides[LIST_URL] = Response{status = 403, ratelimit_remaining = "40"}
	c3 := new_cache()
	res = resolve(.Fast, TARGET, &c3, fake_get, &f3, NOW, context.temp_allocator)
	expect_incomplete(t, res)
	testing.expect_value(t, res.rate_limited, false)
	testing.expect_value(t, c3.rate_limit_reset_at, i64(0))
}

@(test)
test_rate_limit_preemptive_stop_mid_paging :: proc(t: ^testing.T) {
	f: Fake
	fake_many(&f)
	f.remaining = "0"
	f.reset = titoa(int(NOW + 900))
	c := new_cache()
	res := resolve(.Fast, TARGET, &c, fake_get, &f, NOW, context.temp_allocator)
	expect_incomplete(t, res)
	testing.expect_value(t, res.rate_limited, true)
	testing.expect_value(t, res.retry_at, NOW + 900)
	// /releases/latest said none remain: the list is not requested at all.
	testing.expect_value(t, len(f.requests), 1)
}

// ---------------------------------------------------------------------------
// Conditional requests

@(test)
test_conditional_requests_reuse_cached_pages :: proc(t: ^testing.T) {
	f: Fake
	fake_many(&f)
	f.etag_pages = true
	c := new_cache()
	res := resolve(.Fast, TARGET, &c, fake_get, &f, NOW, context.temp_allocator)
	testing.expect_value(t, res.candidate.tag, "v0.7.0-rc.150")
	testing.expect_value(t, len(c.pages), 4)

	// Round-trip resolver.json, then resolve again: every request is conditional
	// and every answer is 304, yet the result is the same.
	data, ok := cache_marshal(c, context.temp_allocator)
	testing.expect(t, ok)
	c2, ok2 := cache_unmarshal(data, context.temp_allocator)
	testing.expect(t, ok2)
	testing.expect_value(t, len(c2.pages), 4)
	n := len(f.requests)
	res = resolve(.Fast, TARGET, &c2, fake_get, &f, NOW + 10, context.temp_allocator)
	testing.expect_value(t, res.status, Status.Candidate)
	testing.expect_value(t, res.candidate.tag, "v0.7.0-rc.150")
	for r in f.requests[n:] {
		testing.expectf(t, r.if_none_match != "", "unconditional request for %s", r.url)
	}

	// A different target invalidates the cache (pages are reduced per target).
	res = resolve(.Fast, "darwin-arm64", &c2, fake_get, &f, NOW + 20, context.temp_allocator)
	testing.expect_value(t, c2.target, "darwin-arm64")
	testing.expect_value(t, res.status, Status.No_Candidate) // the fake only attaches linux-amd64 and windows-amd64

	// Garbage resolver.json is rejected rather than half-loaded.
	_, bad := cache_unmarshal(transmute([]byte)string("{nope"), context.temp_allocator)
	testing.expect(t, !bad)
}

@(test)
test_stable_pruning_keeps_only_visited_pages :: proc(t: ^testing.T) {
	f: Fake
	fake_many(&f)
	f.etag_pages = true
	c := new_cache()
	_ = resolve(.Fast, TARGET, &c, fake_get, &f, NOW, context.temp_allocator)
	testing.expect_value(t, len(c.pages), 4)
	_ = resolve(.Stable, TARGET, &c, fake_get, &f, NOW, context.temp_allocator)
	testing.expect_value(t, len(c.pages), 1)
	testing.expect_value(t, c.pages[0].url, LATEST_URL)
}

// ---------------------------------------------------------------------------
// Eligibility (§13.2)

ENGINE :: 1
ABI :: 1

offer :: proc(version, sha: string, seq: i64 = 0) -> Offer {
	return Offer{id = {version = version, sha256 = sha, seq = seq}, min_engine = 1, min_launcher_abi = 1}
}

@(test)
test_fast_to_stable_never_downgrades :: proc(t: ^testing.T) {
	// Installed from fast: 0.7.0-rc.150. Channel switched to stable; stable is 0.5.80.
	f: Fake
	fake_many(&f)
	c := new_cache()
	res := resolve(.Stable, TARGET, &c, fake_get, &f, NOW, context.temp_allocator)
	testing.expect_value(t, res.candidate.version, "0.5.80")
	installed := Release_Id{version = "0.7.0-rc.150", sha256 = "aa"}
	for a in ([]Action{.Timer, .Update_Now, .Retry_Failed}) {
		v, code := check_eligibility(a, installed, offer(res.candidate.version, "bb"), nil, ENGINE, ABI)
		testing.expectf(t, v == .Noop && code == "ahead_of_channel", "%v: %v %s", a, v, code)
	}
	// Only an explicit install_version may go lower.
	v, code := check_eligibility(.Install_Version, installed, offer("0.5.80", "bb"), nil, ENGINE, ABI)
	testing.expect_value(t, v, Verdict.Proceed)
	testing.expect_value(t, code, "")
	// A prerelease of the same core is lower than the release: 0.7.0 replaces 0.7.0-rc.150.
	v, _ = check_eligibility(.Timer, installed, offer("0.7.0", "cc"), nil, ENGINE, ABI)
	testing.expect_value(t, v, Verdict.Proceed)
}

@(test)
test_equal_version_different_digest_refused :: proc(t: ^testing.T) {
	installed := Release_Id{version = "0.5.80", sha256 = "aa", seq = 100}
	for a in Action {
		v, code := check_eligibility(a, installed, offer("0.5.80", "bb", 100), nil, ENGINE, ABI)
		testing.expectf(t, v == .Failed && code == "digest_conflict", "%v: %v %s", a, v, code)
		// Same bytes, re-signed (different seq): also a conflict.
		v, code = check_eligibility(a, installed, offer("0.5.80", "aa", 200), nil, ENGINE, ABI)
		testing.expectf(t, v == .Failed && code == "digest_conflict", "%v re-signed: %v %s", a, v, code)
	}
	// Build metadata does not make a different version.
	v, code := check_eligibility(.Timer, installed, offer("0.5.80+build.7", "bb", 100), nil, ENGINE, ABI)
	testing.expect_value(t, v, Verdict.Failed)
	testing.expect_value(t, code, "digest_conflict")
}

@(test)
test_eligibility_order :: proc(t: ^testing.T) {
	installed := Release_Id{version = "0.5.80", sha256 = "aa", seq = 100}
	v, code := check_eligibility(.Timer, installed, offer("0.5.80", "aa", 100), nil, ENGINE, ABI)
	testing.expect(t, v == .Noop && code == "up_to_date")
	// Unknown seq on either side does not fake a conflict.
	v, code = check_eligibility(.Timer, {version = "0.5.80", sha256 = "aa"}, offer("0.5.80", "aa", 100), nil, ENGINE, ABI)
	testing.expect(t, v == .Noop && code == "up_to_date")
	// Repair re-installs the same release.
	v, code = check_eligibility(.Repair, installed, offer("0.5.80", "aa", 100), nil, ENGINE, ABI)
	testing.expect(t, v == .Proceed, code)

	pins := []Pin{{version = "0.5.81", sha256 = "dd"}}
	v, code = check_eligibility(.Timer, installed, offer("0.5.81", "dd"), pins, ENGINE, ABI)
	testing.expect(t, v == .Noop && code == "pinned")
	v, code = check_eligibility(.Update_Now, installed, offer("0.5.81", "dd"), pins, ENGINE, ABI)
	testing.expect(t, v == .Noop && code == "pinned")
	v, _ = check_eligibility(.Retry_Failed, installed, offer("0.5.81", "dd"), pins, ENGINE, ABI)
	testing.expect_value(t, v, Verdict.Proceed)
	v, _ = check_eligibility(.Install_Version, installed, offer("0.5.81", "dd"), pins, ENGINE, ABI)
	testing.expect_value(t, v, Verdict.Proceed)
	// A pin is per bytes: a new digest of a pinned version is not pinned.
	v, _ = check_eligibility(.Timer, installed, offer("0.5.81", "ee"), pins, ENGINE, ABI)
	testing.expect_value(t, v, Verdict.Proceed)

	o := offer("0.5.81", "ee")
	o.min_engine = 0
	v, code = check_eligibility(.Timer, installed, o, nil, ENGINE, ABI)
	testing.expect(t, v == .Failed && code == "no_engine")
	o.min_engine = 2
	v, code = check_eligibility(.Timer, installed, o, nil, ENGINE, ABI)
	testing.expect(t, v == .Failed && code == "engine_too_old")
	o.min_engine, o.min_launcher_abi = 1, 2
	v, code = check_eligibility(.Timer, installed, o, nil, ENGINE, ABI)
	testing.expect(t, v == .Failed && code == "launcher_abi_too_old")
	// Downgrade check precedes engine checks.
	o = offer("0.5.1", "ff")
	o.min_engine = 0
	v, code = check_eligibility(.Timer, installed, o, nil, ENGINE, ABI)
	testing.expect(t, v == .Noop && code == "ahead_of_channel")
}

@(test)
test_manifest_match :: proc(t: ^testing.T) {
	r := Release{tag = "v0.5.80", version = "0.5.80", bundle = {name = "heimdall-local-linux-amd64-v0.5.80.tar.gz"}}
	ok, _ := check_manifest_match(r, "0.5.80", "heimdall-local-linux-amd64-v0.5.80.tar.gz")
	testing.expect(t, ok)
	ok2, code := check_manifest_match(r, "0.5.79", "heimdall-local-linux-amd64-v0.5.80.tar.gz")
	testing.expect(t, !ok2 && code == "manifest_mismatch")
	ok3, _ := check_manifest_match(r, "0.5.80", "heimdall-local-linux-amd64-v0.5.79.tar.gz")
	testing.expect(t, !ok3)
}

// ---------------------------------------------------------------------------
// SemVer, Link, cadence

@(test)
test_semver :: proc(t: ^testing.T) {
	ordered := []string{"1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.0.1", "1.10.0", "18446744073709551616.0.0"}
	for i in 0 ..< len(ordered) - 1 {
		testing.expectf(t, semver_compare_strings(ordered[i], ordered[i + 1]) < 0, "%s < %s", ordered[i], ordered[i + 1])
		testing.expectf(t, semver_compare_strings(ordered[i + 1], ordered[i]) > 0, "%s > %s", ordered[i + 1], ordered[i])
	}
	testing.expect_value(t, semver_compare_strings("1.0.0+a", "1.0.0+b"), 0)
	for bad in ([]string{"1.0", "1.0.0.0", "01.0.0", "1.0.0-", "1.0.0-01", "1.0.0-rc..1", "1.0.0-rc.", "1.0.0.", "1.0.0+", "1.0.0-r c", "v1.0.0", ""}) {
		_, ok := semver_parse(bad)
		testing.expectf(t, !ok, "%q must not parse", bad)
	}
	_, ok := semver_parse_tag("0.5.80")
	testing.expect(t, !ok, "tags need the v prefix")
	_, ok = semver_parse_tag("v0.5.80-rc.1+sha.abc")
	testing.expect(t, ok)
}

@(test)
test_link_next :: proc(t: ^testing.T) {
	testing.expect_value(t, link_next(`<https://api.github.com/x?page=2>; rel="next", <https://api.github.com/x?page=5>; rel="last"`, context.temp_allocator), "https://api.github.com/x?page=2")
	testing.expect_value(t, link_next(`<https://api.github.com/x?page=1>; rel="prev", <https://api.github.com/x?page=3>; rel="first"`, context.temp_allocator), "")
	testing.expect_value(t, link_next("", context.temp_allocator), "")
	testing.expect(t, next_url_allowed("https://api.github.com/repositories/42/releases?per_page=100&page=2"))
	testing.expect(t, !next_url_allowed("https://api.github.com.evil/repositories/42/releases?page=2"))
	testing.expect(t, !next_url_allowed("https://api.github.com@evil/releases?page=2"))
	testing.expect(t, !next_url_allowed("http://api.github.com/repositories/42/releases?page=2"))
}

@(test)
test_cadence :: proc(t: ^testing.T) {
	c := new_cache()
	schedule_start(&c, NOW, 0)
	testing.expect_value(t, c.next_check_at, NOW + 10 * MINUTE)
	schedule_start(&c, NOW, 0.999999)
	testing.expect(t, c.next_check_at <= NOW + 30 * MINUTE && c.next_check_at > NOW + 29 * MINUTE)
	testing.expect(t, !check_due(c, NOW))

	ok := Result{status = .Candidate}
	for u in ([]f64{0, 0.5, 0.999999, 1}) {
		schedule_after(&c, ok, NOW, u)
		testing.expectf(t, c.next_check_at >= NOW + 5 * HOUR + 30 * MINUTE && c.next_check_at <= NOW + 6 * HOUR + 30 * MINUTE, "u=%v next=%v", u, c.next_check_at - NOW)
	}
	schedule_after(&c, Result{status = .No_Candidate}, NOW, 0.5)
	testing.expect_value(t, c.next_check_at, NOW + 6 * HOUR)

	// Errors back off 15 min, doubling, capped at 6 h; success resets.
	bad := Result{status = .Incomplete}
	want := []i64{15 * MINUTE, 30 * MINUTE, HOUR, 2 * HOUR, 4 * HOUR, 6 * HOUR, 6 * HOUR}
	for w in want {
		schedule_after(&c, bad, NOW, 0.5)
		testing.expect_value(t, c.next_check_at - NOW, w)
	}
	schedule_after(&c, ok, NOW, 0.5)
	testing.expect_value(t, c.backoff_s, i64(0))
	schedule_after(&c, bad, NOW, 0.5)
	testing.expect_value(t, c.next_check_at - NOW, i64(15 * MINUTE))

	// A rate limit waits for the reset and survives a restart.
	schedule_after(&c, Result{status = .Incomplete, rate_limited = true, retry_at = NOW + 3 * HOUR}, NOW, 0)
	testing.expect_value(t, c.next_check_at, NOW + 3 * HOUR)
	schedule_start(&c, NOW + 60, 0)
	testing.expect_value(t, c.next_check_at, NOW + 3 * HOUR)
	testing.expect(t, check_due(c, NOW + 3 * HOUR))
}
