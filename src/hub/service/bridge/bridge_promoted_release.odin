package bridge

import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "base:runtime"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import httpc "odin_test:lib/httpc"

// A structured request seam keeps tests offline and the outbound HTTP boundary intact.
Bridge_Catalog_Get :: #type proc(req: httpc.Request) -> (body: string, ok: bool, reason: string)

bridge_catalog_http_get :: proc(req: httpc.Request) -> (body: string, ok: bool, reason: string) {
	resp, err := httpc.send(req, context.temp_allocator)
	if err != .None do return "", false, httpc.error_string(err)
	if resp.status != 200 do return "", false, fmt.tprintf("HTTP %d", resp.status)
	return string(resp.body), true, ""
}

Bridge_Catalog_Asset :: struct { name: string }
Bridge_Catalog_Release :: struct {
	tag_name: string,
	draft, prerelease: bool,
	assets: []Bridge_Catalog_Asset,
}

bridge_catalog_bundle :: proc(target, tag: string) -> string {
	ext := ".zip" if strings.has_prefix(target, "windows-") else ".tar.gz"
	return fmt.tprintf("heimdall-local-%s-%s%s", target, tag, ext)
}

// Match the desktop's VERSION_PATTERN: tags are safe single path segments.
bridge_catalog_tag_valid :: proc(tag: string) -> bool {
	if tag == "" || tag == "." || tag == ".." do return false
	for c in tag {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '.' || c == '_' || c == '-') do return false
	}
	return true
}

bridge_catalog_digest :: proc(sums, name: string) -> string {
	found := 0
	digest := ""
	rest := sums
	for line in strings.split_lines_iterator(&rest) {
		fields := strings.fields(line, context.temp_allocator)
		if len(fields) != 2 || strings.trim_left(fields[1], "*") != name do continue
		if len(fields[0]) != 64 do return ""
		if _, ok := hex.decode(transmute([]byte)fields[0], context.temp_allocator); !ok do return ""
		digest = strings.to_lower(fields[0], context.temp_allocator)
		found += 1
	}
	return digest if found == 1 else ""
}

bridge_catalog_request :: proc(base: string, path: []string, query: []httpc.Query_Param = nil) -> httpc.Request {
	u, _ := httpc.parse_url(base)
	headers := make([]httpc.Header, 2, context.temp_allocator)
	headers[0], headers[1] = httpc.accept("application/vnd.github+json"), httpc.user_agent("ham-hub")
	return {method = .GET, url = u, path = path, query = query,
		headers = headers,
		timeout_ms = 5_000, connect_timeout_ms = 2_000, max_redirects = 5, max_response_bytes = 4 * 1024 * 1024}
}

// Bridge_Catalog_Memo dedupes identical GETs within one refresh: every target
// reads the same release list, pin and SHA256SUMS documents, so a refresh costs a
// handful of GitHub calls instead of one list per target (unauthenticated GitHub
// allows 60 requests per hour). Entries live in the temp allocator.
Bridge_Catalog_Memo_Entry :: struct {
	body, reason: string,
	ok: bool,
}
Bridge_Catalog_Memo :: struct {
	get: Bridge_Catalog_Get,
	seen: map[string]Bridge_Catalog_Memo_Entry,
}

bridge_catalog_memo_get :: proc(memo: ^Bridge_Catalog_Memo, req: httpc.Request) -> (body: string, ok: bool, reason: string) {
	key, err := httpc.build_url(req.url, req.path, req.query, allocator = context.temp_allocator)
	if err != .None do return memo.get(req)
	if memo.seen == nil do memo.seen = make(map[string]Bridge_Catalog_Memo_Entry, context.temp_allocator)
	if hit, found := memo.seen[key]; found do return hit.body, hit.ok, hit.reason
	body, ok, reason = memo.get(req)
	memo.seen[key] = {body = body, ok = ok, reason = reason}
	return
}

// GitHub lists releases newest first, BRIDGE_CATALOG_PAGE_SIZE per page. The
// stable reader and the choices reader request identical pages, so the refresh
// memo fetches each page once. 100 per page would be ~3.6 MB, too close to the
// request's 4 MiB response cap; 30 keeps every page well under it.
BRIDGE_CATALOG_PAGE_SIZE :: 30
// Defensive bound on pagination (3000 releases); hitting it is an error, never
// a silently partial list.
BRIDGE_CATALOG_MAX_PAGES :: 100

bridge_catalog_releases_request :: proc(page: int) -> httpc.Request {
	size := fmt.tprintf("%d", BRIDGE_CATALOG_PAGE_SIZE)
	query := make([]httpc.Query_Param, 1 if page <= 1 else 2, context.temp_allocator)
	query[0] = {"per_page", size}
	if page > 1 do query[1] = {"page", fmt.tprintf("%d", page)}
	return bridge_catalog_request("https://api.github.com", {"repos", "tanmayv", "heimdall-agent-manager", "releases"}, query)
}

// bridge_catalog_fetch_release resolves the newest promoted release that has a
// verified artifact for target (or the pinned tag). It pages the release list
// until a match or the last page: promoted releases can sit far below the first
// page when many prereleases ship between promotions (report F9).
bridge_catalog_fetch_release :: proc(memo: ^Bridge_Catalog_Memo, target, pin: string) -> (info: Bridge_Update_Info, reachable: bool) {
	info.target, info.latest_source = target, "promoted"
	if pin != "" {
		if !bridge_catalog_tag_valid(pin) {
			info.fallback_reason = "invalid operator release tag"
			return info, true
		}
		tag := pin if strings.has_prefix(pin, "v") else fmt.tprintf("v%s", pin)
		req := bridge_catalog_request("https://api.github.com", {"repos", "tanmayv", "heimdall-agent-manager", "releases", "tags", tag})
		doc, ok, reason := bridge_catalog_memo_get(memo, req)
		if !ok {
			info.fallback_reason = fmt.tprintf("cannot resolve promoted releases: %s", reason)
			return info, false
		}
		releases := make([]Bridge_Catalog_Release, 1, context.temp_allocator)
		if json.unmarshal_string(doc, &releases[0], allocator = context.temp_allocator) != nil {
			info.fallback_reason = "release source returned invalid release metadata"
			return info, false
		}
		if found, failed := bridge_catalog_pick_release(memo, &info, releases, target, pin); found || failed do return info, !failed
		info.warning = fmt.tprintf("Pinned release %s has no verified artifact for %s", pin, target)
		return info, true
	}
	for page in 1..=BRIDGE_CATALOG_MAX_PAGES {
		doc, ok, reason := bridge_catalog_memo_get(memo, bridge_catalog_releases_request(page))
		if !ok {
			info.fallback_reason = fmt.tprintf("cannot resolve promoted releases: %s", reason)
			return info, false
		}
		releases: []Bridge_Catalog_Release
		if err := json.unmarshal_string(doc, &releases, allocator = context.temp_allocator); err != nil {
			info.fallback_reason = fmt.tprintf("release source returned an invalid release list: %v", err)
			return info, false
		}
		if found, failed := bridge_catalog_pick_release(memo, &info, releases, target, ""); found || failed do return info, !failed
		if len(releases) < BRIDGE_CATALOG_PAGE_SIZE {
			info.warning = fmt.tprintf("No promoted release has a verified artifact for %s", target)
			return info, true
		}
	}
	info.fallback_reason = fmt.tprintf("release list exceeds %d pages", BRIDGE_CATALOG_MAX_PAGES)
	return info, false
}

// bridge_catalog_pick_release fills info from the first qualifying release in
// list order. failed reports a fetch error (info.fallback_reason is set).
@(private)
bridge_catalog_pick_release :: proc(memo: ^Bridge_Catalog_Memo, info: ^Bridge_Update_Info, releases: []Bridge_Catalog_Release, target, pin: string) -> (found, failed: bool) {
	// GitHub lists newest promotions first, matching the desktop's latestRelease.
	for release in releases {
		if release.draft || (pin == "" && release.prerelease) || !bridge_catalog_tag_valid(release.tag_name) do continue
		if pin != "" && strings.trim_prefix(pin, "v") != strings.trim_prefix(release.tag_name, "v") do continue
		name := bridge_catalog_bundle(target, release.tag_name)
		has_bundle, has_sums := false, false
		for asset in release.assets {
			if asset.name == name do has_bundle = true
			if asset.name == "SHA256SUMS" do has_sums = true
		}
		if !has_bundle || !has_sums do continue
		path := []string{"tanmayv", "heimdall-agent-manager", "releases", "download", release.tag_name, "SHA256SUMS"}
		sums, fetched, detail := bridge_catalog_memo_get(memo, bridge_catalog_request("https://github.com", path))
		if !fetched {
			info.fallback_reason = fmt.tprintf("cannot fetch SHA256SUMS for %s: %s", release.tag_name, detail)
			return false, true
		}
		digest := bridge_catalog_digest(sums, name)
		if digest == "" do continue
		path[len(path)-1] = name
		bundle_req := bridge_catalog_request("https://github.com", path)
		url, url_err := httpc.build_url(bundle_req.url, bundle_req.path, allocator = context.temp_allocator)
		if url_err != .None do continue
		info.latest_version = strings.trim_prefix(release.tag_name, "v")
		info.download_url, info.sha256 = url, digest
		info.artifact_available = true
		return true, false
	}
	return false, false
}

// BRIDGE_CATALOG_REFRESH_INTERVAL is how often the background refresher re-reads
// the promoted releases. Request handlers never call GitHub (GET /bridges used to
// spend seconds on a cold per-target cache), so a promotion reaches the UI and the
// bridges within this interval of its publication, or on a hub restart.
BRIDGE_CATALOG_REFRESH_INTERVAL :: 30 * time.Minute

// Every target with release artifacts (canonical_bridge_platform); the snapshot
// holds one latest slot and one pinned slot per target.
BRIDGE_CATALOG_TARGETS :: [7]string{"linux-amd64", "linux-arm64", "darwin-amd64", "darwin-arm64", "termux-arm64", "windows-amd64", "windows-arm64"}
BRIDGE_CATALOG_SLOTS :: 2 * len(BRIDGE_CATALOG_TARGETS)

Bridge_Catalog_Entry :: struct {
	at: time.Time,
	populated, reachable: bool,
	pin: string,
	info: Bridge_Update_Info,
}

bridge_catalog_copy_info :: proc(info: Bridge_Update_Info, allocator: mem.Allocator) -> Bridge_Update_Info {
	result := info
	result.target = strings.clone(info.target, allocator)
	result.latest_version = strings.clone(info.latest_version, allocator)
	result.latest_commit_sha = strings.clone(info.latest_commit_sha, allocator)
	result.latest_source = strings.clone(info.latest_source, allocator)
	result.download_url = strings.clone(info.download_url, allocator)
	result.sha256 = strings.clone(info.sha256, allocator)
	result.warning = strings.clone(info.warning, allocator)
	result.fallback_reason = strings.clone(info.fallback_reason, allocator)
	return result
}

bridge_catalog_entry_destroy :: proc(entry: ^Bridge_Catalog_Entry) {
	if !entry.populated do return
	context.allocator = runtime.default_allocator()
	delete(entry.pin)
	delete(entry.info.target)
	delete(entry.info.latest_version)
	delete(entry.info.latest_commit_sha)
	delete(entry.info.latest_source)
	delete(entry.info.download_url)
	delete(entry.info.sha256)
	delete(entry.info.warning)
	delete(entry.info.fallback_reason)
	entry^ = {}
}

// bridge_update_catalog_destroy stops the refresher, then frees the snapshot.
bridge_update_catalog_destroy :: proc(catalog: ^Bridge_Update_Catalog) {
	if catalog == nil do return
	bridge_catalog_refresher_stop(catalog)
	sync.mutex_lock(&catalog.snapshot_mutex)
	defer sync.mutex_unlock(&catalog.snapshot_mutex)
	for &entry in catalog.snapshot do bridge_catalog_entry_destroy(&entry)
	bridge_catalog_choices_destroy(catalog.choices)
	catalog.choices, catalog.choices_loaded = nil, false
}

bridge_catalog_slot :: proc(target, pin: string) -> int {
	targets := BRIDGE_CATALOG_TARGETS
	for candidate, i in targets {
		if candidate == target do return i * 2 + (1 if pin != "" else 0)
	}
	return -1
}

// bridge_catalog_release serves the in-memory snapshot only: no request path
// reaches GitHub. Strings use context.temp_allocator. Before the first refresh
// lands the result is unreachable, so callers fall back to the manifest.
bridge_catalog_release :: proc(catalog: ^Bridge_Update_Catalog, target, pin: string) -> (Bridge_Update_Info, bool) {
	miss := Bridge_Update_Info{target = target, latest_source = "promoted"}
	if catalog == nil || catalog.release_get == nil {
		miss.fallback_reason = "release source is not configured"
		return miss, false
	}
	index := bridge_catalog_slot(target, pin)
	if index < 0 {
		miss.fallback_reason = fmt.tprintf("no promoted releases are published for target %s", target)
		return miss, false
	}
	sync.mutex_lock(&catalog.snapshot_mutex)
	defer sync.mutex_unlock(&catalog.snapshot_mutex)
	entry := &catalog.snapshot[index]
	if !entry.populated || entry.pin != pin {
		miss.fallback_reason = "promoted releases have not been loaded yet"
		return miss, false
	}
	return bridge_catalog_copy_info(entry.info, context.temp_allocator), entry.reachable
}

// bridge_catalog_refresh fetches every target (and the operator pin, if set)
// outside the snapshot lock, then swaps the results in under it. An unreachable
// result never replaces a reachable one: an outage keeps serving the last good
// promotion. Temp allocations are the caller's to reset.
bridge_catalog_refresh :: proc(catalog: ^Bridge_Update_Catalog) -> (reachable, total: int) {
	if catalog == nil || catalog.release_get == nil do return 0, 0
	memo := Bridge_Catalog_Memo{get = catalog.release_get}
	targets := BRIDGE_CATALOG_TARGETS
	pins := [2]string{"", catalog.override_version}
	pin_count := 1 if catalog.override_version == "" else 2
	fresh: [BRIDGE_CATALOG_SLOTS]Bridge_Catalog_Entry
	now := time.now()
	failure := ""
	for target in targets {
		for pin in pins[:pin_count] {
			info, ok := bridge_catalog_fetch_release(&memo, target, pin)
			fresh[bridge_catalog_slot(target, pin)] = {at = now, populated = true, reachable = ok,
				pin = strings.clone(pin, runtime.default_allocator()), info = bridge_catalog_copy_info(info, runtime.default_allocator())}
			total += 1
			if ok {
				reachable += 1
			} else if failure == "" {
				failure = info.fallback_reason
			}
		}
	}
	choices, choices_ok := bridge_catalog_fetch_choices(&memo)
	sync.mutex_lock(&catalog.snapshot_mutex)
	if choices_ok {
		bridge_catalog_choices_destroy(catalog.choices)
		catalog.choices = make([]Bridge_Catalog_Choice, len(choices), runtime.default_allocator())
		for item, i in choices {
			catalog.choices[i] = item
			catalog.choices[i].tag = strings.clone(item.tag, runtime.default_allocator())
		}
		catalog.choices_loaded = true
	}
	for &entry, i in fresh {
		if !entry.populated do continue
		current := &catalog.snapshot[i]
		if !entry.reachable && current.populated && current.reachable && current.pin == entry.pin do continue
		// Swap: the old entry leaves the lock in `fresh` and is freed below.
		current^, entry = entry, current^
	}
	sync.mutex_unlock(&catalog.snapshot_mutex)
	for &entry in fresh do bridge_catalog_entry_destroy(&entry)
	if reachable < total {
		fmt.eprintfln("hub: promoted bridge release refresh: %d/%d lookups failed, keeping the last good snapshot: %s", total - reachable, total, failure)
	}
	return
}

// bridge_catalog_refresher_start refreshes at once and then every interval on
// its own thread, which inherits the caller's context. Startup never waits on it.
bridge_catalog_refresher_start :: proc(catalog: ^Bridge_Update_Catalog) {
	if catalog == nil || catalog.release_get == nil || catalog.refresher != nil do return
	catalog.refresher_stop = false
	// thread-spawn: startup (caller's allocator is the process heap)
	catalog.refresher = thread.create_and_start_with_data(rawptr(catalog), bridge_catalog_refresher_entry, init_context = context)
}

// bridge_catalog_refresher_stop wakes the refresher and joins it. A refresh in
// flight finishes first; each GitHub call is bounded by its request timeout.
bridge_catalog_refresher_stop :: proc(catalog: ^Bridge_Update_Catalog) {
	if catalog == nil || catalog.refresher == nil do return
	sync.mutex_lock(&catalog.refresher_mutex)
	catalog.refresher_stop = true
	sync.cond_broadcast(&catalog.refresher_cond)
	sync.mutex_unlock(&catalog.refresher_mutex)
	thread.join(catalog.refresher)
	thread.destroy(catalog.refresher)
	catalog.refresher = nil
}

@(private = "file")
bridge_catalog_refresher_entry :: proc(data: rawptr) {
	catalog := (^Bridge_Update_Catalog)(data)
	interval := catalog.refresh_interval if catalog.refresh_interval > 0 else BRIDGE_CATALOG_REFRESH_INTERVAL
	for {
		_, _ = bridge_catalog_refresh(catalog)
		free_all(context.temp_allocator)
		started := time.tick_now()
		sync.mutex_lock(&catalog.refresher_mutex)
		for !catalog.refresher_stop {
			left := interval - time.tick_since(started)
			if left <= 0 do break
			_ = sync.cond_wait_with_timeout(&catalog.refresher_cond, &catalog.refresher_mutex, left)
		}
		stopping := catalog.refresher_stop
		sync.mutex_unlock(&catalog.refresher_mutex)
		if stopping do return
	}
}
