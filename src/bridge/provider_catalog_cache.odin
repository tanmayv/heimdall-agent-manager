package main

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import cfg_lib "odin_test:lib/config"
import contracts "odin_test:contracts"
import ws "odin_test:lib/ws"

Bridge_Catalog_Model :: struct {
	model_id: string `json:"model_id"`,
	label:    string `json:"label"`,
	state:    string `json:"state"`,
}

Bridge_ACP_Recipe :: contracts.ACP_Recipe

Bridge_Catalog_Provider :: struct {
	transports: []string `json:"transports"`,
	default_transport: string `json:"default_transport"`,
	acp_recipe: Bridge_ACP_Recipe `json:"acp_recipe"`,
	provider:           string `json:"provider"`,
	display_name:       string `json:"display_name"`,
	icon_url:           string `json:"icon_url"`,
	binary:             string `json:"binary"`,
	base_args:          []string `json:"base_args"`,
	yolo_args:          []string `json:"yolo_args"`,
	// Appended instead of yolo_args for permission_mode 'ask'; absent from a Hub
	// that predates it (nil, so ask mode just omits the yolo flags).
	ask_args:           []string `json:"ask_args"`,
	model_flag:         string `json:"model_flag"`,
	prompt_args:        []string `json:"prompt_args"`,
	prompt_delivery:    string `json:"prompt_delivery"`,
	starter_prompt:     string `json:"starter_prompt"`,
	bootstrap_file:     string `json:"bootstrap_file"`,
	skill_dir:           string `json:"skill_dir"`,
	startup_detection:  cfg_lib.Startup_Detection_Config `json:"startup_detection"`,
	activity_detection: cfg_lib.Activity_Detection_Config `json:"activity_detection"`,
	// Zero value (catalog `null` or a Hub that predates it) means unsupported.
	extension:          Bridge_Catalog_Extension `json:"extension"`,
	state:               string `json:"state"`,
	models:              []Bridge_Catalog_Model `json:"models"`,
}

Bridge_Provider_Catalog_Wire :: struct {
	providers: []Bridge_Catalog_Provider `json:"providers"`,
}

Bridge_Provider_Catalog_Snapshot :: struct {
	etag:         string,
	catalog_json: string,
	providers:    []Bridge_Catalog_Provider,
}

bridge_provider_catalog_mutex: sync.RW_Mutex
bridge_provider_catalog_loaded: bool
bridge_provider_catalog_snapshot: ^Bridge_Provider_Catalog_Snapshot

bridge_provider_catalog_path :: proc() -> string {
	data_dir := strings.trim_space(bridge_config.data_dir)
	if data_dir == "" do data_dir = "~/.local/share/heimdall"
	expanded := bridge_expand_home(data_dir)
	defer if raw_data(expanded) != raw_data(data_dir) do delete(expanded)
	return strings.concatenate({strings.trim_right(expanded, "/"), "/bridge/provider_catalog.json"})
}

// bridge_provider_catalog_name_supported accepts any well-formed provider slug
// (lowercase letters, digits, and inner dashes, at most 32 bytes). The Hub's
// catalog is the source of truth for which providers exist, so adding one needs
// no Bridge release. Bridges up to v0.3.39 hard-coded exactly four names and
// reject a catalog that adds a provider, keeping their cached copy instead.
bridge_provider_catalog_name_supported :: proc(name: string) -> bool {
	if len(name) == 0 || len(name) > 32 do return false
	if name[0] == '-' || name[len(name) - 1] == '-' do return false
	for c in transmute([]u8)name {
		if !((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-') do return false
	}
	return true
}

bridge_provider_catalog_valid :: proc(catalog: Bridge_Provider_Catalog_Wire) -> bool {
	if len(catalog.providers) == 0 do return false
	for provider, i in catalog.providers {
		if !bridge_catalog_transport_valid(provider) do return false
		if !bridge_provider_catalog_name_supported(provider.provider) do return false
		if strings.trim_space(provider.display_name) == "" || strings.trim_space(provider.binary) == "" do return false
		if provider.state != "active" && provider.state != "deprecated" do return false
		if len(provider.models) == 0 do return false
		for previous in 0..<i {
			if catalog.providers[previous].provider == provider.provider do return false
		}
		for model, model_index in provider.models {
			if strings.trim_space(model.model_id) == "" || strings.trim_space(model.label) == "" do return false
			if model.state != "active" && model.state != "deprecated" do return false
			for previous_model in 0..<model_index {
				if provider.models[previous_model].model_id == model.model_id do return false
			}
		}
	}
	return true
}

bridge_provider_catalog_build_snapshot :: proc(etag, catalog_json: string) -> (^Bridge_Provider_Catalog_Snapshot, bool) {
	if !strings.has_prefix(etag, "sha256:") || !bootstrap_cache_verify_hash(catalog_json, etag) do return nil, false
	if !bridge_catalog_transport_shape_valid(catalog_json) do return nil,false
	wire: Bridge_Provider_Catalog_Wire
	if err := json.unmarshal_string(catalog_json, &wire, json.DEFAULT_SPECIFICATION, context.temp_allocator); err != nil do return nil, false
	if !bridge_provider_catalog_valid(wire) do return nil, false
	// Validate in scratch memory, then copy every nested array/map into the
	// immutable process-lifetime snapshot. Rejected updates retain no allocations.
	wire = {}
	if err:=json.unmarshal_string(catalog_json,&wire,json.DEFAULT_SPECIFICATION,runtime.default_allocator());err!=nil do return nil,false
	for &provider in wire.providers {
		if len(provider.transports)==0 {
			provider.transports=make([]string,1,runtime.default_allocator())
			provider.transports[0]=strings.clone("pty",runtime.default_allocator())
			provider.default_transport=strings.clone("pty",runtime.default_allocator())
		}
	}
	// This runs on the Hub WebSocket reader thread. Never replace that thread's
	// context allocator: values allocated before this call have deferred frees
	// that must continue using the allocator which created them. The immutable
	// process-lifetime snapshot alone is explicitly allocated from the runtime
	// allocator.
	snapshot := new(Bridge_Provider_Catalog_Snapshot, runtime.default_allocator())
	snapshot.etag = strings.clone(etag, runtime.default_allocator())
	snapshot.catalog_json = strings.clone(catalog_json, runtime.default_allocator())
	snapshot.providers = wire.providers
	return snapshot, true
}

bridge_provider_catalog_publish :: proc(snapshot: ^Bridge_Provider_Catalog_Snapshot) {
	if snapshot == nil do return
	sync.rw_mutex_lock(&bridge_provider_catalog_mutex)
	// Published snapshots are immutable and intentionally retained for the process
	// lifetime. A launch may still hold owned argv derived under the read lock; with
	// four providers and rare catalog edits, retaining a few KB avoids the same
	// replace-vs-reader use-after-free class documented in AGENTS.md.
	bridge_provider_catalog_snapshot = snapshot
	sync.rw_mutex_unlock(&bridge_provider_catalog_mutex)
	// Wake discovery requests parked in bridge_provider_catalog_wait_ready. The
	// broadcast is taken under the ready mutex (never while holding the catalog
	// lock), so a waiter that just saw an empty catalog cannot miss it.
	sync.mutex_lock(&bridge_provider_catalog_ready_mutex)
	sync.cond_broadcast(&bridge_provider_catalog_ready_cond)
	sync.mutex_unlock(&bridge_provider_catalog_ready_mutex)
}

// ---- catalog readiness for provider discovery ------------------------------
//
// A freshly installed bridge has no cached catalog: it asks the Hub for one only
// after its runtime is ready, so for a short window the Hub can route a
// provider_discover to a bridge that has nothing to probe. Answering that with an
// empty report records every CLI as absent. Discovery therefore waits a bounded
// time for the catalog, and otherwise refuses with a retriable typed error and
// re-requests the catalog in case the first request or its reply was lost.

bridge_provider_catalog_ready_mutex: sync.Mutex
bridge_provider_catalog_ready_cond: sync.Cond

// Longest a discovery request parks waiting for the catalog. Kept short so the
// probes that follow still finish inside the Hub's 10s wait.
BRIDGE_PROVIDER_CATALOG_READY_WAIT :: 2 * time.Second
// Minimum spacing between recovery catalog requests sent from discovery.
BRIDGE_PROVIDER_CATALOG_RECOVERY_INTERVAL :: 5 * time.Second
BRIDGE_PROVIDER_CATALOG_NOT_READY_CAUSE :: "provider_catalog_not_ready"
// Hint for callers that retry a not-ready refusal.
BRIDGE_PROVIDER_CATALOG_RETRY_AFTER_MS :: 2000

bridge_provider_catalog_recovery_mutex: sync.Mutex
bridge_provider_catalog_recovery_last: time.Time

// bridge_provider_catalog_wait_ready reports whether a catalog is loaded, waiting
// until `deadline` at most. A zero deadline only checks.
bridge_provider_catalog_wait_ready :: proc(deadline: time.Time) -> bool {
	for {
		if bridge_provider_catalog_provider_count() > 0 do return true
		remaining := time.diff(time.now(), deadline)
		if deadline == {} || remaining <= 0 do return false
		sync.mutex_lock(&bridge_provider_catalog_ready_mutex)
		// Re-check under the ready mutex: publish broadcasts under it, so the
		// catalog either is visible here or its broadcast is still to come.
		if bridge_provider_catalog_provider_count() > 0 {
			sync.mutex_unlock(&bridge_provider_catalog_ready_mutex)
			return true
		}
		_ = sync.cond_wait_with_timeout(&bridge_provider_catalog_ready_cond, &bridge_provider_catalog_ready_mutex, remaining)
		sync.mutex_unlock(&bridge_provider_catalog_ready_mutex)
	}
}

// bridge_provider_catalog_recovery_due rate-limits recovery catalog requests; it
// claims the slot when it returns true.
bridge_provider_catalog_recovery_due :: proc(now: time.Time) -> bool {
	sync.mutex_lock(&bridge_provider_catalog_recovery_mutex)
	defer sync.mutex_unlock(&bridge_provider_catalog_recovery_mutex)
	last := bridge_provider_catalog_recovery_last
	if last != {} && time.diff(last, now) < BRIDGE_PROVIDER_CATALOG_RECOVERY_INTERVAL do return false
	bridge_provider_catalog_recovery_last = now
	return true
}

bridge_provider_catalog_save :: proc(etag, catalog_json: string) -> bool {
	path := bridge_provider_catalog_path()
	defer delete(path)
	if slash := strings.last_index_byte(path, '/'); slash > 0 {
		if mk_err := bridge_make_directory_all(path[:slash]); mk_err != nil && !os.exists(path[:slash]) {
			fmt.eprintfln("bridge provider catalog: cannot create cache directory %s: %v", path[:slash], mk_err)
			return false
		}
	}
	b := strings.builder_make()
	strings.write_string(&b, "{\"catalog_etag\":\"")
	bridge_runtime_write_json_string(&b, etag)
	strings.write_string(&b, "\",\"catalog_json\":\"")
	bridge_runtime_write_json_string(&b, catalog_json)
	strings.write_string(&b, "\"}\n")
	payload := strings.to_string(b)
	defer delete(payload)
	tmp := strings.concatenate({path, ".tmp"})
	defer delete(tmp)
	if w_err := os.write_entire_file(tmp, transmute([]byte)payload); w_err != nil {
		fmt.eprintfln("bridge provider catalog: cannot write cache %s: %v", tmp, w_err)
		return false
	}
	if rn_err := os.rename(tmp, path); rn_err != nil {
		fmt.eprintfln("bridge provider catalog: cannot rename cache %s -> %s: %v", tmp, path, rn_err)
		_ = os.remove(tmp)
		return false
	}
	return true
}

bridge_provider_catalog_apply :: proc(etag, catalog_json: string) -> bool {
	snapshot, ok := bridge_provider_catalog_build_snapshot(etag, catalog_json)
	if !ok do return false
	// The Hub is the source of truth and the file is only a restart cache: a failed
	// cache write must not leave this process without a catalog, or provider
	// discovery would refuse until the next restart. bridge_provider_catalog_save
	// already logged why it failed.
	if !bridge_provider_catalog_save(etag, catalog_json) do fmt.println("bridge provider catalog: applied in memory only; the restart cache was not updated")
	bridge_provider_catalog_publish_and_probe(snapshot)
	return true
}

bridge_provider_catalog_publish_and_probe :: proc(snapshot: ^Bridge_Provider_Catalog_Snapshot) {
	had_providers := bridge_provider_catalog_provider_count() > 0
	bridge_provider_catalog_publish(snapshot)
	// A fresh bridge starts with no catalog, so startup probing finds nothing
	// ("catalog=0 present=0"). The first sync that brings providers in must probe
	// them, or the bridge only sees installed CLIs after a restart.
	if !had_providers && snapshot != nil && len(snapshot.providers) > 0 do bridge_provider_reprobe_hook()
}

bridge_provider_catalog_provider_count :: proc() -> int {
	bridge_provider_catalog_init()
	sync.rw_mutex_shared_lock(&bridge_provider_catalog_mutex)
	defer sync.rw_mutex_shared_unlock(&bridge_provider_catalog_mutex)
	if bridge_provider_catalog_snapshot == nil do return 0
	return len(bridge_provider_catalog_snapshot.providers)
}

// Test seam: replaced by a counter in tests so no thread or real PATH probe runs.
bridge_provider_reprobe_hook: proc() = bridge_provider_reprobe_async

bridge_provider_reprobe_async :: proc() {
	// Tests that apply catalogs must not probe the host PATH or write the real store.
	when ODIN_TEST do return
	thread.run(proc() {
		results := bridge_provider_discover(nil)
		for &result in results do bridge_provider_path_destroy(&result)
		delete(results)
		free_all(context.temp_allocator)
	})
}

bridge_provider_catalog_init :: proc() {
	sync.rw_mutex_lock(&bridge_provider_catalog_mutex)
	if bridge_provider_catalog_loaded {
		sync.rw_mutex_unlock(&bridge_provider_catalog_mutex)
		return
	}
	bridge_provider_catalog_loaded = true
	sync.rw_mutex_unlock(&bridge_provider_catalog_mutex)

	path := bridge_provider_catalog_path()
	defer delete(path)
	raw, err := os.read_entire_file(path, context.allocator)
	if err != nil do return
	defer delete(raw)
	body := string(raw)
	etag := extract_json_string(body, "catalog_etag", "")
	defer delete(etag)
	catalog_json := extract_json_string(body, "catalog_json", "")
	defer delete(catalog_json)
	snapshot, ok := bridge_provider_catalog_build_snapshot(etag, catalog_json)
	if ok do bridge_provider_catalog_publish(snapshot)
}

bridge_provider_catalog_current_etag :: proc() -> string {
	bridge_provider_catalog_init()
	sync.rw_mutex_shared_lock(&bridge_provider_catalog_mutex)
	defer sync.rw_mutex_shared_unlock(&bridge_provider_catalog_mutex)
	if bridge_provider_catalog_snapshot == nil do return ""
	return strings.clone(bridge_provider_catalog_snapshot.etag)
}

// Returns a catalog-backed profile whose strings remain valid for the process
// lifetime. Published catalog snapshots are immutable and intentionally retained.
// There is no default-provider fallback: callers must name an active provider.
bridge_provider_catalog_profile :: proc(name: string) -> (Bridge_Provider_Profile, bool) {
	if strings.trim_space(name) == "" do return {}, false
	bridge_provider_catalog_init()
	sync.rw_mutex_shared_lock(&bridge_provider_catalog_mutex)
	defer sync.rw_mutex_shared_unlock(&bridge_provider_catalog_mutex)
	if bridge_provider_catalog_snapshot == nil do return {}, false
	for provider in bridge_provider_catalog_snapshot.providers {
		if provider.provider != name || provider.state != "active" do continue
		return bridge_provider_profile_from_catalog(provider), true
	}
	return {}, false
}

// The catalog's executable name for an active provider; the string is cloned.
bridge_provider_catalog_binary :: proc(name: string, allocator := context.temp_allocator) -> (string, bool) {
	if strings.trim_space(name) == "" do return "", false
	bridge_provider_catalog_init()
	sync.rw_mutex_shared_lock(&bridge_provider_catalog_mutex)
	defer sync.rw_mutex_shared_unlock(&bridge_provider_catalog_mutex)
	if bridge_provider_catalog_snapshot == nil do return "", false
	for provider in bridge_provider_catalog_snapshot.providers {
		if provider.provider != name || provider.state != "active" || provider.binary == "" do continue
		return strings.clone(provider.binary, allocator), true
	}
	return "", false
}

// Projects one catalog entry onto the launch profile. The result aliases the
// entry's strings, so it lives as long as the snapshot that owns the entry.
bridge_provider_profile_from_catalog :: proc(provider: Bridge_Catalog_Provider) -> Bridge_Provider_Profile {
	return Bridge_Provider_Profile{
		name = provider.provider,
		base_args = provider.base_args,
		yolo_flags = provider.yolo_args,
		ask_flags = provider.ask_args,
		prompt_flags = provider.prompt_args,
		starter_prompt = provider.starter_prompt,
		extension = provider.extension,
		prompt_delivery = provider.prompt_delivery,
		skill_dir = provider.skill_dir,
		bootstrap_file_name = provider.bootstrap_file,
		model_flag = provider.model_flag,
		startup_detection = provider.startup_detection,
		activity_detection = provider.activity_detection,
	}
}

bridge_provider_catalog_has_model :: proc(provider_name, model_id: string) -> bool {
	if strings.trim_space(provider_name) == "" || strings.trim_space(model_id) == "" do return false
	observed := bridge_models_get(provider_name)
	defer bridge_models_destroy(&observed)
	if observed.has_snapshot {
		if _, active := bridge_provider_catalog_profile(provider_name); !active do return false
		for model in observed.models do if model.model_id==model_id do return true
		return false
	}
	bridge_provider_catalog_init()
	sync.rw_mutex_shared_lock(&bridge_provider_catalog_mutex)
	defer sync.rw_mutex_shared_unlock(&bridge_provider_catalog_mutex)
	if bridge_provider_catalog_snapshot == nil do return false
	for provider in bridge_provider_catalog_snapshot.providers {
		if provider.provider != provider_name || provider.state != "active" do continue
		for model in provider.models {
			if model.model_id == model_id && model.state == "active" do return true
		}
	}
	return false
}

bridge_provider_catalog_needs_sync :: proc(hub_etag: string) -> bool {
	if strings.trim_space(hub_etag) == "" do return false
	current := bridge_provider_catalog_current_etag()
	defer delete(current)
	return !strings.equal_fold(current, hub_etag)
}

bridge_provider_catalog_request_json :: proc() -> string {
	current := bridge_provider_catalog_current_etag()
	defer delete(current)
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"provider_catalog_request\",\"cached_etag\":\"")
	bridge_runtime_write_json_string(&b, current)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

bridge_provider_catalog_handle_frame :: proc(conn: ^ws.Connection, frame_type, text: string) -> bool {
	if frame_type == "provider_catalog_version" {
		hub_etag := extract_json_string(text, "catalog_etag", "")
		defer delete(hub_etag)
		if bridge_provider_catalog_needs_sync(hub_etag) {
			request := bridge_provider_catalog_request_json()
			defer delete(request)
			_ = bridge_hub_send(conn, request)
		}
		// The hub sends its catalog version on every connect: report profiles then.
		bridge_send_provider_profiles_report(conn)
		return true
	}
	if frame_type != "provider_catalog" do return false
	etag := extract_json_string(text, "catalog_etag", "")
	defer delete(etag)
	catalog_json := extract_json_string(text, "catalog_json", "")
	defer delete(catalog_json)
	if !bridge_provider_catalog_apply(etag, catalog_json) {
		// bridge_provider_catalog_save prints its own reason when the cache write
		// is what failed; a silent false here means the body itself was bad.
		fmt.println("bridge provider catalog rejected: malformed body or sha256 mismatch")
	} else {
		// A new catalog can turn a custom profile id into a slug clash.
		bridge_send_provider_profiles_report(conn)
	}
	return true
}

bridge_catalog_transport_valid :: proc(provider: Bridge_Catalog_Provider) -> bool {
 if len(provider.transports)==0 do return provider.default_transport=="" && provider.acp_recipe.command==""
 if len(provider.transports)>2 || !contracts.runtime_transport_valid(provider.default_transport) do return false
 found:=false
 has_acp:=false
 for name,i in provider.transports {
  if !contracts.runtime_transport_valid(name) do return false
  for previous in provider.transports[:i] do if previous==name do return false
  if name==provider.default_transport do found=true
  if name=="acp" do has_acp=true
 }
 if !found do return false
 if has_acp {
  encoded,err:=json.marshal(provider.acp_recipe,allocator=context.temp_allocator)
  if err!=nil || !contracts.acp_recipe_valid(string(encoded)) do return false
 }
 return true
}

bridge_catalog_transport_shape_valid :: proc(raw:string)->bool {
 value,err:=json.parse(raw, parse_integers=true)
 if err!=nil do return false
 defer json.destroy_value(value)
 obj,ok:=value.(json.Object)
 if !ok do return false
 providers,valid:=obj["providers"].(json.Array)
 if !valid do return false
 for provider in providers {
  row,rok:=provider.(json.Object)
  if !rok do return false
  if item,present:=row["transports"];present {
   list,lok:=item.(json.Array)
   if !lok || len(list)<1 || len(list)>2 do return false
   for transport in list {
    if name,ok:=transport.(json.String); ok && name=="acp" {
     if !contracts.acp_recipe_value_valid(row["acp_recipe"]) do return false
    }
   }
  }
 }
 return true
}
