package bridge

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import contracts "odin_test:contracts"
import httpc "odin_test:lib/httpc"
import domain "odin_test:hub/domain"

// Metadata is refreshed in the background. SHA256SUMS is fetched only for a
// selected candidate at POST time, avoiding one request per historical canary
// on every refresh. GET /bridges never performs network I/O.
Bridge_Catalog_Choice :: struct {
	tag: string,
	prerelease: bool,
	bundles: [len(BRIDGE_CATALOG_TARGETS)]bool,
}

bridge_catalog_fetch_choices :: proc(memo: ^Bridge_Catalog_Memo) -> ([]Bridge_Catalog_Choice, bool) {
	result := make([dynamic]Bridge_Catalog_Choice, context.temp_allocator)
	seen := make(map[string]bool, context.temp_allocator)
	stable := false
	// GitHub's release list is paginated. Never replace a complete snapshot
	// with a partial list after an error or the defensive page limit.
	for page in 1..=100 {
		query := []httpc.Query_Param{{"per_page", "30"}}
		if page > 1 do query = []httpc.Query_Param{{"per_page", "30"}, {"page", fmt.tprintf("%d", page)}}
		doc, ok, _ := bridge_catalog_memo_get(memo, bridge_catalog_request("https://api.github.com",
			{"repos", "tanmayv", "heimdall-agent-manager", "releases"}, query))
		if !ok do return nil, false
		releases: []Bridge_Catalog_Release
		if json.unmarshal_string(doc, &releases, allocator = context.temp_allocator) != nil do return nil, false
		for release in releases {
			if release.draft || !bridge_catalog_tag_valid(release.tag_name) || !contracts.release_version_valid(release.tag_name) do continue
			if seen[release.tag_name] do continue
			seen[release.tag_name] = true
			if !release.prerelease {
				if stable do continue
				stable = true
			}
			item := Bridge_Catalog_Choice{tag = release.tag_name, prerelease = release.prerelease}
			for target, i in BRIDGE_CATALOG_TARGETS {
				name := bridge_catalog_bundle(target, release.tag_name)
				bundle, sums := false, false
				for asset in release.assets {
					if asset.name == name do bundle = true
					if asset.name == "SHA256SUMS" do sums = true
				}
				item.bundles[i] = bundle && sums
			}
			append(&result, item)
		}
		if len(releases) < 30 do return result[:], true
	}
	return nil, false
}

bridge_catalog_choices_destroy :: proc(choices: []Bridge_Catalog_Choice) {
	context.allocator = runtime.default_allocator()
	for item in choices do delete(item.tag)
	delete(choices)
}

// Strings use context.temp_allocator. The flags, including downgrade, are
// recomputed from the bridge's current version, never trusted from the browser.
resolve_bridge_update_choices :: proc(catalog: ^Bridge_Update_Catalog, bridge: domain.Bridge) -> []contracts.Bridge_Update_Choice {
	result := make([dynamic]contracts.Bridge_Update_Choice, context.temp_allocator)
	target := normalize_bridge_target(bridge.machine_os, bridge.machine_arch)
	slot := bridge_catalog_slot(target, "")
	loaded := false
	if catalog != nil {
		sync.mutex_lock(&catalog.snapshot_mutex)
		loaded = catalog.choices_loaded
		if loaded && slot >= 0 {
			for item in catalog.choices {
				cmp := contracts.release_version_compare(item.tag, bridge.version)
				if item.prerelease && cmp <= 0 do continue
				append(&result, contracts.Bridge_Update_Choice{
					version = strings.clone(item.tag, context.temp_allocator),
					prerelease = item.prerelease, downgrade = cmp < 0, artifact_available = item.bundles[slot / 2],
				})
			}
		}
		sync.mutex_unlock(&catalog.snapshot_mutex)
	}
	if !loaded {
		info := resolve_bridge_update_info(catalog, bridge)
		if info.latest_version != "" {
			append(&result, contracts.Bridge_Update_Choice{
				version = info.latest_version,
				downgrade = contracts.release_version_compare(info.latest_version, bridge.version) < 0,
				artifact_available = info.artifact_available,
			})
		}
	}
	// Newest first, independent of publication order (older canaries can be
	// published again). The stable release remains available as a downgrade.
	for i in 1..<len(result) {
		j := i
		for j > 0 && contracts.release_version_compare(result[j].version, result[j-1].version) > 0 {
			result[j], result[j-1] = result[j-1], result[j]
			j -= 1
		}
	}
	return result[:]
}

resolve_bridge_selected_update :: proc(catalog: ^Bridge_Update_Catalog, bridge: domain.Bridge, version: string) -> (Bridge_Update_Info, bool) {
	current := resolve_bridge_update_info(catalog, bridge)
	if version == "" || version == "latest" do return current, true
	for choice in resolve_bridge_update_choices(catalog, bridge) {
		if strings.trim_prefix(choice.version, "v") != strings.trim_prefix(version, "v") do continue
		info := Bridge_Update_Info{latest_version = choice.version, target = current.target, latest_source = "promoted"}
		if !choice.artifact_available do return info, true
		if strings.trim_prefix(current.latest_version, "v") == strings.trim_prefix(version, "v") {
			current.latest_version = choice.version
			return current, true
		}
		if catalog == nil || catalog.release_get == nil do return info, true
		memo := Bridge_Catalog_Memo{get = catalog.release_get}
		name := bridge_catalog_bundle(info.target, choice.version)
		path := []string{"tanmayv", "heimdall-agent-manager", "releases", "download", choice.version, "SHA256SUMS"}
		sums, ok, reason := bridge_catalog_memo_get(&memo, bridge_catalog_request("https://github.com", path))
		if !ok { info.fallback_reason = reason; return info, true }
		info.sha256 = bridge_catalog_digest(sums, name)
		if info.sha256 == "" do return info, true
		path[len(path)-1] = name
		req := bridge_catalog_request("https://github.com", path)
		info.download_url, _ = httpc.build_url(req.url, req.path, allocator = context.temp_allocator)
		info.artifact_available = info.download_url != ""
		return info, true
	}
	return {}, false
}
