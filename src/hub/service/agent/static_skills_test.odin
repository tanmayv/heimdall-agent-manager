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
			channel := []string{"artifact download", "vault_unavailable", "unsent_chunks", "events subscriptions", "events unwatch"}
			operations := []string{"task-chain create --kind mixed_work", "user_stopped", "rate_limited", "--project-ids", "shell serve", "preview_url", "without `--bg`", "last 20 lines", "omit sensitive output", "My reading:", "approvals the user granted and not granted", "### Daily brief", "Nothing needs you.", "automations create --target bot --trigger \"cron:"}
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

// ---------------------------------------------------------------------------
// Ownership: each topic lives in exactly one skill (design §6.2). The owner
// holds the topic; no other skill carries the same heading.
// ---------------------------------------------------------------------------

Skill_Owned_Topic :: struct {
	owner:    string,
	headings: []string, // "## ..." heading lines the owner holds and no other skill may repeat
	topics:   []string, // substrings the owner must keep (verbs, flags, rules)
}

SKILL_OWNED_TOPICS := []Skill_Owned_Topic{
	{"chain-events-and-claims",
		{"## Event inbox and migration notices", "## Subscriptions, watches and limits", "## Requirement revisions: acknowledging on your own claim", "## Durable claims, cancellation and transfer"},
		{"events next", "events ack", "events watch", "events subscriptions", "lease transfer", "task cancel", "--acknowledge-requirements-revision", "--legacy-event-notices"}},
	{"shell-sessions",
		{"## The three kinds", "## Calling a server session from this host"},
		{"shell run", "shell serve", "shell set-port", "shell list", "/proxy/", "--bg"}},
	{"action-cards",
		{"## From an agent: `ham-ctl action create`", "## Operation catalog", "## Guards"},
		{"action create", "agent.cards.create"}},
	{"heimdall-ctl-communication",
		{"## 4. Asking questions", "## 5. Chat vs task comments"},
		{"chat read", "chat send", "--questions-file", "multi_question_answer", "question_stale", "start-success"}},
	{"memory-management-workflow",
		{"## Scope", "## Types", "## Propose, review, approve"},
		{"memory propose", "--project-ids", "--template-ids"}},
	{"artifact-authoring",
		{"## 3. Upload", "## 5. Deliver it"},
		{"artifact create", "--kind html-bundle", "artifact download", "artifact://"}},
	// "## 8. Solo mode" is deliberately in both task-management skills: each keeps only its half (design §6.2 row 18).
	{"worker-task-management",
		{},
		{"lease submit", "lease handoff", "lease block", "review post", "task fetch"}},
	{"ham-ctl-reference",
		{"## task-chain — your task chains", "## workflow — runs inside a mixed-work task chain", "## issue — track, discuss, and vote on issues and blockers", "## automations — event and cron rules", "## Agent webhook management"},
		{"task-chain create --title", "--coordinator", "task-chain fleet set", "task-chain token-usage", "workflow run", "issue vote", "automations create", "automations webhooks", "extension hook"}},
}

// Counts the skills whose content has `heading` as a whole line.
count_skills_with_heading :: proc(heading: string) -> (count: int, first: string) {
	for skill in STATIC_SKILLS {
		if skill_has_heading_line(skill.content, heading) {
			if count == 0 do first = skill.slug
			count += 1
		}
	}
	return
}

skill_has_heading_line :: proc(content, heading: string) -> bool {
	rest := content
	for len(rest) > 0 {
		nl := strings.index_byte(rest, '\n')
		line := rest if nl < 0 else rest[:nl]
		if line == heading do return true
		if nl < 0 do break
		rest = rest[nl + 1:]
	}
	return false
}

find_static_skill :: proc(slug: string) -> (content: string, ok: bool) {
	for skill in STATIC_SKILLS {
		if skill.slug == slug do return skill.content, true
	}
	return "", false
}

@(test)
test_static_skills_contains_all_thirteen_skills :: proc(t: ^testing.T) {
	want := []string{
		"action-cards", "artifact-authoring", "chain-events-and-claims", "coordinator-task-management",
		"ham-ctl-reference", "heimdall-ctl-communication", "heimdall-preview-setup", "memory-management-workflow",
		"ninjy-bot-operations", "ninjy-channel-communication", "search-command", "shell-sessions", "worker-task-management",
	}
	testing.expect_value(t, len(STATIC_SKILLS), len(want))
	for slug in want {
		content, ok := find_static_skill(slug)
		testing.expect(t, ok, slug)
		testing.expect(t, strings.has_prefix(content, strings.concatenate({"---\nname: ", slug, "\ndescription: "}, context.temp_allocator)), slug)
	}
}

@(test)
test_static_skills_owner_holds_topic_and_headings_are_unique :: proc(t: ^testing.T) {
	for owned in SKILL_OWNED_TOPICS {
		content, ok := find_static_skill(owned.owner)
		testing.expect(t, ok, owned.owner)
		for topic in owned.topics {
			testing.expectf(t, strings.contains(content, topic), "%s must hold topic %q", owned.owner, topic)
		}
		for heading in owned.headings {
			count, first := count_skills_with_heading(heading)
			testing.expectf(t, count == 1 && first == owned.owner, "heading %q must appear only in %s (found in %d skills, first %s)", heading, owned.owner, count, first)
		}
	}
}

@(test)
test_static_skills_ham_ctl_reference_does_not_restate_owned_groups :: proc(t: ^testing.T) {
	content, ok := find_static_skill("ham-ctl-reference")
	testing.expect(t, ok, "ham-ctl-reference")
	// Topics moved to owner skills: neither their sections nor their detail may return.
	for forbidden in ([]string{
		"## chat — inbox and sending", "### Grouped questions", "### Delivered grouped answers",
		"## shell — run commands", "### Showing a running process to the user", "### Two sessions calling each other",
		"## memory — durable memories", "### Memory scope", "## artifact — create",
		"## events — durable task-chain inbox", "## Event inbox and migration notices",
		"## Live requirement revisions", "## Durable claims, cancellation and transfer",
		"multi_question_answer", "/api/v1/preview/",
	}) {
		// Headings are matched as whole lines (the pointer table may quote an owner heading); other strings as substrings.
		restated := skill_has_heading_line(content, forbidden) if strings.has_prefix(forbidden, "#") else strings.contains(content, forbidden)
		testing.expectf(t, !restated, "ham-ctl-reference must not restate %q (owned elsewhere)", forbidden)
	}
	// It points at each owner by skill name.
	for owner in ([]string{"heimdall-ctl-communication", "shell-sessions", "chain-events-and-claims", "artifact-authoring", "memory-management-workflow", "worker-task-management"}) {
		testing.expectf(t, strings.contains(content, owner), "ham-ctl-reference must point at %s", owner)
	}
	// Design §6.4 budget: slimmed from ~70 KB; fail if it grows back.
	testing.expectf(t, len(content) < 48 * 1024, "ham-ctl-reference is %d bytes, budget is 48 KiB", len(content))
}

@(test)
test_static_skills_shell_list_flag_requirement_matches_code :: proc(t: ^testing.T) {
	// src/ctl/shell_cmds.odin ctl_shell_list: no flag is required; every filter narrows.
	content, ok := find_static_skill("shell-sessions")
	testing.expect(t, ok, "shell-sessions")
	testing.expect(t, strings.contains(content, "no flag is required"), "shell-sessions must state that shell list needs no flag")
	testing.expect(t, !strings.contains(content, "is REQUIRED (`--project` alone fails"), "shell-sessions must not claim --bridge or --chain is required")
	ref, _ := find_static_skill("ham-ctl-reference")
	testing.expect(t, !strings.contains(ref, "shell list"), "the shell list flag rule is stated once, in shell-sessions")
}

@(test)
test_static_skills_reference_pointer_table_names_existing_headings :: proc(t: ^testing.T) {
	ref, ok := find_static_skill("ham-ctl-reference")
	testing.expect(t, ok, "ham-ctl-reference")
	// Every pointer row names an owner skill and a heading that exists in it.
	pointers := []struct{ owner, heading: string }{
		{"heimdall-ctl-communication", "## 3. Send"}, {"heimdall-ctl-communication", "## 4. Asking questions"}, {"heimdall-ctl-communication", "## 1. Startup"},
		{"shell-sessions", "## Commands"}, {"shell-sessions", "## Other verbs"}, {"shell-sessions", "## Calling a server session from this host"},
		{"heimdall-preview-setup", "## Start and share"}, {"heimdall-preview-setup", "## Backend behavior through the tunnel"},
		{"chain-events-and-claims", "## Event inbox and migration notices"}, {"chain-events-and-claims", "## Durable claims, cancellation and transfer"},
		{"chain-events-and-claims", "## Requirement revisions: acknowledging on your own claim"},
		{"coordinator-task-management", "## 9. Live requirement amendments and significant changes"},
		{"coordinator-task-management", "## 6. Recording the user's verdict"},
		{"artifact-authoring", "## 3. Upload"}, {"memory-management-workflow", "## Scope"}, {"memory-management-workflow", "## Commands"},
		{"action-cards", "## From an agent: `ham-ctl action create`"}, {"search-command", "## Parameters (CLI flag / RPC field)"},
		{"worker-task-management", "## 6. Fetch omitted or referenced context"}, {"worker-task-management", "## 7. Reviewing"},
	}
	for ptr in pointers {
		testing.expectf(t, strings.contains(ref, ptr.heading), "ham-ctl-reference pointer table must name %q", ptr.heading)
		content, found := find_static_skill(ptr.owner)
		testing.expect(t, found, ptr.owner)
		testing.expectf(t, skill_has_heading_line(content, ptr.heading), "%s must have heading %q", ptr.owner, ptr.heading)
	}
	// Restored rules (coordinator audit of e43bc3ba).
	for rule in ([]string{"refused in solo mode for your own work", "the task returns to `ready`", "(must be `ready`)", "bare `<path>`", "--expected-requirements-revision", "workflow-stage restrictions still apply", "for all roles"}) {
		testing.expectf(t, strings.contains(ref, rule), "ham-ctl-reference must keep %q", rule)
	}
	coord, _ := find_static_skill("coordinator-task-management")
	testing.expect(t, strings.contains(coord, "MCP cannot acknowledge another agent's lease or approve reviews"), "coordinator §9 must hold the MCP rules")
	testing.expect(t, strings.contains(coord, "opaque `revision`"), "coordinator §9 must distinguish the MCP revision")
	comm, _ := find_static_skill("heimdall-ctl-communication")
	testing.expect(t, strings.contains(comm, "not vault envelopes"), "comm skill must say plaintext, not vault envelopes")
	art, _ := find_static_skill("artifact-authoring")
	testing.expect(t, !strings.contains(art, "or the `ham-ctl-reference` skill"), "artifact-authoring must not point back at the reference")
}
