package agent

import "core:strings"
import "core:testing"
import "odin_test:hub/bootcache"
import "odin_test:hub/domain"
import "odin_test:hub/repository/iface"

@(test)
test_static_skills_ham_ctl_reference_content :: proc(t: ^testing.T) {
	found := false
	for skill in STATIC_SKILLS {
		if skill.slug == "ham-ctl-reference" {
			found = true
			testing.expect(t, strings.contains(skill.content, "task-chain create --title"), "ham-ctl-reference must document task-chain create")
			testing.expect(t, strings.contains(skill.content, "--coordinator"), "ham-ctl-reference must document coordinator flag")
			testing.expect(t, !strings.contains(skill.content, "Pub/Sub subscription mechanism"), "ham-ctl-reference must not document removed Pub/Sub subscriptions")
		}
	}
	testing.expect(t, found, "STATIC_SKILLS must contain ham-ctl-reference")
}

@(test)
test_static_skills_heimdall_preview_setup_content :: proc(t: ^testing.T) {
	found := false
	for skill in STATIC_SKILLS {
		if skill.slug == "heimdall-preview-setup" {
			found = true
			testing.expect(t, strings.contains(skill.content, "shell serve"), "heimdall-preview-setup must document shell serve")
			testing.expect(t, strings.contains(skill.content, "--port"), "heimdall-preview-setup must document --port")
			testing.expect(t, strings.contains(skill.content, "127.0.0.1"), "heimdall-preview-setup must document the preferred loopback bind")
			testing.expect(t, strings.contains(skill.content, "base: './'"), "heimdall-preview-setup must document a relative Vite base")
			testing.expect(t, strings.contains(skill.content, "preview_url"), "heimdall-preview-setup must document preview_url")
			testing.expect(t, strings.contains(skill.content, "/proxy/"), "heimdall-preview-setup must document cross-bridge proxy calls")
			testing.expect(t, strings.contains(skill.content, "/p/"), "heimdall-preview-setup must document preview-origin paths")
			testing.expect(t, strings.contains(skill.content, "description: How to share a web app or API you are running on localhost"), "heimdall-preview-setup description must mention localhost")
			testing.expect(t, strings.contains(skill.content, "description:") && strings.contains(skill.content, "presenting the hub-returned `preview_url` verbatim"), "heimdall-preview-setup description must mention preview_url")
		}
	}
	testing.expect(t, found, "STATIC_SKILLS must contain heimdall-preview-setup")
}

@(test)
test_static_skills_artifact_authoring_content :: proc(t: ^testing.T) {
	found := false
	for skill in STATIC_SKILLS {
		if skill.slug == "artifact-authoring" {
			found = true
			testing.expect(t, strings.has_prefix(skill.content, "---\nname: artifact-authoring\ndescription: "), "artifact-authoring must start with name/description frontmatter")
			testing.expect(t, strings.contains(skill.content, "--kind html-bundle --directory"), "artifact-authoring must document html-bundle directory upload")
			testing.expect(t, strings.contains(skill.content, "--entry"), "artifact-authoring must document --entry")
			testing.expect(t, strings.contains(skill.content, "--kind image --content-type image/png"), "artifact-authoring must document image kind and content type")
			testing.expect(t, strings.contains(skill.content, "artifact://"), "artifact-authoring must document artifact:// delivery links")
		}
	}
	testing.expect(t, found, "STATIC_SKILLS must contain artifact-authoring")
}

@(test)
test_ninjy_skills_include_channel_and_operation_recipes :: proc(t: ^testing.T) {
	for slug, index in ([]string{"ninjy-channel-communication", "ninjy-bot-operations"}) {
		found := false
		for skill in STATIC_SKILLS {
			if skill.slug != slug do continue
			found = true
			frontmatter := strings.concatenate({"---\nname: ", slug, "\ndescription: Use as the Ninjy bot"})
			defer delete(frontmatter)
			testing.expect(t, strings.has_prefix(skill.content, frontmatter), slug)
			channel := []string{"channel history --limit 50", "latest `updated_at` across all projects", "artifact download", "vault_unavailable", "unsent_chunks", "events subscriptions", "events unwatch"}
			operations := []string{"task-chain create --kind mixed_work", "user_stopped", "rate_limited", "--project-ids", "shell serve", "preview_url", "chain_work_done", "My reading:", "approvals the user granted and not granted"}
			for recipe in (channel if index == 0 else operations) {
				testing.expect(t, strings.contains(skill.content, recipe), recipe)
			}
		}
		testing.expect(t, found, slug)
	}
}

@(test)
test_ninjy_bootstrap_selection_and_warm_manifest :: proc(t: ^testing.T) {
	identity := domain.Agent{
		agent_id = "agt_ninjy_bootstrap_test", name = "Ninjy fixture",
		owner_user_id = "user_ninjy_bootstrap_test", template_id = domain.TEMPLATE_BOT_ID,
		instructions = "Custom instruction fixture",
	}
	agents := iface.Agent_Repository{
		ctx = &identity,
		get = proc(ctx: rawptr, id: string) -> (domain.Agent, bool, domain.Domain_Error) {
			return (^domain.Agent)(ctx)^, true, {}
		},
		get_instance = proc(ctx: rawptr, id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
			identity := (^domain.Agent)(ctx)
			return {
				agent_instance_id = id, agent_id = identity.agent_id,
				owner_user_id = identity.owner_user_id, bridge_id = "brg_ninjy_fixture",
				provider = "codex", runtime_status = "stopped", run_count = 7,
			}, true, {}
		},
	}
	bridges := iface.Bridge_Repository{
		get_bridge = proc(ctx: rawptr, id: string) -> (domain.Bridge, bool, domain.Domain_Error) {
			return {bridge_id = id}, true, {}
		},
	}
	service := Agent_Service{agents = &agents, bridges = &bridges}
	bot_hash := bootstrap_fragment_hash(BOOTSTRAP_BOT_AGENTS_TEMPLATE)
	shared_hash := bootstrap_fragment_hash(BOOTSTRAP_AGENTS_TEMPLATE)
	defer delete(bot_hash)
	defer delete(shared_hash)
	testing.expect(t, bot_hash != shared_hash)

	instance_manifest, instance_ok, _ := bootstrap_manifest_json_for_bridge(
		&service, identity.owner_user_id, "brg_ninjy_fixture", "inst_ninjy_fixture")
	defer delete(instance_manifest)
	testing.expect(t, instance_ok)
	testing.expect(t, strings.contains(instance_manifest, bot_hash))
	testing.expect(t, strings.contains(instance_manifest, `"run_count":7`))
	testing.expect(t, strings.contains(instance_manifest, "Custom instruction fixture"))

	fresh, fresh_ok, _ := bootstrap_manifest_conditional(
		&service, identity.owner_user_id, identity.agent_id, "coordinator", "codex", "", "brg_ninjy_fixture", "")
	testing.expect(t, fresh_ok && fresh.status == 200 && fresh.was_render)
	testing.expect(t, strings.contains(fresh.manifest_json, bot_hash))
	for slug in ([]string{"ninjy-channel-communication", "ninjy-bot-operations"}) {
		testing.expect(t, strings.contains(instance_manifest, slug), slug)
		testing.expect(t, strings.contains(fresh.manifest_json, slug), slug)
	}
	bot_body, found := resolve_single_blob(&service, bot_hash)
	testing.expect(t, found)
	testing.expect_value(t, bot_body, BOOTSTRAP_BOT_AGENTS_TEMPLATE)

	warm, warm_ok, _ := bootstrap_manifest_conditional(
		&service, identity.owner_user_id, identity.agent_id, "coordinator", "codex", "", "brg_ninjy_fixture", fresh.etag)
	testing.expect(t, warm_ok && warm.status == 304 && !warm.was_render)
	previous_etag := strings.clone(fresh.etag)
	defer delete(previous_etag)
	previous_version := strings.clone(fresh.version)
	defer delete(previous_version)

	identity.template_id = domain.TEMPLATE_COORDINATOR_ID
	bootcache.bump_content_epoch()
	changed, changed_ok, _ := bootstrap_manifest_conditional(
		&service, identity.owner_user_id, identity.agent_id, "coordinator", "codex", "", "brg_ninjy_fixture", previous_etag)
	testing.expect(t, changed_ok && changed.status == 200 && changed.was_render)
	testing.expect(t, changed.etag != previous_etag && changed.version != previous_version)
	testing.expect(t, strings.contains(changed.manifest_json, shared_hash))
	for template_id in ([]string{"", "tmpl_worker", "tmpl_reviewer", "tmpl_soloist", "tmpl_custom_fixture"}) {
		hash := bootstrap_template_hash(template_id)
		defer delete(hash)
		testing.expect_value(t, hash, shared_hash)
	}
	shared_body, shared_found := resolve_single_blob(&service, shared_hash)
	testing.expect(t, shared_found)
	testing.expect_value(t, shared_body, BOOTSTRAP_AGENTS_TEMPLATE)
}
