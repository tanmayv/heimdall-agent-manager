package main

// Provider profiles (REQ-PROF-1, 2, 4): bridge-local instances of a catalog provider.
//
// A profile names a catalog provider ("driver") and may override where and how it
// runs: binary, config_dir (the driver's config-dir variable), home_dir (HOME and the
// XDG dirs), env, and launch args appended after the catalog's model arguments.
// Every provider has an implicit default profile whose id is its slug and that has no
// overrides; it behaves exactly like the provider did before profiles existed.
//
// Storage: <data_dir>/bridge/provider_profiles.json (0600). The overrides of each
// profile ("secret") are AES-256-GCM encrypted under the bridge's persistent
// Profile_Key keystore slot (keystore_common.odin), with AAD binding them to this
// bridge and profile id. The hub knows only the metadata provider_profiles_report
// carries (ids, provider, the UI-encrypted label, accent, enabled, has/count flags).
//
// Threat note (Linux): the key is a 0600 file beside the store, so at-rest
// encryption protects copied, synced or backed-up stores and other OS users, not a
// process of the same user. macOS/Windows/Android keep the key in the OS keystore.

import "core:crypto"
import "core:crypto/aes"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"
import vault "odin_test:lib/vault"

PROFILE_ID_MAX :: 32
PROFILE_ENV_MAX :: 64
PROFILE_ENV_NAME_MAX :: 128
PROFILE_ENV_VALUE_MAX :: 8 * 1024
PROFILE_ARGS_MAX :: 32
PROFILE_ARG_MAX :: 1024
PROFILE_PATH_MAX :: 4096
PROFILE_LABEL_ENC_MAX :: 4096
PROFILE_STORE_MAX :: 256
PROFILE_STORE_VERSION :: 1
PROFILE_SECRET_AAD :: "heimdall-provider-profile-v1"
PROFILE_IV_BYTES :: 12
PROFILE_TAG_BYTES :: 16

Provider_Profile_Env :: struct {
	name:      string `json:"name"`,
	value:     string `json:"value"`,
	sensitive: bool `json:"sensitive"`,
}

// The encrypted part of a profile: everything the hub must never see.
Provider_Profile_Secret :: struct {
	binary:     string `json:"binary"`,
	config_dir: string `json:"config_dir"`,
	home_dir:   string `json:"home_dir"`,
	env:        []Provider_Profile_Env `json:"env"`,
	args:       []string `json:"args"`,
}

Provider_Profile :: struct {
	profile_id: string,
	provider:   string,
	label_enc:  string, // vault:v2 ciphertext made by the UI; the bridge never reads it
	accent:     string,
	enabled:    bool,
	created_at: i64,
	updated_at: i64,
	secret:     Provider_Profile_Secret,
}

// On-disk record: metadata in clear, secret sealed.
Provider_Profile_Record_Wire :: struct {
	profile_id: string `json:"profile_id"`,
	provider:   string `json:"provider"`,
	label_enc:  string `json:"label_enc"`,
	accent:     string `json:"accent"`,
	enabled:    bool `json:"enabled"`,
	created_at: i64 `json:"created_at"`,
	updated_at: i64 `json:"updated_at"`,
	sealed:     string `json:"sealed"`,
}

Provider_Profile_Store_Wire :: struct {
	version:  int `json:"version"`,
	profiles: []Provider_Profile_Record_Wire `json:"profiles"`,
}

// Typed refusal codes; they go to the hub and the UI verbatim.
Profile_Error :: enum {
	None,
	Invalid_Id,
	Reserved_Id,
	Unknown_Provider,
	Provider_Mismatch,
	Invalid_Accent,
	Invalid_Label,
	Path_Invalid,
	Binary_Invalid,
	Config_Dir_Unsupported,
	Env_Invalid,
	Env_Forbidden,
	Args_Invalid,
	Not_Found,
	Default_Not_Removable,
	Store_Full,
	Store_Unavailable,
	Unknown,
	Disabled,
}

profile_error_code :: proc(e: Profile_Error) -> string {
	switch e {
	case .None:                   return ""
	case .Invalid_Id:             return "profile_invalid_id"
	case .Reserved_Id:            return "profile_reserved_id"
	case .Unknown_Provider:       return "profile_unknown_provider"
	case .Provider_Mismatch:      return "profile_provider_mismatch"
	case .Invalid_Accent:         return "profile_invalid_accent"
	case .Invalid_Label:          return "profile_invalid_label"
	case .Path_Invalid:           return "profile_path_invalid"
	case .Binary_Invalid:         return "profile_binary_invalid"
	case .Config_Dir_Unsupported: return "profile_config_dir_unsupported"
	case .Env_Invalid:            return "profile_env_invalid"
	case .Env_Forbidden:          return "profile_env_forbidden"
	case .Args_Invalid:           return "profile_args_invalid"
	case .Not_Found:              return "profile_not_found"
	case .Default_Not_Removable:  return "profile_default_not_removable"
	case .Store_Full:             return "profile_store_full"
	case .Store_Unavailable:      return "profile_store_unavailable"
	case .Unknown:                return "profile_unknown"
	case .Disabled:               return "profile_disabled"
	}
	return "profile_error"
}

// ── Driver config-dir variables ─────────────────────────────────────────────

// profile_config_dir_var is the environment variable through which a driver takes
// its config directory; "" means the driver has none and config_dir is refused.
profile_config_dir_var :: proc(provider: string) -> string {
	switch provider {
	case "claude":      return "CLAUDE_CONFIG_DIR"
	case "codex":       return "CODEX_HOME"
	case "antigravity", "gemini": return "GEMINI_CONFIG_DIR"
	case "pi":          return "PI_CODING_AGENT_DIR"
	}
	return ""
}

// profile_config_dir_default is where the driver keeps its config under a HOME.
profile_config_dir_default :: proc(provider: string) -> string {
	switch provider {
	case "claude":      return ".claude"
	case "codex":       return ".codex"
	case "antigravity", "gemini": return ".gemini"
	case "pi":          return ".pi/agent"
	}
	return ""
}

// ── Validation ──────────────────────────────────────────────────────────────

profile_id_valid :: proc(id: string) -> bool {
	if len(id) < 1 || len(id) > PROFILE_ID_MAX do return false
	if !(id[0] >= 'a' && id[0] <= 'z') do return false
	for c in transmute([]u8)id {
		ok := (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-'
		if !ok do return false
	}
	return true
}

profile_env_name_valid :: proc(name: string) -> bool {
	if len(name) < 1 || len(name) > PROFILE_ENV_NAME_MAX do return false
	c0 := name[0]
	if !((c0 >= 'A' && c0 <= 'Z') || (c0 >= 'a' && c0 <= 'z') || c0 == '_') do return false
	for c in transmute([]u8)name {
		ok := (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_'
		if !ok do return false
	}
	return true
}

profile_accent_valid :: proc(accent: string) -> bool {
	if accent == "" do return true
	if len(accent) != 7 || accent[0] != '#' do return false
	for c in transmute([]u8)accent[1:] {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) do return false
	}
	return true
}

profile_has_nul :: proc(s: string) -> bool {
	return strings.index_byte(s, 0) >= 0
}

// profile_path_absolute checks an override path: absolute, bounded, no NUL, no
// "." / ".." components (it is used verbatim, never normalised through symlinks).
profile_path_absolute :: proc(p: string) -> bool {
	if p == "" || len(p) > PROFILE_PATH_MAX || profile_has_nul(p) do return false
	if !filepath.is_abs(p) do return false
	rest := p
	for part in strings.split_iterator(&rest, "/") {
		if part == "." || part == ".." do return false
	}
	return true
}

// profile_catalog_has is the catalog lookup used by validation; a test seam lets
// unit tests run without a cached catalog.
profile_catalog_has :: proc(provider: string) -> bool {
	when ODIN_TEST {
		if len(g_profile_test_catalog) > 0 do return slice.contains(g_profile_test_catalog, provider)
	}
	_, ok := bridge_provider_catalog_profile(provider)
	return ok
}

// Test seams (only read under ODIN_TEST; declared always so `odin check` of the
// test files type-checks).
g_profile_test_catalog: []string

// profile_validate_metadata checks id namespace and metadata (amendment 1 §2).
profile_validate_metadata :: proc(p: ^Provider_Profile) -> Profile_Error {
	if !profile_id_valid(p.profile_id) do return .Invalid_Id
	if !profile_catalog_has(p.provider) do return .Unknown_Provider
	// The default profile's id is its provider slug; no other profile may take any slug.
	if p.profile_id != p.provider && profile_catalog_has(p.profile_id) do return .Reserved_Id
	if !profile_accent_valid(p.accent) do return .Invalid_Accent
	if p.label_enc != "" && (len(p.label_enc) > PROFILE_LABEL_ENC_MAX || !vault.is_armored(p.label_enc)) do return .Invalid_Label
	return .None
}

// profile_validate_secret checks the overrides (amendment 2 §4, amendment 4 §3).
// Directory creation is separate (profile_prepare_dirs) so validation has no effects.
profile_validate_secret :: proc(provider: string, s: ^Provider_Profile_Secret) -> Profile_Error {
	if s.binary != "" {
		if !profile_path_absolute(s.binary) do return .Path_Invalid
		info, err := os.stat(s.binary, context.temp_allocator)
		if err != nil || info.type != .Regular || !bridge_os_is_executable(s.binary) do return .Binary_Invalid
	}
	if s.home_dir != "" && !profile_path_absolute(s.home_dir) do return .Path_Invalid
	config_var := profile_config_dir_var(provider)
	if s.config_dir != "" {
		if config_var == "" do return .Config_Dir_Unsupported
		if !profile_path_absolute(s.config_dir) do return .Path_Invalid
	}
	if len(s.env) > PROFILE_ENV_MAX do return .Env_Invalid
	seen := make(map[string]bool, context.temp_allocator)
	for e in s.env {
		if !profile_env_name_valid(e.name) || len(e.value) > PROFILE_ENV_VALUE_MAX || profile_has_nul(e.value) do return .Env_Invalid
		if seen[e.name] do return .Env_Invalid
		seen[e.name] = true
		if strings.has_prefix(e.name, "HEIMDALL_") do return .Env_Forbidden
		if s.home_dir != "" && (e.name == "HOME" || strings.has_prefix(e.name, "XDG_")) do return .Env_Forbidden
		if s.config_dir != "" && e.name == config_var do return .Env_Forbidden
	}
	if len(s.args) > PROFILE_ARGS_MAX do return .Args_Invalid
	for a in s.args {
		if len(a) == 0 || len(a) > PROFILE_ARG_MAX || profile_has_nul(a) do return .Args_Invalid
	}
	return .None
}

// profile_prepare_dirs creates a missing config_dir / home_dir leaf with mode 0700.
// Only the leaf: its parent must already exist and be writable (amendment 3 §3).
profile_prepare_dirs :: proc(s: ^Provider_Profile_Secret) -> Profile_Error {
	context.allocator = context.temp_allocator
	for dir in ([]string{s.home_dir, s.config_dir}) {
		if dir == "" do continue
		trimmed := strings.trim_right(dir, "/")
		if info, err := os.stat(trimmed, context.temp_allocator); err == nil {
			if info.type != .Directory do return .Path_Invalid
			continue
		}
		parent := filepath.dir(trimmed)
		pinfo, perr := os.stat(parent, context.temp_allocator)
		if perr != nil || pinfo.type != .Directory do return .Path_Invalid
		// A parent we cannot write to makes this fail, which is the refusal.
		if os.make_directory(trimmed, {.Read_User, .Write_User, .Execute_User}) != nil && !os.is_dir(trimmed) do return .Path_Invalid
	}
	return .None
}

// ── Child environment (amendment 1 §4) ──────────────────────────────────────

Profile_Env_Plan :: struct {
	set:   [dynamic][2]string,
	unset: [dynamic]string, // kept for callers that build a full env; launches only add
}

// profile_env_plan computes the profile's layer on top of the bridge env (which
// already carries an isolated local home when there is one): home_dir, then the
// driver config-dir variable, then the profile env. HEIMDALL_* is added later by
// the launcher and can never be set here (validation refuses it).
profile_env_plan :: proc(p: ^Provider_Profile, allocator := context.temp_allocator) -> Profile_Env_Plan {
	plan := Profile_Env_Plan{set = make([dynamic][2]string, allocator), unset = make([dynamic]string, allocator)}
	s := &p.secret
	if s.home_dir != "" {
		h := strings.trim_right(s.home_dir, "/")
		append(&plan.set, [2]string{"HOME", h})
		append(&plan.set, [2]string{"XDG_CONFIG_HOME", strings.concatenate({h, "/.config"}, allocator)})
		append(&plan.set, [2]string{"XDG_DATA_HOME", strings.concatenate({h, "/.local/share"}, allocator)})
		append(&plan.set, [2]string{"XDG_STATE_HOME", strings.concatenate({h, "/.local/state"}, allocator)})
		append(&plan.set, [2]string{"XDG_CACHE_HOME", strings.concatenate({h, "/.cache"}, allocator)})
		// A config-dir variable inherited from the bridge would point back out of
		// home_dir. The pty host can only add variables, so pin it inside home_dir.
		if v := profile_config_dir_var(p.provider); v != "" && s.config_dir == "" {
			append(&plan.set, [2]string{v, strings.concatenate({h, "/", profile_config_dir_default(p.provider)}, allocator)})
		}
	}
	if s.config_dir != "" {
		if v := profile_config_dir_var(p.provider); v != "" do append(&plan.set, [2]string{v, strings.trim_right(s.config_dir, "/")})
	}
	for e in s.env do append(&plan.set, [2]string{e.name, e.value})
	return plan
}

// profile_apply_env_plan returns base with the plan applied (later wins).
profile_apply_env_plan :: proc(base: []string, plan: Profile_Env_Plan, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	skip :: proc(entry: string, plan: Profile_Env_Plan) -> bool {
		eq := strings.index_byte(entry, '=')
		name := entry[:eq] if eq >= 0 else entry
		for u in plan.unset do if u == name do return true
		for kv in plan.set do if kv[0] == name do return true
		return false
	}
	for entry in base do if !skip(entry, plan) do append(&out, entry)
	for kv in plan.set do append(&out, strings.concatenate({kv[0], "=", kv[1]}, allocator))
	return out[:]
}

// ── At-rest sealing ─────────────────────────────────────────────────────────

profile_secret_aad :: proc(bridge_id, profile_id: string, allocator := context.temp_allocator) -> string {
	return strings.concatenate({PROFILE_SECRET_AAD, "|", bridge_id, "|", profile_id}, allocator)
}

profile_seal_secret :: proc(key: []byte, bridge_id, profile_id: string, s: ^Provider_Profile_Secret, allocator := context.temp_allocator) -> (sealed: string, ok: bool) {
	plain, merr := json.marshal(s^, allocator = context.temp_allocator)
	if merr != nil do return "", false
	defer mem.zero_explicit(raw_data(plain), len(plain))
	buf := make([]byte, PROFILE_IV_BYTES + len(plain) + PROFILE_TAG_BYTES, context.temp_allocator)
	iv := buf[:PROFILE_IV_BYTES]
	crypto.rand_bytes(iv)
	ct := buf[PROFILE_IV_BYTES:PROFILE_IV_BYTES + len(plain)]
	tag := buf[PROFILE_IV_BYTES + len(plain):]
	gcm: aes.Context_GCM
	aes.init_gcm(&gcm, key)
	defer aes.reset_gcm(&gcm)
	aad := profile_secret_aad(bridge_id, profile_id)
	aes.seal_gcm(&gcm, ct, tag, iv, transmute([]byte)aad, plain)
	enc, eerr := base64.encode(buf, allocator = allocator)
	if eerr != nil do return "", false
	return enc, true
}

profile_open_secret :: proc(key: []byte, bridge_id, profile_id, sealed: string, out: ^Provider_Profile_Secret, allocator := context.temp_allocator) -> bool {
	buf, derr := base64.decode(sealed, allocator = context.temp_allocator)
	if derr != nil || len(buf) < PROFILE_IV_BYTES + PROFILE_TAG_BYTES do return false
	iv := buf[:PROFILE_IV_BYTES]
	ct := buf[PROFILE_IV_BYTES:len(buf) - PROFILE_TAG_BYTES]
	tag := buf[len(buf) - PROFILE_TAG_BYTES:]
	plain := make([]byte, len(ct), context.temp_allocator)
	defer mem.zero_explicit(raw_data(plain), len(plain))
	gcm: aes.Context_GCM
	aes.init_gcm(&gcm, key)
	defer aes.reset_gcm(&gcm)
	aad := profile_secret_aad(bridge_id, profile_id)
	if !aes.open_gcm(&gcm, plain, iv, transmute([]byte)aad, ct, tag) do return false
	return json.unmarshal(plain, out, json.Specification.JSON, allocator) == nil
}

// ── Store ───────────────────────────────────────────────────────────────────

g_profile_store_mu: sync.Mutex

// Tests point the store somewhere private and skip the keystore.
g_profile_test_store_path: string
g_profile_test_key: [PROFILE_KEY_BYTES]byte
g_profile_test_key_set: bool

profile_store_path :: proc(allocator := context.temp_allocator) -> string {
	when ODIN_TEST {
		if g_profile_test_store_path != "" do return strings.clone(g_profile_test_store_path, allocator)
	}
	data_dir := strings.trim_space(bridge_config.data_dir)
	if data_dir == "" do data_dir = "~/.local/share/heimdall"
	expanded := bridge_expand_home(data_dir)
	defer if raw_data(expanded) != raw_data(data_dir) do delete(expanded)
	return strings.concatenate({strings.trim_right(expanded, "/"), "/bridge/provider_profiles.json"}, allocator)
}

profile_store_key :: proc() -> (key: [PROFILE_KEY_BYTES]byte, ok: bool) {
	when ODIN_TEST {
		if g_profile_test_key_set do return g_profile_test_key, true
	}
	return keystore_profile_key(bridge_config.daemon_id)
}

profile_bridge_id :: proc() -> string {
	return bridge_config.daemon_id
}

// Caller holds g_profile_store_mu. A missing file is an empty store.
profile_store_read_locked :: proc(allocator := context.temp_allocator) -> (records: []Provider_Profile_Record_Wire, ok: bool) {
	path := profile_store_path()
	if !os.exists(path) do return nil, true
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil do return nil, false
	wire: Provider_Profile_Store_Wire
	if json.unmarshal(data, &wire, json.Specification.JSON, allocator) != nil do return nil, false
	if wire.version != PROFILE_STORE_VERSION do return nil, false
	return wire.profiles, true
}

// Caller holds g_profile_store_mu. Atomic 0600 write (temp file + rename).
profile_store_write_locked :: proc(records: []Provider_Profile_Record_Wire) -> bool {
	context.allocator = context.temp_allocator
	path := profile_store_path()
	dir := filepath.dir(path)
	if err := bridge_make_directory_all(dir); err != nil && !os.is_dir(dir) do return false
	data, merr := json.marshal(Provider_Profile_Store_Wire{version = PROFILE_STORE_VERSION, profiles = records}, allocator = context.temp_allocator)
	if merr != nil do return false
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	_ = os.remove(tmp)
	f, oerr := os.open(tmp, {.Write, .Create, .Excl, .Trunc}, {.Read_User, .Write_User})
	if oerr != nil do return false
	n, werr := os.write(f, data)
	serr := os.sync(f)
	os.close(f)
	if werr != nil || n != len(data) || serr != nil {
		_ = os.remove(tmp)
		return false
	}
	if os.rename(tmp, path) != nil {
		_ = os.remove(tmp)
		return false
	}
	return true
}

profile_record_open :: proc(key: []byte, rec: Provider_Profile_Record_Wire, out: ^Provider_Profile, allocator := context.temp_allocator) -> bool {
	out^ = Provider_Profile{
		profile_id = rec.profile_id, provider = rec.provider, label_enc = rec.label_enc, accent = rec.accent,
		enabled = rec.enabled, created_at = rec.created_at, updated_at = rec.updated_at,
	}
	if rec.sealed == "" do return true
	return profile_open_secret(key, profile_bridge_id(), rec.profile_id, rec.sealed, &out.secret, allocator)
}

// profile_list returns every stored profile, decrypted, in temp memory.
profile_list :: proc(allocator := context.temp_allocator) -> (profiles: []Provider_Profile, err: Profile_Error) {
	sync.mutex_lock(&g_profile_store_mu)
	defer sync.mutex_unlock(&g_profile_store_mu)
	records, ok := profile_store_read_locked(allocator)
	if !ok do return nil, .Store_Unavailable
	if len(records) == 0 do return nil, .None
	key, kok := profile_store_key()
	if !kok do return nil, .Store_Unavailable
	defer crypto.zero_explicit(&key, size_of(key))
	out := make([dynamic]Provider_Profile, allocator)
	for rec in records {
		p: Provider_Profile
		if !profile_record_open(key[:], rec, &p, allocator) do return nil, .Store_Unavailable
		append(&out, p)
	}
	return out[:], .None
}

// profile_lookup resolves a profile id for a launch or probe of `provider`.
// "" or the provider slug with no stored record is the implicit default profile.
// A stored profile must be enabled and belong to `provider`. Never falls back.
profile_lookup :: proc(provider, profile_id: string, allocator := context.temp_allocator) -> (p: Provider_Profile, err: Profile_Error) {
	id := strings.trim_space(profile_id)
	if id == "" do id = provider
	profiles, lerr := profile_list(allocator)
	if lerr != .None do return {}, lerr
	for candidate in profiles {
		if candidate.profile_id != id do continue
		if candidate.provider != provider do return {}, .Provider_Mismatch
		if !candidate.enabled do return {}, .Disabled
		return candidate, .None
	}
	if id == provider do return Provider_Profile{profile_id = provider, provider = provider, enabled = true}, .None
	return {}, .Unknown
}

// profile_upsert stores p, keeping any sensitive env value marked keep in
// keep_names from the stored version. Validates everything before writing.
profile_upsert :: proc(p: ^Provider_Profile, keep_names: []string, now: i64) -> Profile_Error {
	if e := profile_validate_metadata(p); e != .None do return e
	sync.mutex_lock(&g_profile_store_mu)
	defer sync.mutex_unlock(&g_profile_store_mu)
	records, ok := profile_store_read_locked()
	if !ok do return .Store_Unavailable
	key, kok := profile_store_key()
	if !kok do return .Store_Unavailable
	defer crypto.zero_explicit(&key, size_of(key))
	idx := -1
	for rec, i in records do if rec.profile_id == p.profile_id do idx = i
	if idx >= 0 {
		existing: Provider_Profile
		if !profile_record_open(key[:], records[idx], &existing) do return .Store_Unavailable
		if existing.provider != p.provider do return .Provider_Mismatch
		// Redacted sensitive values: an entry the UI marks keep retains the stored value.
		for &e in p.secret.env {
			if !slice.contains(keep_names, e.name) do continue
			for old in existing.secret.env do if old.name == e.name && old.sensitive do e.value = old.value
		}
		p.created_at = records[idx].created_at
	} else {
		if len(records) >= PROFILE_STORE_MAX do return .Store_Full
		p.created_at = now
	}
	p.updated_at = now
	if e := profile_validate_secret(p.provider, &p.secret); e != .None do return e
	if e := profile_prepare_dirs(&p.secret); e != .None do return e
	sealed, sok := profile_seal_secret(key[:], profile_bridge_id(), p.profile_id, &p.secret)
	if !sok do return .Store_Unavailable
	rec := Provider_Profile_Record_Wire{
		profile_id = p.profile_id, provider = p.provider, label_enc = p.label_enc, accent = p.accent,
		enabled = p.enabled, created_at = p.created_at, updated_at = p.updated_at, sealed = sealed,
	}
	next := make([dynamic]Provider_Profile_Record_Wire, context.temp_allocator)
	append(&next, ..records)
	if idx >= 0 do next[idx] = rec
	else do append(&next, rec)
	return .None if profile_store_write_locked(next[:]) else .Store_Unavailable
}

// profile_remove deletes a custom profile. A default profile cannot be removed (it
// can only be reset). The hub refuses removal while agents reference the profile.
profile_remove :: proc(provider, profile_id: string) -> Profile_Error {
	if profile_id == provider do return .Default_Not_Removable
	sync.mutex_lock(&g_profile_store_mu)
	defer sync.mutex_unlock(&g_profile_store_mu)
	records, ok := profile_store_read_locked()
	if !ok do return .Store_Unavailable
	next := make([dynamic]Provider_Profile_Record_Wire, context.temp_allocator)
	found := false
	for rec in records {
		if rec.profile_id == profile_id {
			if rec.provider != provider do return .Provider_Mismatch
			found = true
			continue
		}
		append(&next, rec)
	}
	if !found do return .Not_Found
	return .None if profile_store_write_locked(next[:]) else .Store_Unavailable
}

// profile_reset drops a default profile's stored overrides, label and accent; the
// default then behaves as before profiles existed. enabled is kept by the hub's
// bridge_provider_settings row, which is independent of the stored record.
profile_reset :: proc(provider: string) -> Profile_Error {
	sync.mutex_lock(&g_profile_store_mu)
	defer sync.mutex_unlock(&g_profile_store_mu)
	records, ok := profile_store_read_locked()
	if !ok do return .Store_Unavailable
	next := make([dynamic]Provider_Profile_Record_Wire, context.temp_allocator)
	for rec in records do if rec.profile_id != provider do append(&next, rec)
	if len(next) == len(records) do return .None
	return .None if profile_store_write_locked(next[:]) else .Store_Unavailable
}

// profile_purge removes the store and its key (uninstall --purge, purge-home).
profile_purge :: proc(bridge_id: string) -> bool {
	sync.mutex_lock(&g_profile_store_mu)
	defer sync.mutex_unlock(&g_profile_store_mu)
	path := profile_store_path()
	file_ok := !os.exists(path) || os.remove(path) == nil
	return keystore_delete_profile_key(bridge_id) && file_ok
}

profile_now_ms :: proc() -> i64 {
	return time.time_to_unix_nano(time.now()) / 1_000_000
}

// ── Metadata report (amendment 2 §3) ────────────────────────────────────────

Provider_Profile_Report_Entry :: struct {
	profile_id:     string `json:"profile_id"`,
	provider:       string `json:"provider"`,
	label_enc:      string `json:"label_enc"`,
	accent:         string `json:"accent"`,
	enabled:        bool `json:"enabled"`,
	has_config_dir: bool `json:"has_config_dir"`,
	has_home_dir:   bool `json:"has_home_dir"`,
	has_binary:     bool `json:"has_binary"`,
	env_count:      int `json:"env_count"`,
	args_count:     int `json:"args_count"`,
	state:          string `json:"state"`,
	created_at:     i64 `json:"created_at"`,
	updated_at:     i64 `json:"updated_at"`,
}

Provider_Profiles_Report_Wire :: struct {
	type:     string `json:"type"`,
	ok:       bool `json:"ok"`,
	error:    string `json:"error"`,
	profiles: []Provider_Profile_Report_Entry `json:"profiles"`,
}

// profile_report_json is the provider_profiles_report frame: metadata only, never a
// value, path, env name or argument. state is "slug_clash" when a later catalog
// added a provider whose slug equals this custom profile's id.
profile_report_json :: proc(allocator := context.allocator) -> string {
	profiles, err := profile_list()
	entries := make([dynamic]Provider_Profile_Report_Entry, context.temp_allocator)
	for &p in profiles {
		state := "ok"
		if p.profile_id != p.provider && profile_catalog_has(p.profile_id) do state = "slug_clash"
		append(&entries, Provider_Profile_Report_Entry{
			profile_id = p.profile_id, provider = p.provider, label_enc = p.label_enc, accent = p.accent,
			enabled = p.enabled, has_config_dir = p.secret.config_dir != "", has_home_dir = p.secret.home_dir != "",
			has_binary = p.secret.binary != "", env_count = len(p.secret.env), args_count = len(p.secret.args),
			state = state, created_at = p.created_at, updated_at = p.updated_at,
		})
	}
	wire := Provider_Profiles_Report_Wire{type = "provider_profiles_report", ok = err == .None, error = profile_error_code(err), profiles = entries[:]}
	data, merr := json.marshal(wire, allocator = allocator)
	if merr != nil do return strings.clone(`{"type":"provider_profiles_report","ok":false,"error":"profile_store_unavailable","profiles":[]}`, allocator)
	return string(data)
}

_ :: fmt
