package main

// DP-1 / DP-5: persisted dev-user roster + active selection for ham-dev-proxy.
//
// The store lives at <data_dir>/dev-proxy/users.json where <data_dir> follows
// the codebase convention (mirror src/lib/tmux/tmux.odin): HEIMDALL_HOME env,
// else $XDG_DATA_HOME/heimdall, else $HOME/.local/share/heimdall.
//
// Shape:
//   {
//     "active": "<username>",
//     "users":  [ {"username":..., "display_name":..., "email":...}, ... ]
//   }
//
// On startup the persisted users are merged with the CLI/config seed users
// (additive; persisted users that shadow a seed username win), and the
// persisted `active` value is authoritative for the default fallback in
// select_dev_user (DP-5). An existing ham_dev_user cookie still wins per
// request — the persisted active is only the fallback.
//
// Writes are atomic (temp file + rename) to avoid a torn store on crash.
// The in-memory cache is guarded by a mutex; the only writers are the
// management API (tasks 2/3) and startup load, all on loopback for a single
// local user, so a simple sync.Mutex is sufficient.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"

// Dev_Proxy_Store is the in-memory cache + guard around the persisted
// dev-user roster. The Dev_Proxy_Config.users slice remains the source of
// truth for the request path (read under the mutex snapshot); this struct
// owns mutations and persistence.
Dev_Proxy_Store :: struct {
	config: ^Dev_Proxy_Config,
	mu: sync.Mutex,
	data_dir: string,
	store_path: string,
	active: string, // persisted active username ("" = fall back to config.default_user)
	loaded: bool,
}

// dev_proxy_store_init resolves the data dir, creates it, and loads any
// persisted roster into the config (merging seed users). It MUST be called
// after default_dev_proxy_config / parse_args and before serving requests.
// Returns the resolved data dir (for startup logging) and the store path.
dev_proxy_store_init :: proc(store: ^Dev_Proxy_Store, config: ^Dev_Proxy_Config) -> (string, string, bool) {
	store.config = config
	store.data_dir = resolve_dev_proxy_data_dir()
	store.store_path = fmt.tprintf("%s/dev-proxy/users.json", store.data_dir)

	// Best-effort create the <data_dir>/dev-proxy directory; failures here are
	// non-fatal (load/save will surface real errors), but we warn.
	_ = os.make_directory_all(fmt.tprintf("%s/dev-proxy", store.data_dir))

	loaded_active, ok := dev_proxy_store_load(store, config)
	store.loaded = ok
	// `active` is set inside dev_proxy_store_load on a successful read; on a
	// missing/corrupt store it stays "" so the existing default_user fallback
	// keeps working.
	if ok && loaded_active != "" {
		store.active = loaded_active
		config.default_user = strings.clone(loaded_active)
	}
	return store.data_dir, store.store_path, ok
}

// dev_proxy_store_load reads users.json (if present) and merges its users
// into config.users (additive; a persisted user with the same username as a
// seed user replaces the seed entry). Returns the persisted active username
// (or "" if unset/missing) and whether a valid store was loaded.
dev_proxy_store_load :: proc(store: ^Dev_Proxy_Store, config: ^Dev_Proxy_Config) -> (string, bool) {
	raw, err := os.read_entire_file(store.store_path, context.allocator)
	if err != nil {
		// Missing store is the normal first-run case; treat as empty.
		return "", false
	}
	value, parse_err := json.parse(raw)
	if parse_err != .None {
		fmt.eprintln("ham-dev-proxy: ignoring corrupt store", store.store_path, parse_err)
		return "", false
	}
	defer json.destroy_value(value)
	obj, is_obj := value.(json.Object)
	if !is_obj {
		fmt.eprintln("ham-dev-proxy: ignoring non-object store", store.store_path)
		return "", false
	}

	// Merge persisted users into the seed roster (additive; persisted wins on
	// username collision).
	seed := config.users
	merged := make([dynamic]Dev_User, 0, len(seed))
	for u in seed do append(&merged, u)
	users_val, has_users := obj["users"]
	if has_users {
		users_arr, is_arr := users_val.(json.Array)
		if is_arr {
			for u_val in users_arr {
				u_obj, ok := u_val.(json.Object)
				if !ok do continue
				u := dev_user_from_json(u_obj)
				if u.username == "" do continue // skip malformed entries
				replaced := false
				for i in 0..<len(merged) {
					if strings.equal_fold(merged[i].username, u.username) {
						merged[i] = u
						replaced = true
						break
					}
				}
				if !replaced do append(&merged, u)
			}
		}
	}
	config.users = merged[:]

	// Persisted active username. NOTE: clone before the deferred
	// json.destroy_value frees the parsed string data.
	active := ""
	active_val, has_active := obj["active"]
	if has_active {
		active_str, ok := active_val.(json.String)
		if ok do active = strings.clone(string(active_str))
	}
	return active, true
}

// dev_proxy_store_save writes the current roster + active selection
// atomically (temp + rename). Callers MUST hold no other config lock; the
// store mutex is taken here.
dev_proxy_store_save :: proc(store: ^Dev_Proxy_Store, users: []Dev_User, active: string) -> bool {
	sync.mutex_lock(&store.mu)
	defer sync.mutex_unlock(&store.mu)
	store.active = strings.clone(active)
	return dev_proxy_store_write_unlocked(store, users, active)
}

// dev_proxy_store_write_unlocked serializes and atomically writes the store.
// Caller MUST hold store.mu.
dev_proxy_store_write_unlocked :: proc(store: ^Dev_Proxy_Store, users: []Dev_User, active: string) -> bool {
	dir := fmt.tprintf("%s/dev-proxy", store.data_dir)
	_ = os.make_directory_all(dir)
	b := strings.builder_make()
	strings.write_string(&b, "{\n  \"active\": ")
	json_write_string(&b, active)
	strings.write_string(&b, ",\n  \"users\": [")
	first := true
	for u in users {
		if !first do strings.write_string(&b, ",")
		first = false
		strings.write_string(&b, "\n    {\"username\": ")
		json_write_string(&b, u.username)
		strings.write_string(&b, ", \"display_name\": ")
		json_write_string(&b, u.display_name)
		strings.write_string(&b, ", \"email\": ")
		json_write_string(&b, u.email)
		strings.write_string(&b, "}")
	}
	strings.write_string(&b, "\n  ]\n}\n")
	content := strings.to_string(b)
	tmp := fmt.tprintf("%s/users.json.tmp", dir)
	if os.write_entire_file(tmp, content) != nil {
		fmt.eprintln("ham-dev-proxy: failed to write temp store", tmp)
		return false
	}
	if os.rename(tmp, store.store_path) != nil {
		fmt.eprintln("ham-dev-proxy: failed to rename store", tmp, "->", store.store_path)
		_ = os.remove(tmp)
		return false
	}
	return true
}

// dev_proxy_store_active returns the persisted active username under the
// mutex. Empty means "no persisted active; use config.default_user".
dev_proxy_store_active :: proc(store: ^Dev_Proxy_Store) -> string {
	sync.mutex_lock(&store.mu)
	defer sync.mutex_unlock(&store.mu)
	return store.active
}

// dev_user_from_json extracts a Dev_User from a parsed JSON object, skipping
// any missing fields (username is the only required field).
dev_user_from_json :: proc(obj: json.Object) -> Dev_User {
	u: Dev_User
	if v, ok := obj["username"]; ok {
		if s, ok := v.(json.String); ok do u.username = strings.clone(string(s))
	}
	if v, ok := obj["display_name"]; ok {
		if s, ok := v.(json.String); ok do u.display_name = strings.clone(string(s))
	}
	if v, ok := obj["email"]; ok {
		if s, ok := v.(json.String); ok do u.email = strings.clone(string(s))
	}
	return u
}

// json_write_string writes a JSON-encoded string value into a builder,
// escaping the minimal set required for dev-user fields (control chars,
// quote, backslash). Matches the helper used by src/bridge/main.odin.
json_write_string :: proc(b: ^strings.Builder, value: string) {
	strings.write_string(b, "\"")
	for r in value {
		switch r {
		case '"': strings.write_string(b, "\\\"")
		case '\\': strings.write_string(b, "\\\\")
		case '\n': strings.write_string(b, "\\n")
		case '\r': strings.write_string(b, "\\r")
		case '\t': strings.write_string(b, "\\t")
		case:
			if r < 0x20 {
				strings.write_string(b, fmt.tprintf("\\u%04x", u32(r)))
			} else {
				strings.write_rune(b, r)
			}
		}
	}
	strings.write_string(b, "\"")
}

// resolve_dev_proxy_data_dir mirrors src/lib/tmux/tmux.odin's HEIMDALL_HOME
// convention, extended with the XDG_DATA_HOME step from DP-1: HEIMDALL_HOME
// env → $XDG_DATA_HOME/heimdall → $HOME/.local/share/heimdall → ".heimdall".
resolve_dev_proxy_data_dir :: proc() -> string {
	if home := os.get_env_alloc("HEIMDALL_HOME", context.allocator); home != "" {
		return home
	}
	if xdg := os.get_env_alloc("XDG_DATA_HOME", context.allocator); xdg != "" {
		return fmt.tprintf("%s/heimdall", xdg)
	}
	if home := os.get_env_alloc("HOME", context.allocator); home != "" {
		return fmt.tprintf("%s/.local/share/heimdall", home)
	}
	return ".heimdall"
}
