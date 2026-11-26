package content

import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// Fake content repository returning no owner templates so list_templates appends
// the built-in templates.
fake_content_list_templates_empty :: proc(ctx: rawptr, owner: domain.User_ID) -> ([]domain.Template, domain.Domain_Error) {
	return {}, {}
}

fake_content_get_template_none :: proc(ctx: rawptr, id: string) -> (domain.Template, bool, domain.Domain_Error) {
	return {}, false, domain.domain_error(.Not_Found, "template not found")
}

// Fake content repository returning the built-ins already to test deduplication.
fake_content_list_templates_with_builtins :: proc(ctx: rawptr, owner: domain.User_ID) -> ([]domain.Template, domain.Domain_Error) {
	out := make([]domain.Template, 5)
	out[0] = domain.Template{template_id = domain.TEMPLATE_COORDINATOR_ID, is_system = true, name = "coordinator"}
	out[1] = domain.Template{template_id = domain.TEMPLATE_WORKER_ID, is_system = true, name = "worker"}
	out[2] = domain.Template{template_id = domain.TEMPLATE_REVIEWER_ID, is_system = true, name = "reviewer"}
	out[3] = domain.Template{template_id = domain.TEMPLATE_EMPTY_ID, is_system = true, name = "empty"}
	out[4] = domain.Template{template_id = domain.TEMPLATE_SOLOIST_ID, is_system = true, name = "soloist"}
	return out, {}
}

@(test)
test_list_templates_includes_all_builtins_without_duplication :: proc(t: ^testing.T) {
	repo := iface.Content_Repository{list_templates = fake_content_list_templates_empty, get_template = fake_content_get_template_none}
	service := new_content_service(&repo, nil, nil, nil, nil, nil, nil)

	templates, err := list_templates(&service, contracts.Auth_Context{user_id = "user_1"})
	defer delete(templates)
	testing.expect_value(t, err.code, domain.Error_Code.None)

	has_coordinator := false
	has_worker := false
	has_reviewer := false
	has_empty := false
	has_soloist := false
	has_stale_reviewer := false

	for tmpl in templates {
		if tmpl.template_id == domain.TEMPLATE_COORDINATOR_ID {
			has_coordinator = true
			testing.expect_value(t, tmpl.is_system, true)
			testing.expect_value(t, tmpl.name, "coordinator")
			testing.expect_value(t, strings.contains(tmpl.instructions, "Role: Coordinator"), true)
		}
		if tmpl.template_id == domain.TEMPLATE_WORKER_ID {
			has_worker = true
			testing.expect_value(t, tmpl.is_system, true)
			testing.expect_value(t, tmpl.name, "worker")
			testing.expect_value(t, strings.contains(tmpl.instructions, "Role: Worker"), true)
		}
		if tmpl.template_id == domain.TEMPLATE_REVIEWER_ID {
			has_reviewer = true
			testing.expect_value(t, tmpl.is_system, true)
			testing.expect_value(t, tmpl.name, "reviewer")
			testing.expect_value(t, strings.contains(tmpl.instructions, "Role: Reviewer"), true)
		}
		if tmpl.template_id == domain.TEMPLATE_EMPTY_ID {
			has_empty = true
			testing.expect_value(t, tmpl.is_system, true)
			testing.expect_value(t, tmpl.name, "empty")
			testing.expect_value(t, strings.contains(tmpl.instructions, "Role: General Agent"), true)
		}
		if tmpl.template_id == domain.TEMPLATE_SOLOIST_ID {
			has_soloist = true
			testing.expect_value(t, tmpl.is_system, true)
			testing.expect_value(t, tmpl.name, "soloist")
			testing.expect_value(t, strings.contains(tmpl.instructions, "Role: Soloist"), true)
		}
		if tmpl.template_id == "tmpl_system_reviewer" do has_stale_reviewer = true
	}

	testing.expect_value(t, has_coordinator, true)
	testing.expect_value(t, has_worker, true)
	testing.expect_value(t, has_reviewer, true)
	testing.expect_value(t, has_empty, true)
	testing.expect_value(t, has_soloist, true)
	testing.expect_value(t, has_stale_reviewer, false)
	testing.expect_value(t, len(templates), 5)

	// Now verify deduplication when repository already contains the templates
	repo_dedup := iface.Content_Repository{list_templates = fake_content_list_templates_with_builtins, get_template = fake_content_get_template_none}
	service_dedup := new_content_service(&repo_dedup, nil, nil, nil, nil, nil, nil)

	templates_dedup, err_dedup := list_templates(&service_dedup, contracts.Auth_Context{user_id = "user_1"})
	defer delete(templates_dedup)
	testing.expect_value(t, err_dedup.code, domain.Error_Code.None)
	testing.expect_value(t, len(templates_dedup), 5)
}

@(test)
test_template_available_all_builtins :: proc(t: ^testing.T) {
	repo := iface.Content_Repository{list_templates = fake_content_list_templates_empty, get_template = fake_content_get_template_none}
	service := new_content_service(&repo, nil, nil, nil, nil, nil, nil)

	testing.expect_value(t, template_available(&service, "user_1", domain.TEMPLATE_COORDINATOR_ID), true)
	testing.expect_value(t, template_available(&service, "user_1", domain.TEMPLATE_WORKER_ID), true)
	testing.expect_value(t, template_available(&service, "user_1", domain.TEMPLATE_REVIEWER_ID), true)
	testing.expect_value(t, template_available(&service, "user_1", domain.TEMPLATE_EMPTY_ID), true)
	testing.expect_value(t, template_available(&service, "user_1", domain.TEMPLATE_SOLOIST_ID), true)
	testing.expect_value(t, template_available(&service, "user_1", "tmpl_system_reviewer"), false)
	testing.expect_value(t, template_available(&service, "user_1", "tmpl_non_existent"), false)
}

BOT_CHANNEL_SKILL :: #load("../../../prompts/skills/ninjy-channel-communication/SKILL.md", string)

// Exercise the public listing service: domain cannot import content without a cycle.
@(test)
test_bot_template_loaded_and_hidden_from_list :: proc(t: ^testing.T) {
	tmpl, ok := domain.builtin_template(domain.TEMPLATE_BOT_ID)
	testing.expect(t, ok)
	testing.expect_value(t, tmpl.name, "Ninjy bot")
	testing.expect_value(t, tmpl.is_system, true)
	for required in ([]string{
		"You are the user's personal Ninjy bot.",
		"./bin/ham-ctl channel send --text",
		"ninjy-channel-communication",
		"ninjy-bot-operations",
		"only within the user's approval",
		"./bin/ham-ctl events next",
		"review verdicts and memory-proposal approvals",
		"sensitive file contents out of chat",
	}) {
		testing.expect(t, strings.contains(tmpl.instructions, required), required)
	}
	// Channel commands the template no longer spells out live in the channel skill it loads.
	for moved in ([]string{
		"./bin/ham-ctl channel read",
		"./bin/ham-ctl channel history --limit 20",
		"./bin/ham-ctl channel history --limit 50",
		"latest `updated_at` across projects",
		"./bin/ham-ctl task-chain list",
		"./bin/ham-ctl task-chain show <chain_id>",
		"./bin/ham-ctl task show <task_id>",
		"./bin/ham-ctl events ack <event_id>",
	}) {
		testing.expect(t, strings.contains(BOT_CHANNEL_SKILL, moved), moved)
	}

	repo := iface.Content_Repository{list_templates = fake_content_list_templates_empty, get_template = fake_content_get_template_none}
	service := new_content_service(&repo, nil, nil, nil, nil, nil, nil)
	templates, err := list_templates(&service, contracts.Auth_Context{user_id = "user_1"})
	defer delete(templates)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	for listed in templates {
		testing.expect(t, listed.template_id != domain.TEMPLATE_BOT_ID)
	}
}
