package main

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"
import vault "odin_test:lib/vault"

// Single boundary for cached manifests and legacy/fallback responses. Never
// substitute plaintext into serialized JSON or YAML: decrypt the fields first.
// Input is borrowed; returned name/content are owned.
bridge_bootstrap_render_skill :: proc(name, payload: string) -> (string, string, bool) {
	blob: contracts.Dynamic_Skill_Blob
	if strings.has_prefix(strings.trim_space(payload), "{") {
		if json.unmarshal_string(payload, &blob, allocator = context.temp_allocator) != nil ||
		   blob.format != contracts.DYNAMIC_SKILL_FORMAT {
			fmt.eprintln("bridge bootstrap skill:", name, "invalid dynamic skill payload")
			return "", "", false
		}
		if !bridge_bootstrap_skill_slug_valid(blob.name) || blob.memory_id == "" {
			fmt.eprintln("bridge bootstrap skill:", blob.memory_id, "invalid memory skill identity")
			return "", "", false
		}
		title := bridge_bootstrap_decrypt_owned(strings.clone(blob.title))
		decrypted_description := bridge_bootstrap_decrypt_owned(strings.clone(blob.description))
		body := bridge_bootstrap_decrypt_owned(strings.clone(blob.body))
		defer delete(title)
		defer delete(decrypted_description)
		defer delete(body)
		description := decrypted_description
		if bridge_bootstrap_skill_unavailable(title) || bridge_bootstrap_skill_unavailable(description) ||
		   bridge_bootstrap_skill_unavailable(body) {
			fmt.eprintln("bridge bootstrap skill:", blob.memory_id, "vault locked or decryption failed; skill cannot be materialized")
			return "", "", false
		}
		// Authored frontmatter stays byte-for-byte intact after decryption.
		if strings.has_prefix(strings.trim_space(body), "---") {
			bridge_bootstrap_skill_explicit_diagnostic(blob.memory_id, body)
			return strings.clone(blob.name), strings.clone(body), true
		}
		if strings.trim_space(description) == "" do description = title
		if strings.trim_space(description) == "" do description = blob.name
		encoded := bridge_bootstrap_skill_quote(description)
		defer delete(encoded)
		b := strings.builder_make()
		strings.write_string(&b, "---\nname: ")
		strings.write_string(&b, blob.name)
		strings.write_string(&b, "\ndescription: ")
		strings.write_string(&b, encoded)
		strings.write_string(&b, "\nheimdall_managed: true\n---\n\n")
		if title != "" {
			strings.write_string(&b, "# ")
			strings.write_string(&b, title)
			strings.write_string(&b, "\n\n")
		}
		strings.write_string(&b, body)
		content := strings.to_string(b)
		if !bridge_bootstrap_skill_generated_valid(content) {
			fmt.eprintln("bridge bootstrap skill:", blob.memory_id, "generated frontmatter validation failed")
			delete(content)
			return "", "", false
		}
		return strings.clone(blob.name), content, true
	}
	// Static skills and pre-structural hub responses are literal Markdown.
	plain_name := bridge_decrypt_embedded_vault_tokens(name, locked_marker = VAULT_LOCKED_MARKER)
	content := bridge_bootstrap_decrypt_owned(strings.clone(payload))
	if bridge_bootstrap_skill_unavailable(plain_name) || bridge_bootstrap_skill_unavailable(content) {
		fmt.eprintln("bridge bootstrap skill:", name, "vault locked or decryption failed; skill cannot be materialized")
		delete(plain_name); delete(content)
		return "", "", false
	}
	bridge_bootstrap_skill_explicit_diagnostic(name, content)
	return plain_name, content, true
}

bridge_bootstrap_skill_slug_valid :: proc(name: string) -> bool {
	if len(name) == 0 || len(name) > 64 do return false
	for ch in name {
		if !('a' <= ch && ch <= 'z') && !('0' <= ch && ch <= '9') && ch != '-' do return false
	}
	return true
}

// Our generated grammar is deliberately smaller than general YAML: fixed keys,
// a safe slug and a JSON double-quoted scalar (also valid YAML). Parse the scalar
// back before exposing the file to a provider.
bridge_bootstrap_skill_generated_valid :: proc(content: string) -> bool {
	if !strings.has_prefix(content, "---\nname: ") do return false
	rest := content[len("---\nname: "):]
	name_end := strings.index_byte(rest, '\n')
	if name_end < 0 || !bridge_bootstrap_skill_slug_valid(rest[:name_end]) do return false
	rest = rest[name_end+1:]
	if !strings.has_prefix(rest, "description: ") do return false
	rest = rest[len("description: "):]
	desc_end := strings.index_byte(rest, '\n')
	if desc_end < 2 || rest[0] != '"' || rest[desc_end-1] != '"' do return false
	description: string
	if json.unmarshal_string(rest[:desc_end], &description, allocator = context.temp_allocator) != nil do return false
	return strings.has_prefix(rest[desc_end:], "\nheimdall_managed: true\n---\n")
}

// This is a structural warning, not a general YAML parser. Authored YAML may
// use block scalars, nested mappings or comments, and must not be rewritten.
bridge_bootstrap_skill_explicit_diagnostic :: proc(identity, body: string) {
	text := strings.trim_space(body)
	if !strings.has_prefix(text, "---\n") && !strings.has_prefix(text, "---\r\n") {
		fmt.eprintln("bridge bootstrap skill:", identity, "explicit frontmatter has no opening delimiter")
		return
	}
	first := true
	has_field := false
	for line in strings.split_lines_iterator(&text) {
		if first { first = false; continue }
		trimmed := strings.trim_space(line)
		if trimmed == "---" {
			if !has_field do fmt.eprintln("bridge bootstrap skill:", identity, "explicit frontmatter has no key: value fields")
			return
		}
		if strings.index_byte(trimmed, ':') > 0 do has_field = true
	}
	fmt.eprintln("bridge bootstrap skill:", identity, "explicit frontmatter has no closing delimiter")
}

// JSON-compatible YAML quoting, escaping non-ASCII BMP runes. YAML treats
// NEL/LS/PS as line breaks even inside quotes, so do not emit those literally.
bridge_bootstrap_skill_quote :: proc(value: string) -> string {
	b := strings.builder_make()
	strings.write_byte(&b, '"')
	for ch in value {
		switch ch {
		case '"': strings.write_string(&b, "\\\"")
		case '\\': strings.write_string(&b, "\\\\")
		case '\n': strings.write_string(&b, "\\n")
		case '\r': strings.write_string(&b, "\\r")
		case '\t': strings.write_string(&b, "\\t")
		case:
			if ch < 0x20 || ch >= 0x7f {
				if ch <= 0xffff {
					fmt.sbprintf(&b, "\\u%04x", u32(ch))
				} else {
					strings.write_rune(&b, ch)
				}
			} else {
				strings.write_rune(&b, ch)
			}
		}
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}

bridge_bootstrap_skill_unavailable :: proc(value: string) -> bool {
	return bridge_has_vault_token(value) || strings.contains(value, VAULT_LOCKED_MARKER) ||
	       strings.contains(value, vault.FAILED_MARKER) || strings.contains(value, vault.OTHER_VAULT_MARKER)
}
