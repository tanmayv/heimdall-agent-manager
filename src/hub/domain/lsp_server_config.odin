package domain

import "core:strings"

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
	// dir_pattern is empty for non-pattern configs; otherwise a glob pattern
	// supporting '*' (non-slash characters) and '**' (recursive across slashes),
	// e.g. "/google/src/cloud/*/*/google3/**".
	dir_pattern:     string,
	created_at:      string,
	updated_at:      string,
}

// lsp_path_glob_match matches a path against a glob pattern supporting:
// '*' matches zero or more non-slash characters.
// '**' matches zero or more characters across slashes.
lsp_path_glob_match :: proc(pattern, text: string) -> bool {
	if pattern == "" do return false
	if pattern == "**" do return true
	if glob_match_inner(pattern, text, 0, 0) do return true
	if strings.has_suffix(pattern, "/**") {
		base := pattern[:len(pattern)-3]
		if glob_match_inner(base, text, 0, 0) do return true
	}
	return false
}

@(private)
glob_match_inner :: proc(pat, str: string, pi, si: int) -> bool {
	p := pi
	s := si
	for p < len(pat) {
		if p + 1 < len(pat) && pat[p] == '*' && pat[p+1] == '*' {
			p += 2
			for p < len(pat) && pat[p] == '*' {
				p += 1
			}
			if p == len(pat) {
				return true
			}
			if pat[p] == '/' {
				if glob_match_inner(pat, str, p + 1, s) {
					return true
				}
			}
			for i := s; i <= len(str); i += 1 {
				if glob_match_inner(pat, str, p, i) {
					return true
				}
			}
			return false
		} else if pat[p] == '*' {
			p += 1
			for p < len(pat) && pat[p] == '*' {
				p += 1
			}
			for i := s; i <= len(str); i += 1 {
				if glob_match_inner(pat, str, p, i) {
					return true
				}
				if i < len(str) && str[i] == '/' {
					break
				}
			}
			return false
		} else {
			if s >= len(str) do return false
			if pat[p] != str[s] do return false
			p += 1
			s += 1
		}
	}
	return s == len(str)
}

// lsp_server_config_matches_language_or_ext reports whether cfg matches the requested
// language and/or the file extension of file_path.
//
// Rules:
// - Returns true if cfg.language == "*" OR language is in comma-separated list of
//   cfg.language (case-insensitive, trimmed).
// - Returns true if file extension of file_path (e.g. ".go", ".ts") is in comma-separated
//   list of cfg.file_extensions (case-insensitive, trimmed).
lsp_server_config_matches_language_or_ext :: proc(cfg: Lsp_Server_Config, language, file_path: string) -> bool {
	// Language check
	if cfg.language == "*" do return true
	if len(language) > 0 {
		rem := cfg.language
		for len(rem) > 0 {
			comma_idx := strings.index_byte(rem, ',')
			item := rem
			if comma_idx >= 0 {
				item = rem[:comma_idx]
				rem = rem[comma_idx + 1:]
			} else {
				rem = ""
			}
			trimmed := strings.trim_space(item)
			if trimmed == "*" do return true
			if strings.equal_fold(trimmed, language) do return true
		}
	}

	// File extension check
	if len(file_path) > 0 && len(cfg.file_extensions) > 0 {
		last_slash := strings.last_index_byte(file_path, '/')
		filename := file_path[last_slash + 1:] if last_slash >= 0 else file_path
		last_dot := strings.last_index_byte(filename, '.')
		if last_dot >= 0 {
			ext_with_dot := filename[last_dot:] // e.g. ".go"
			ext_no_dot := filename[last_dot + 1:] // e.g. "go"
			rem := cfg.file_extensions
			for len(rem) > 0 {
				comma_idx := strings.index_byte(rem, ',')
				item := rem
				if comma_idx >= 0 {
					item = rem[:comma_idx]
					rem = rem[comma_idx + 1:]
				} else {
					rem = ""
				}
				trimmed := strings.trim_space(item)
				if trimmed == "" do continue
				trimmed_no_dot := trimmed[1:] if strings.has_prefix(trimmed, ".") else trimmed
				if strings.equal_fold(trimmed, ext_with_dot) || strings.equal_fold(trimmed_no_dot, ext_no_dot) {
					return true
				}
			}
		}
	}

	return false
}

// lsp_server_config_resolve picks the best config for file_path from a slice
// of candidate configs.
//
// Precedence:
// 1. Longest matching literal dir_prefix (path boundary enforced).
// 2. Matching dir_pattern (glob pattern matching file_path).
// 3. Global default (dir_prefix == "" && dir_pattern == "").
//
// Returns (config, true) on a match, ({}, false) when no config matches at all.
lsp_server_config_resolve :: proc(configs: []Lsp_Server_Config, file_path: string) -> (Lsp_Server_Config, bool) {
	best_idx := -1
	best_tier := 0 // 0 = none, 1 = default, 2 = pattern, 3 = prefix
	best_prefix_len := -1

	for cfg, i in configs {
		prefix := cfg.dir_prefix
		pattern := cfg.dir_pattern

		// Check literal dir_prefix match
		prefix_matches := false
		if len(prefix) > 0 {
			if len(file_path) >= len(prefix) && file_path[:len(prefix)] == prefix {
				if len(file_path) == len(prefix) || file_path[len(prefix)] == '/' {
					prefix_matches = true
				}
			}
		}

		if prefix_matches {
			// Tier 3: literal dir_prefix (longest prefix wins)
			if best_tier < 3 || len(prefix) > best_prefix_len {
				best_idx = i
				best_tier = 3
				best_prefix_len = len(prefix)
			}
			continue
		}

		// Literal dir_prefix matches take precedence over patterns and defaults
		if best_tier >= 3 do continue

		// Check dir_pattern match
		if len(pattern) > 0 {
			if lsp_path_glob_match(pattern, file_path) {
				if best_tier < 2 {
					best_idx = i
					best_tier = 2
				}
				continue
			}
		}

		// Pattern matches take precedence over global default
		if best_tier >= 2 do continue

		// Check global default: dir_prefix == "" && dir_pattern == ""
		if prefix == "" && pattern == "" {
			if best_tier < 1 {
				best_idx = i
				best_tier = 1
			}
			continue
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
	delete(c.dir_pattern)
	delete(c.created_at)
	delete(c.updated_at)
}

lsp_server_configs_destroy :: proc(configs: [dynamic]Lsp_Server_Config) {
	for c in configs do lsp_server_config_destroy(c)
	delete(configs)
}
