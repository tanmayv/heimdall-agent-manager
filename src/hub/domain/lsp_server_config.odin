package domain

Lsp_Server_Config :: struct {
	config_id:       string,
	owner_user_id:   string,
	bridge_id:       string,
	language:        string,
	cmd:             string,
	args:            string,
	file_extensions: string,
	root_markers:    string,
	// dir_prefix is empty for a language-wide default; otherwise a path prefix
	// with no trailing slash (e.g. "/home/user/project"). A row with a non-empty
	// dir_prefix overrides the default for files under that directory.
	dir_prefix:      string,
	created_at:      string,
	updated_at:      string,
}

// lsp_server_config_resolve picks the best config for file_path from a slice
// that is already filtered to the relevant (bridge, language) pair.
//
// Resolution rule: the config whose dir_prefix is the LONGEST valid path-prefix
// of file_path wins. A dir_prefix is a valid path-prefix when:
//   - dir_prefix == "" (language default — matches everything, lowest priority), OR
//   - strings.has_prefix(file_path, dir_prefix) AND the next character in
//     file_path is '/' or file_path ends exactly at dir_prefix (so "/work/exp"
//     matches "/work/exp/main.go" but NOT "/work/experiment/main.go").
//
// Returns (config, true) on a match, ({}, false) when no config matches at all.
lsp_server_config_resolve :: proc(configs: []Lsp_Server_Config, file_path: string) -> (Lsp_Server_Config, bool) {
	best_idx    := -1
	best_len    := -1 // -1 = no candidate yet; 0 = default found; >0 = prefix length

	for cfg, i in configs {
		prefix := cfg.dir_prefix
		if prefix == "" {
			// Language default: matches any path but loses to any specific prefix.
			if best_len < 0 {
				best_idx = i
				best_len = 0
			}
			continue
		}
		// Specific prefix: must match with a path boundary.
		if len(file_path) < len(prefix) do continue
		if file_path[:len(prefix)] != prefix do continue
		// Path-boundary check: after the prefix the path must end or continue with '/'.
		if len(file_path) > len(prefix) && file_path[len(prefix)] != '/' do continue
		// Longer prefix wins.
		if len(prefix) > best_len {
			best_idx = i
			best_len = len(prefix)
		}
	}

	if best_idx < 0 do return Lsp_Server_Config{}, false
	return configs[best_idx], true
}

lsp_server_config_destroy :: proc(c: Lsp_Server_Config) {
	delete(c.config_id)
	delete(c.owner_user_id)
	delete(c.bridge_id)
	delete(c.language)
	delete(c.cmd)
	delete(c.args)
	delete(c.file_extensions)
	delete(c.root_markers)
	delete(c.dir_prefix)
	delete(c.created_at)
	delete(c.updated_at)
}

lsp_server_configs_destroy :: proc(configs: [dynamic]Lsp_Server_Config) {
	for c in configs do lsp_server_config_destroy(c)
	delete(configs)
}
