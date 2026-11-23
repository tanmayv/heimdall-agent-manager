package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import agent "odin_test:hub/service/agent"
import "odin_test:hub/bootcache"
import "odin_test:hub/domain"
import "odin_test:hub/repository/iface"
import contracts "odin_test:contracts"

// One fixture follows the actual hub -> hashed cache -> bridge pipeline. Set
// HEIMDALL_SKILLFIX_EXPORT_DIR to retain its exact files for Codex enumeration.
@(test)
test_dynamic_skill_bootstrap_sealed_cache_restart :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	prev_key, had_key := os.lookup_env("HEIMDALL_VAULT_KEYRING", context.temp_allocator)
	prev_ctl, had_ctl := os.lookup_env("HEIMDALL_HAM_CTL_BIN", context.temp_allocator)
	defer {
		if had_key { os.set_env("HEIMDALL_VAULT_KEYRING", prev_key) } else { os.unset_env("HEIMDALL_VAULT_KEYRING") }
		if had_ctl { os.set_env("HEIMDALL_HAM_CTL_BIN", prev_ctl) } else { os.unset_env("HEIMDALL_HAM_CTL_BIN") }
	}
	os.set_env("HEIMDALL_VAULT_KEYRING", test_keyring_env_value(TEST_VAULT_KEY_HEX))
	os.set_env("HEIMDALL_HAM_CTL_BIN", "/bin/sh")
	// Use the actual deployed Codex skill directory rather than machine catalog state.
	providers := []Bridge_Catalog_Provider{{provider = "codex", state = "active", skill_dir = ".codex/skills"}}
	snapshot := Bridge_Provider_Catalog_Snapshot{providers = providers}
	sync.rw_mutex_lock(&bridge_provider_catalog_mutex)
	prev_loaded := bridge_provider_catalog_loaded
	prev_snapshot := bridge_provider_catalog_snapshot
	bridge_provider_catalog_loaded = true
	bridge_provider_catalog_snapshot = &snapshot
	sync.rw_mutex_unlock(&bridge_provider_catalog_mutex)
	defer {
		sync.rw_mutex_lock(&bridge_provider_catalog_mutex)
		bridge_provider_catalog_loaded = prev_loaded
		bridge_provider_catalog_snapshot = prev_snapshot
		sync.rw_mutex_unlock(&bridge_provider_catalog_mutex)
	}
	enc :: proc(s: string) -> string {
		token, _ := test_encrypt_hex(s, TEST_VAULT_KEY_HEX, context.temp_allocator)
		return token
	}
	title := "Voice messages: \"quoted\" \\path\nUnicode café 日本語 😀"
	description := "Use: \"quotes\" and \\slashes\nnext\tline café 日本語 😀\u0085\u2028\u2029"
	body := "Skill body: literal \\n stays literal.\nSecond line: café 日本語 😀\n"
	identity := domain.Agent{agent_id = "agt_skillfix", owner_user_id = "user_skillfix", template_id = domain.TEMPLATE_BOT_ID}
	agents := iface.Agent_Repository{
		ctx = &identity,
		get = proc(ctx: rawptr, id: string) -> (domain.Agent, bool, domain.Domain_Error) {
			return (^domain.Agent)(ctx)^, true, {}
		},
		get_instance = proc(ctx: rawptr, id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
			a := (^domain.Agent)(ctx)
			return {agent_instance_id = id, agent_id = a.agent_id, owner_user_id = a.owner_user_id,
			        bridge_id = "brg_skillfix", provider = "codex", runtime_status = "stopped"}, true, {}
		},
	}
	structured := true
	bridges := iface.Bridge_Repository{ctx = &structured, get_bridge = proc(ctx: rawptr, id: string) -> (domain.Bridge, bool, domain.Domain_Error) {
		return {bridge_id = id, capabilities_json = "{\"features\":[\"dynamic_skill_v2\"]}" if (^bool)(ctx)^ else "{}"}, true, {}
	}}
	memories := []domain.Memory{
		{memory_id = "mem_18eab58c00000001", type = .Skill, status = "active", agent_ids = {"agt_skillfix"},
		 title = enc(title), description = enc(description), body = enc(body)},
		{memory_id = "mem_18eab58c00000002", type = .Skill, status = "active", agent_ids = {"agt_skillfix"},
		 title = enc(title), body = enc(body)}, // empty description falls back AFTER decryption
		{memory_id = "mem_habit", type = .Habit, status = "active", agent_ids = {"agt_skillfix"}, title = "Habit fixture", body = "Habit only"},
		{memory_id = "mem_wrong", type = .Skill, status = "active", agent_ids = {"agt_other"}, title = "Wrong agent", body = "excluded"},
		{memory_id = "mem_inactive", type = .Skill, status = "pending", agent_ids = {"agt_skillfix"}, title = "Inactive", body = "excluded"},
	}
	content := iface.Content_Repository{
		ctx = &memories,
		list_memories = proc(ctx: rawptr, owner: domain.User_ID) -> ([]domain.Memory, domain.Domain_Error) {
			return (^[]domain.Memory)(ctx)^, {}
		},
	}
	service := agent.Agent_Service{agents = &agents, bridges = &bridges, content = &content}
	instance_manifest, ok, _ := agent.bootstrap_manifest_json_for_bridge(&service, identity.owner_user_id, "brg_skillfix", "inst_skillfix")
	testing.expect(t, ok)
	bootcache.bump_content_epoch()
	fresh, fresh_ok, _ := agent.bootstrap_manifest_conditional(&service, identity.owner_user_id, identity.agent_id,
	                                                         "coordinator", "codex", "", "brg_skillfix", "")
	testing.expect(t, fresh_ok && fresh.status == 200)
	// Conditional cache results are borrowed. Epoch invalidation below can free
	// that entry, so retain an owned snapshot for restart comparisons/assembly.
	fresh_etag := strings.clone(fresh.etag)
	defer delete(fresh_etag)
	fresh_manifest := strings.clone(fresh.manifest_json)
	defer delete(fresh_manifest)
	warm, warm_ok, _ := agent.bootstrap_manifest_conditional(&service, identity.owner_user_id, identity.agent_id,
	                                                       "coordinator", "codex", "", "brg_skillfix", fresh_etag)
	testing.expect(t, warm_ok && warm.status == 304 && !warm.was_render)
	bootcache.bump_content_epoch()
	restarted, restarted_ok, _ := agent.bootstrap_manifest_conditional(&service, identity.owner_user_id, identity.agent_id,
	                                                                 "coordinator", "codex", "", "brg_skillfix", "")
	testing.expect(t, restarted_ok)
	testing.expect_value(t, restarted.manifest_json, fresh_manifest)

	// Changing only the bridge capability must bypass the warm manifest cache.
	structured = false
	legacy_instance, legacy_ok, _ := agent.bootstrap_manifest_json_for_bridge(&service, identity.owner_user_id, "brg_skillfix", "inst_skillfix")
	testing.expect(t, legacy_ok)
	legacy_agent, legacy_agent_ok, _ := agent.bootstrap_manifest_conditional(&service, identity.owner_user_id, identity.agent_id, "coordinator", "codex", "", "brg_skillfix", fresh_etag)
	testing.expect(t, legacy_agent_ok && legacy_agent.status == 200 && legacy_agent.was_render)
	for manifest in ([]string{legacy_instance, legacy_agent.manifest_json}) {
		doc: struct{skills: []struct{name, hash: string}}
		testing.expect(t, json.unmarshal_string(manifest, &doc, allocator = context.temp_allocator) == nil)
		count := 0
		for skill in doc.skills {
			if !strings.has_prefix(skill.name, "mem-18eab58c") do continue
			payload, found := agent.resolve_single_blob(&service, skill.hash)
			testing.expect(t, found && bootstrap_cache_verify_hash(payload, skill.hash))
			// Simulate the OLD bridge's embedded-token replacement, not the new renderer.
			plain := bridge_bootstrap_decrypt_owned(strings.clone(payload))
			defer delete(plain)
			testing.expect(t, strings.has_prefix(plain, fmt.tprintf("---\nname: %s\ndescription: %s\n", skill.name, skill.name)))
			testing.expect(t, strings.has_suffix(plain, body))
			count += 1
		}
		testing.expect_value(t, count, 2)
	}
	structured = true
	export_dir, export_ok := os.lookup_env("HEIMDALL_SKILLFIX_EXPORT_DIR", context.temp_allocator)
	for manifest, manifest_index in ([]string{instance_manifest, fresh_manifest}) {
		testing.expect(t, strings.contains(manifest, "mem-18eab58c00000001") && strings.contains(manifest, "mem-18eab58c00000002"), "both skills selected")
		testing.expect(t, !strings.contains(manifest, "mem-wrong") && !strings.contains(manifest, "mem-inactive"))
		testing.expect(t, !strings.contains(manifest, "mem-habit"), "Habit must not be a skill")
		cache_dir := fmt.tprintf("/tmp/ham-skillfix-%d-%d", os.get_pid(), manifest_index)
		os.remove_all(cache_dir)
		defer os.remove_all(cache_dir)
		cache: Bootstrap_Cache
		bootstrap_cache_init(&cache, cache_dir, 1024*1024*8)
		hashes := bridge_bootstrap_collect_manifest_hashes(manifest)
		for h in hashes {
			blob, found := agent.resolve_single_blob(&service, h)
			testing.expect(t, found, h)
			testing.expect(t, bootstrap_cache_verify_hash(blob, h))
			testing.expect(t, bootstrap_cache_put(&cache, h, blob))
		}
		// New cache object reconstructs its index from the exact disk blobs.
		reopened: Bootstrap_Cache
		bootstrap_cache_init(&reopened, cache_dir, 1024*1024*8)
		d := Bridge_Bootstrap_Descriptor{instance_id = "inst_skillfix", agent_id = identity.agent_id, role = "coordinator"}
		files, result := bridge_bootstrap_build_file_set(manifest, d, "unix:/tmp/test.sock", "test-token", "codex", &reopened)
		defer bridge_bootstrap_free_file_set(files)
		testing.expect(t, result.ok, result.detail)
		dynamic_count := 0
		memory_count := 0
		for f in files {
			if f.kind == "MEMORY_MD" {
				memory_count += 1
				testing.expect(t, strings.contains(f.content, "Habit only"))
				testing.expect(t, !strings.contains(f.content, "Skill body") && !strings.contains(f.content, "Voice messages"))
			}
			if f.kind != "SKILL" || !strings.contains(f.relative_path, "/mem-18eab58c0000000") do continue
			dynamic_count += 1
			testing.expect(t, strings.has_suffix(f.content, body))
			testing.expect(t, bridge_bootstrap_skill_generated_valid(f.content))
			lines := strings.split(f.content, "\n", context.temp_allocator)
			name := strings.trim_prefix(lines[1], "name: ")
			testing.expect(t, strings.has_suffix(f.relative_path, fmt.tprintf("/%s/SKILL.md", name)))
			testing.expect_value(t, len(name), 20)
			desc: string
			testing.expect(t, json.unmarshal_string(strings.trim_prefix(lines[2], "description: "), &desc, allocator = context.temp_allocator) == nil)
			expected := description if strings.has_suffix(name, "1") else title
			testing.expect_value(t, desc, expected)
			if export_ok && manifest_index == 1 {
				testing.expect(t, bridge_bootstrap_write_skill_file(export_dir, f.relative_path, f.content))
			}
		}
		testing.expect_value(t, dynamic_count, 2)
		testing.expect_value(t, memory_count, 1)
	}
	if export_ok {
		expected, _ := json.marshal(struct{title, description, body: string}{title, description, body}, allocator = context.temp_allocator)
		testing.expect(t, os.write_entire_file(fmt.tprintf("%s/expected.json", export_dir), expected) == nil)
	}
}

@(test)
test_dynamic_skill_explicit_legacy_and_invalid :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	providers := []Bridge_Catalog_Provider{{provider = "codex", state = "active", skill_dir = ".codex/skills"}}
	snapshot := Bridge_Provider_Catalog_Snapshot{providers = providers}
	sync.rw_mutex_lock(&bridge_provider_catalog_mutex)
	prev_loaded := bridge_provider_catalog_loaded
	prev_snapshot := bridge_provider_catalog_snapshot
	bridge_provider_catalog_loaded = true
	bridge_provider_catalog_snapshot = &snapshot
	sync.rw_mutex_unlock(&bridge_provider_catalog_mutex)
	defer {
		sync.rw_mutex_lock(&bridge_provider_catalog_mutex)
		bridge_provider_catalog_loaded = prev_loaded
		bridge_provider_catalog_snapshot = prev_snapshot
		sync.rw_mutex_unlock(&bridge_provider_catalog_mutex)
	}
	body := "---\nname: authored\ndescription: |\n  An authored: description\n---\n\n# body\n"
	blob := contracts.Dynamic_Skill_Blob{format = contracts.DYNAMIC_SKILL_FORMAT, memory_id = "mem_123", name = "mem-123", body = body}
	raw, _ := json.marshal(blob, allocator = context.temp_allocator)
	// Exercise the actual legacy response writer and default-skill fallback.
	run_dir := fmt.tprintf("/tmp/ham-skillfix-legacy-%d", os.get_pid())
	os.remove_all(run_dir)
	defer os.remove_all(run_dir)
	legacy_response, _ := json.marshal(struct{skills: []struct{name, content: string}}{
		skills = {{name = "mem-123", content = string(raw)}},
	}, allocator = context.temp_allocator)
	paths := bridge_bootstrap_write_skills(run_dir, "codex", string(legacy_response))
	testing.expect_value(t, len(paths), 1)
	if len(paths) == 1 {
		file, read_err := os.read_entire_file(fmt.tprintf("%s/%s", run_dir, paths[0]), context.temp_allocator)
		testing.expect(t, read_err == nil)
		testing.expect_value(t, string(file), body)
	}
	fallback, _ := json.marshal(struct{default_skill_name, default_skill_content: string}{"mem-123", string(raw)}, allocator = context.temp_allocator)
	fallback_paths := bridge_bootstrap_write_skills(run_dir, "codex", string(fallback))
	testing.expect_value(t, len(fallback_paths), 1)
	if len(paths) == 1 && len(fallback_paths) == 1 do testing.expect_value(t, paths[0], fallback_paths[0])
	name, rendered, ok := bridge_bootstrap_render_skill("mem-123", string(raw))
	defer delete(name); defer delete(rendered)
	testing.expect(t, ok)
	testing.expect_value(t, rendered, body)
	testing.expect_value(t, name, "mem-123")
	legacy_name, legacy, legacy_ok := bridge_bootstrap_render_skill("authored", body)
	defer delete(legacy_name); defer delete(legacy)
	testing.expect(t, legacy_ok)
	testing.expect_value(t, legacy, body)
	// Authored invalid frontmatter warns but remains intact per coordinator ruling.
	bad := "---\nname: unfinished\n"
	bad_name, bad_content, bad_ok := bridge_bootstrap_render_skill("bad", bad)
	defer delete(bad_name); defer delete(bad_content)
	testing.expect(t, bad_ok)
	testing.expect_value(t, bad_content, bad)
	_, _, invalid_ok := bridge_bootstrap_render_skill("bad", "{\"format\":\"unknown\"}")
	testing.expect(t, !invalid_ok)
	testing.expect(t, !bridge_bootstrap_skill_generated_valid("---\nname: bad_name\ndescription: \"d\"\nheimdall_managed: true\n---\n"))
	testing.expect(t, !bridge_bootstrap_skill_generated_valid("---\nname: name\ndescription: unquoted: value\nheimdall_managed: true\n---\n"))
}

@(test)
test_dynamic_skill_locked_is_diagnosed :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	// Unknown epoch remains locked regardless of any user keyring.
	token := test_vault_seal("secret", TEST_VAULT_KEY_HEX, 999)
	defer delete(token)
	blob := contracts.Dynamic_Skill_Blob{format = contracts.DYNAMIC_SKILL_FORMAT, memory_id = "mem_locked",
	                                   name = "mem-locked", title = token, body = "body"}
	raw, _ := json.marshal(blob, allocator = context.temp_allocator)
	_, _, ok := bridge_bootstrap_render_skill("mem-locked", string(raw))
	testing.expect(t, !ok)
}

@(test)
test_dynamic_skill_authored_whitespace_and_plaintext_markers :: proc(t: ^testing.T) {
	body := "---\nname: authored\ndescription: authored\n---\n\n[Encrypted] [encrypted: bridge vault locked] vault:v2:example\n"
	for literal_newlines in ([]bool{false, true}) {
		input := strings.concatenate({"\n \t", body})
		if literal_newlines {
			replaced, _ := strings.replace_all(input, "\n", "\\n")
			delete(input)
			input = replaced
		}
		defer delete(input)
		blob := contracts.Dynamic_Skill_Blob{format = contracts.DYNAMIC_SKILL_FORMAT, memory_id = "mem_authored", name = "mem-authored", body = input}
		raw, _ := json.marshal(blob, allocator = context.temp_allocator)
		name, rendered, ok := bridge_bootstrap_render_skill("mem-authored", string(raw))
		defer delete(name); defer delete(rendered)
		testing.expect(t, ok)
		testing.expect_value(t, rendered, body)
		if export_dir, present := os.lookup_env("HEIMDALL_SKILLFIX_EXPORT_DIR", context.temp_allocator); present {
			testing.expect(t, bridge_bootstrap_write_skill_file(export_dir, ".codex/skills/authored/SKILL.md", rendered))
		}
	}
	// Static/legacy Markdown also trims leading whitespace without losing the tail.
	name, rendered, ok := bridge_bootstrap_render_skill("authored", "\n \t---\nname: authored\ndescription: authored\n---\n\n[Encrypted] Literal \\n documentation\n")
	defer delete(name); defer delete(rendered)
	testing.expect(t, ok)
	testing.expect_value(t, rendered, "---\nname: authored\ndescription: authored\n---\n\n[Encrypted] Literal \\n documentation\n")
}
