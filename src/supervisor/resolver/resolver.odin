package resolver

// GitHub release resolver for the bridge supervisor (T11). Implements
// docs/specs/bridge-supervisor-engine.md §13.1 (resolution), §13.3 (cadence, in
// cadence.odin) and §13.2 rules 1-6 (eligibility.odin).
//
// The package does no I/O of its own: HTTP goes through the injected Get proc
// and the clock is a parameter, so the engine (T13) and the failure-injection
// suite (T15) can drive every path. Its persistent state is the Cache, stored
// by the engine as <data>/supervisor/resolver.json (§3).
//
// Rules:
//   - stable: GET /releases/latest only. Never a list page, never an older
//     release; a latest release without this target's bundle + manifest +
//     signature is no_candidate (keep installed).
//   - fast: GET /releases?per_page=100 and every Link rel="next" page to the
//     end. Any page error, rate limit, non-list body, bad next link, loop or
//     page cap means resolve_incomplete: nothing is picked from a partial list.
//     Candidate = max(highest-SemVer prerelease, stable).
//   - Conditional requests: each URL's ETag / Last-Modified is cached with the
//     reduced page, so a 304 reuses the page; a 304 with nothing cached is an
//     error, never an empty page.
//   - Rate limits: 403/429 with retry-after or x-ratelimit-remaining: 0 stop the
//     resolution and set retry_at; no request is made before that time.
//
// Memory:
//   - A Cache owns all of its memory, allocated with cache.allocator (set by
//     cache_make / cache_unmarshal). resolve frees pages it replaces, prunes or
//     clears, and the old target; cache_destroy frees the rest. A Cache can be
//     held for the life of the supervisor.
//   - A Result owns its detail and candidate strings, allocated with resolve's
//     allocator argument; nothing in it aliases the cache. Free with
//     result_destroy (same allocator).
//   - resolve uses context.temp_allocator for parsing and scratch (a 100-release
//     page parses into a few MB). It never frees it: the caller must
//     free_all(context.temp_allocator) after each resolution, e.g. once per
//     timer tick.

import "core:encoding/json"
import "core:mem"
import "core:strconv"
import "core:strings"
import "odin_test:lib/releaserepo"

REPO :: releaserepo.REPO
API_BASE :: "https://api.github.com/repos/" + REPO
LATEST_URL :: API_BASE + "/releases/latest"
LIST_URL :: API_BASE + "/releases?per_page=100"
// Asset downloads must come from this repository's release download path (REQ-SRC-1).
DOWNLOAD_PREFIX :: "https://github.com/" + REPO + "/releases/download/"
// GitHub's Link URLs may use /repositories/<id>/ instead of /repos/<owner>/<repo>/.
NEXT_PREFIX :: "https://api.github.com/"
MANIFEST_ASSET :: "heimdall-release-manifest.json"
SIGNATURE_ASSET :: MANIFEST_ASSET + ".minisig"
// 100 pages of 100 releases. Reaching it means something is wrong; treat as incomplete.
MAX_PAGES :: 100
// Wait used when GitHub signals a limit without saying until when (secondary limits).
RATE_LIMIT_DEFAULT_WAIT :: 60
CACHE_SCHEMA :: 1

Channel :: enum {
	Stable,
	Fast,
}

Request :: struct {
	url:               string,
	if_none_match:     string, // cached ETag, "" when none
	if_modified_since: string, // cached Last-Modified, "" when none
}

// Response carries the status, body and the headers the resolver reads.
// Header values are raw strings, "" when absent.
Response :: struct {
	status:              int,
	body:                string,
	etag:                string,
	last_modified:       string,
	link:                string,
	retry_after:         string,
	ratelimit_remaining: string,
	ratelimit_reset:     string,
}

// Get performs one GET. ok = false is a transport failure (DNS, TLS, timeout);
// any HTTP status is ok = true with resp.status set.
Get :: #type proc(req: Request, user: rawptr) -> (resp: Response, ok: bool, detail: string)

Asset :: struct {
	name: string `json:"name"`,
	size: i64 `json:"size"`,
	url:  string `json:"url"`,
}

// Release is the part of a GitHub release the engine needs. Assets other than
// this target's bundle, the manifest and its signature are dropped; a missing
// asset has an empty name.
Release :: struct {
	tag:        string `json:"tag"`,
	version:    string `json:"version"`, // tag without "v", "" when the tag is not SemVer
	draft:      bool `json:"draft"`,
	prerelease: bool `json:"prerelease"`,
	bundle:     Asset `json:"bundle"`,
	manifest:   Asset `json:"manifest"`,
	signature:  Asset `json:"signature"`,
}

Cached_Page :: struct {
	url:           string `json:"url"`,
	etag:          string `json:"etag"`,
	last_modified: string `json:"last_modified"`,
	next:          string `json:"next"`, // Link rel="next", "" on the last page
	single:        bool `json:"single"`, // /releases/latest: one object, not a list
	releases:      []Release `json:"releases"`,
}

// Cache is resolver.json (§3): conditional-request cache plus the schedule.
// Create with cache_make or cache_unmarshal; free with cache_destroy.
Cache :: struct {
	using wire: Cache_Wire,
	allocator:  mem.Allocator, // owns target and every page (see Memory above)
}

// Cache_Wire is the persisted form of a Cache.
Cache_Wire :: struct {
	schema:              int `json:"schema"`,
	target:              string `json:"target"`, // pages are reduced for this target
	pages:               [dynamic]Cached_Page `json:"pages"`,
	next_check_at:       i64 `json:"next_check_at"`,
	backoff_s:           i64 `json:"backoff_s"`,
	rate_limit_reset_at: i64 `json:"rate_limit_reset_at"`,
}

Status :: enum {
	Candidate,    // candidate is set
	No_Candidate, // resolution complete, nothing for this target: keep installed
	Incomplete,   // failed resolve_incomplete: keep installed, retry later
}

Result :: struct {
	status:       Status,
	code:         string, // "", "no_candidate" or "resolve_incomplete"
	detail:       string, // human-readable reason for the status line
	candidate:    Release,
	from_stable:  bool, // fast only: the candidate is the stable release
	rate_limited: bool,
	retry_at:     i64, // when rate_limited: no request before this unix time
	requests:     int, // HTTP requests made (each counts against the 60/h anonymous limit)
}

// bundle_asset_name is the release asset for target at tag, as published by
// .github/workflows/release-local-binaries.yml (same rule as
// src/bridge/release_fetch.odin bridge_release_bundle_name).
bundle_asset_name :: proc(target, tag: string, allocator := context.allocator) -> string {
	ext := ".zip" if strings.has_prefix(target, "windows-") else ".tar.gz"
	return strings.concatenate({"heimdall-local-", target, "-", tag, ext}, allocator)
}

// release_usable: not a draft, SemVer tag, and this target's bundle plus the
// manifest and its signature are attached.
release_usable :: proc(r: Release) -> bool {
	return !r.draft && r.version != "" && r.bundle.name != "" && r.manifest.name != "" && r.signature.name != ""
}

// resolve finds the candidate for channel. cache is read for conditional
// requests and updated with fresh pages (in cache.allocator); the schedule
// fields are left to schedule_after (cadence.odin). The Result is owned by the
// caller (allocator; free with result_destroy). Scratch goes to
// context.temp_allocator, which the caller must free_all after each call.
resolve :: proc(
	channel: Channel,
	target: string,
	cache: ^Cache,
	get: Get,
	user: rawptr,
	now: i64,
	allocator := context.allocator,
) -> (res: Result) {
	if cache.allocator.procedure == nil do cache.allocator = context.allocator
	// Appends happen under the temp context below; pin the array to the cache's allocator.
	if cache.pages.allocator.procedure == nil do cache.pages.allocator = cache.allocator
	if cache.schema != CACHE_SCHEMA || cache.target != target {
		// Pages are reduced per target; another target's pages are useless.
		cache_clear_pages(cache)
		delete(cache.target, cache.allocator)
		cache.schema = CACHE_SCHEMA
		cache.target = strings.clone(target, cache.allocator)
	}
	visited := make([dynamic]string, context.temp_allocator)
	complete: bool
	{
		context.allocator = context.temp_allocator
		res, complete = resolve_scratch(channel, target, cache, get, user, now, &visited)
	}
	// Copy out before pruning: the candidate may point into a cached page.
	res.detail = strings.clone(res.detail, allocator)
	res.candidate = release_clone(res.candidate, allocator)
	if complete do prune(cache, visited[:])
	return res
}

// result_destroy frees what resolve allocated for res.
result_destroy :: proc(res: ^Result, allocator := context.allocator) {
	delete(res.detail, allocator)
	release_destroy(&res.candidate, allocator)
	res^ = {}
}

// resolve_scratch does the work with every string in context.allocator
// (temp) or the cache; its Result may alias cached pages. complete = the
// resolution saw every page it needed (cache may be pruned to them).
@(private)
resolve_scratch :: proc(
	channel: Channel,
	target: string,
	cache: ^Cache,
	get: Get,
	user: rawptr,
	now: i64,
	visited: ^[dynamic]string,
) -> (res: Result, complete: bool) {
	if now < cache.rate_limit_reset_at {
		return incomplete_rate_limited(res, cache.rate_limit_reset_at, "GitHub rate limit in effect"), false
	}

	stable, stable_ok, stable_res := resolve_stable(target, cache, get, user, now, visited, &res)
	if stable_res.status == .Incomplete do return stable_res, false

	if channel == .Stable {
		res.status = .Candidate if stable_ok else .No_Candidate
		res.candidate = stable
		if !stable_ok {
			res.code = "no_candidate"
			res.detail = stable_res.detail
		}
		// rate_limited is reported only with Incomplete; the cache keeps the reset time.
		res.rate_limited, res.retry_at = false, 0
		return res, true
	}

	best: Release
	have_best := false
	url: string = LIST_URL
	for page_no := 1;; page_no += 1 {
		if page_no > MAX_PAGES {
			return incomplete(res, "more than 100 pages of releases; refusing to pick from a partial list"), false
		}
		for seen in visited^ {
			if seen == url do return incomplete(res, "release pages link back to an earlier page"), false
		}
		// Stop before a request that GitHub has already told us will be refused.
		if res.rate_limited do return incomplete_rate_limited(res, res.retry_at, "GitHub rate limit reached while paging releases"), false
		append(visited, url)
		page, perr, rl_at := fetch_page(url, false, target, cache, get, user, now, &res)
		if rl_at != 0 do return incomplete_rate_limited(res, rl_at, perr), false
		if perr != "" do return incomplete(res, strings.concatenate({"release page ", itoa(page_no), ": ", perr})), false
		for r in page.releases {
			if !r.prerelease || !release_usable(r) do continue
			if !have_best || semver_compare_strings(r.version, best.version) > 0 {
				best, have_best = r, true
			}
		}
		if page.next == "" do break
		if !next_url_allowed(page.next) {
			return incomplete(res, "release list links to a page outside api.github.com"), false
		}
		url = page.next
	}

	switch {
	case stable_ok && (!have_best || semver_compare_strings(stable.version, best.version) >= 0):
		res.status, res.candidate, res.from_stable = .Candidate, stable, true
	case have_best:
		res.status, res.candidate = .Candidate, best
	case:
		res.status, res.code = .No_Candidate, "no_candidate"
		res.detail = strings.concatenate({"no release carries a ", target, " bundle and a signed manifest"})
	}
	res.rate_limited, res.retry_at = false, 0
	return res, true
}

@(private)
resolve_stable :: proc(
	target: string,
	cache: ^Cache,
	get: Get,
	user: rawptr,
	now: i64,
	visited: ^[dynamic]string,
	acc: ^Result,
) -> (r: Release, ok: bool, res: Result) {
	append(visited, LATEST_URL)
	page, perr, rl_at := fetch_page(LATEST_URL, true, target, cache, get, user, now, acc)
	res = acc^
	if rl_at != 0 do return {}, false, incomplete_rate_limited(res, rl_at, perr)
	if perr == "no stable release" {
		res.detail = "GitHub reports no stable release"
		return {}, false, res
	}
	if perr != "" do return {}, false, incomplete(res, strings.concatenate({"latest release: ", perr}))
	if len(page.releases) != 1 do return {}, false, incomplete(res, "latest release: GitHub did not return a release")
	r = page.releases[0]
	switch {
	case r.draft || r.prerelease:
		res.detail = strings.concatenate({"latest release ", r.tag, " is not a stable release"})
	case r.version == "":
		res.detail = strings.concatenate({"latest release tag ", r.tag, " is not v+SemVer"})
	case !release_usable(r):
		res.detail = strings.concatenate({"stable release ", r.tag, " has no ", target, " bundle with a signed manifest"})
	case:
		return r, true, res
	}
	return {}, false, res
}

// fetch_page GETs url conditionally and returns the reduced page. err != ""
// on any failure; rl_at != 0 when the failure is a rate limit. On success
// acc.rate_limited/retry_at are set if GitHub says no requests remain.
@(private)
fetch_page :: proc(
	url: string,
	single: bool,
	target: string,
	cache: ^Cache,
	get: Get,
	user: rawptr,
	now: i64,
	acc: ^Result,
) -> (page: Cached_Page, err: string, rl_at: i64) {
	cached_idx := -1
	for p, i in cache.pages {
		if p.url == url && p.single == single {
			cached_idx = i
			break
		}
	}
	req := Request{url = url}
	if cached_idx >= 0 {
		req.if_none_match = cache.pages[cached_idx].etag
		req.if_modified_since = cache.pages[cached_idx].last_modified
	}
	resp, ok, detail := get(req, user)
	acc.requests += 1
	if !ok do return {}, strings.concatenate({"request failed (", detail, ")"}), 0
	if at, limited := rate_limit_at(resp, now); limited {
		cache.rate_limit_reset_at = at
		return {}, "GitHub rate limit", at
	}
	if strings.trim_space(resp.ratelimit_remaining) == "0" {
		at, _ := rate_limit_at(Response{status = 429, ratelimit_reset = resp.ratelimit_reset}, now)
		acc.rate_limited, acc.retry_at = true, at
		cache.rate_limit_reset_at = at
	}
	switch resp.status {
	case 304:
		if cached_idx < 0 do return {}, "HTTP 304 for a page that is not cached", 0
		return cache.pages[cached_idx], "", 0
	case 200:
	case 404:
		if single do return {}, "no stable release", 0
		return {}, "HTTP 404", 0
	case:
		return {}, strings.concatenate({"HTTP ", itoa(resp.status)}), 0
	}
	ca := cache.allocator
	releases, perr := parse_releases(resp.body, single, target, ca)
	if perr != "" do return {}, perr, 0
	page = Cached_Page {
		url           = strings.clone(url, ca),
		etag          = strings.clone(resp.etag, ca),
		last_modified = strings.clone(resp.last_modified, ca),
		next          = "" if single else link_next(resp.link, ca),
		single        = single,
		releases      = releases,
	}
	if cached_idx >= 0 {
		page_destroy(&cache.pages[cached_idx], ca)
		cache.pages[cached_idx] = page
	} else {
		append(&cache.pages, page)
	}
	return page, "", 0
}

// rate_limit_at reports whether resp is a rate-limit refusal and until when.
// GitHub: 429, or 403 with x-ratelimit-remaining: 0 or a retry-after header.
rate_limit_at :: proc(resp: Response, now: i64) -> (at: i64, limited: bool) {
	retry_after := strings.trim_space(resp.retry_after)
	remaining := strings.trim_space(resp.ratelimit_remaining)
	if resp.status != 429 && !(resp.status == 403 && (remaining == "0" || retry_after != "")) do return 0, false
	if secs, ok := strconv.parse_i64_of_base(retry_after, 10); ok && secs >= 0 {
		return now + max(secs, 1), true
	}
	if reset, ok := strconv.parse_i64_of_base(strings.trim_space(resp.ratelimit_reset), 10); ok && reset > now {
		return reset, true
	}
	return now + RATE_LIMIT_DEFAULT_WAIT, true
}

// parse_releases reduces a GitHub releases document: a list, or with single
// the object of /releases/latest. Anything else is an error.
@(private)
parse_releases :: proc(body: string, single: bool, target: string, allocator: mem.Allocator) -> (out: []Release, err: string) {
	value, perr := json.parse_string(body, parse_integers = true, allocator = context.temp_allocator)
	if perr != .None do return nil, "GitHub returned a body that is not JSON"
	items := make([dynamic]json.Object, context.temp_allocator)
	if single {
		obj, ok := value.(json.Object)
		if !ok do return nil, "GitHub did not return a release object"
		append(&items, obj)
	} else {
		arr, ok := value.(json.Array)
		if !ok do return nil, "GitHub did not return a release list"
		for item in arr {
			obj, is_obj := item.(json.Object)
			if !is_obj do return nil, "GitHub returned a release list with a non-object entry"
			append(&items, obj)
		}
	}
	list := make([]Release, len(items), allocator)
	for obj, i in items {
		r := &list[i]
		tag, _ := obj["tag_name"].(json.String)
		r.tag = strings.clone(tag, allocator)
		r.draft, _ = obj["draft"].(json.Boolean)
		r.prerelease, _ = obj["prerelease"].(json.Boolean)
		if _, ok := semver_parse_tag(tag); ok do r.version = strings.clone(tag[1:], allocator)
		if r.version == "" do continue
		want_bundle := bundle_asset_name(target, tag, context.temp_allocator)
		assets, _ := obj["assets"].(json.Array)
		for a in assets {
			ao, _ := a.(json.Object)
			name, _ := ao["name"].(json.String)
			dl, _ := ao["browser_download_url"].(json.String)
			size, _ := ao["size"].(json.Integer)
			// The asset must be served from this release's download path.
			if dl != strings.concatenate({DOWNLOAD_PREFIX, tag, "/", name}, context.temp_allocator) do continue
			if name != want_bundle && name != MANIFEST_ASSET && name != SIGNATURE_ASSET do continue
			asset := Asset{name = strings.clone(name, allocator), size = size, url = strings.clone(dl, allocator)}
			slot := &r.signature
			if name == want_bundle {
				slot = &r.bundle
			} else if name == MANIFEST_ASSET {
				slot = &r.manifest
			}
			asset_destroy(slot, allocator) // a duplicate asset name replaces the earlier one
			slot^ = asset
		}
	}
	return list, ""
}

// link_next extracts rel="next" from an RFC 8288 Link header.
link_next :: proc(link: string, allocator := context.allocator) -> string {
	rest := link
	for part in strings.split_iterator(&rest, ",") {
		p := strings.trim_space(part)
		lt, gt := strings.index_byte(p, '<'), strings.index_byte(p, '>')
		if lt != 0 || gt < 0 do continue
		params := p[gt + 1:]
		for param in strings.split_iterator(&params, ";") {
			kv := strings.trim_space(param)
			if kv == `rel="next"` || kv == "rel=next" do return strings.clone(p[1:gt], allocator)
		}
	}
	return ""
}

@(private)
next_url_allowed :: proc(url: string) -> bool {
	if !strings.has_prefix(url, NEXT_PREFIX) do return false
	path := url[len(NEXT_PREFIX):]
	for c in transmute([]byte)path {
		// No userinfo, fragments, whitespace or backslashes; the host is fixed above.
		if c == '@' || c == '#' || c == '\\' || c <= ' ' do return false
	}
	return strings.contains(path, "/releases?")
}

// prune drops cached pages not visited by a complete resolution.
@(private)
prune :: proc(cache: ^Cache, visited: []string) {
	kept := 0
	for p in cache.pages {
		keep := false
		for v in visited {
			if v == p.url {
				keep = true
				break
			}
		}
		if keep {
			cache.pages[kept] = p
			kept += 1
		} else {
			pp := p
			page_destroy(&pp, cache.allocator)
		}
	}
	resize(&cache.pages, kept)
}

@(private)
incomplete :: proc(res: Result, detail: string) -> Result {
	out := res
	out.status, out.code, out.detail = .Incomplete, "resolve_incomplete", detail
	out.candidate, out.from_stable = {}, false
	return out
}

@(private)
incomplete_rate_limited :: proc(res: Result, at: i64, detail: string) -> Result {
	out := incomplete(res, detail)
	out.rate_limited, out.retry_at = true, at
	return out
}

@(private)
itoa :: proc(n: int, allocator := context.allocator) -> string {
	buf: [24]byte
	return strings.clone(strconv.write_int(buf[:], i64(n), 10), allocator)
}

// cache_marshal / cache_unmarshal convert resolver.json. The engine writes the
// bytes with its atomic file replace (§4.3 rules); an unreadable file is
// replaced by an empty cache (the only cost is unconditional requests).
cache_marshal :: proc(cache: Cache, allocator := context.allocator) -> (data: []byte, ok: bool) {
	out, err := json.marshal(cache.wire, {pretty = true}, allocator)
	return out, err == nil
}

// cache_unmarshal returns a Cache owned by allocator. A failed parse leaves
// nothing allocated (it parses into temp and deep-copies on success).
cache_unmarshal :: proc(data: []byte, allocator := context.allocator) -> (cache: Cache, ok: bool) {
	wire: Cache_Wire
	if json.unmarshal(data, &wire, allocator = context.temp_allocator) != nil || wire.schema != CACHE_SCHEMA {
		return cache_make(allocator), false
	}
	cache = cache_make(allocator)
	cache.wire.schema = wire.schema
	cache.target = strings.clone(wire.target, allocator)
	cache.next_check_at, cache.backoff_s, cache.rate_limit_reset_at = wire.next_check_at, wire.backoff_s, wire.rate_limit_reset_at
	for p in wire.pages do append(&cache.pages, page_clone(p, allocator))
	return cache, true
}

// cache_make returns an empty Cache whose memory comes from allocator.
cache_make :: proc(allocator := context.allocator) -> Cache {
	return Cache{allocator = allocator, wire = {pages = make([dynamic]Cached_Page, allocator)}}
}

// cache_destroy frees everything the cache owns.
cache_destroy :: proc(cache: ^Cache) {
	cache_clear_pages(cache)
	delete(cache.pages)
	delete(cache.target, cache.allocator)
	cache^ = {}
}

@(private)
cache_clear_pages :: proc(cache: ^Cache) {
	for &p in cache.pages do page_destroy(&p, cache.allocator)
	clear(&cache.pages)
}

page_clone :: proc(p: Cached_Page, allocator := context.allocator) -> Cached_Page {
	out := p
	out.url = strings.clone(p.url, allocator)
	out.etag = strings.clone(p.etag, allocator)
	out.last_modified = strings.clone(p.last_modified, allocator)
	out.next = strings.clone(p.next, allocator)
	out.releases = make([]Release, len(p.releases), allocator)
	for r, i in p.releases do out.releases[i] = release_clone(r, allocator)
	return out
}

page_destroy :: proc(p: ^Cached_Page, allocator := context.allocator) {
	delete(p.url, allocator)
	delete(p.etag, allocator)
	delete(p.last_modified, allocator)
	delete(p.next, allocator)
	for &r in p.releases do release_destroy(&r, allocator)
	delete(p.releases, allocator)
	p^ = {}
}

release_clone :: proc(r: Release, allocator := context.allocator) -> Release {
	out := r
	out.tag = strings.clone(r.tag, allocator)
	out.version = strings.clone(r.version, allocator)
	out.bundle = asset_clone(r.bundle, allocator)
	out.manifest = asset_clone(r.manifest, allocator)
	out.signature = asset_clone(r.signature, allocator)
	return out
}

release_destroy :: proc(r: ^Release, allocator := context.allocator) {
	delete(r.tag, allocator)
	delete(r.version, allocator)
	asset_destroy(&r.bundle, allocator)
	asset_destroy(&r.manifest, allocator)
	asset_destroy(&r.signature, allocator)
	r^ = {}
}

@(private)
asset_clone :: proc(a: Asset, allocator: mem.Allocator) -> Asset {
	return Asset{name = strings.clone(a.name, allocator), size = a.size, url = strings.clone(a.url, allocator)}
}

@(private)
asset_destroy :: proc(a: ^Asset, allocator: mem.Allocator) {
	delete(a.name, allocator)
	delete(a.url, allocator)
	a^ = {}
}
