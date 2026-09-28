package taskchain

import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import project "odin_test:hub/service/project"

subscribe_taskchain :: proc(
	service: ^Taskchain_Service,
	auth: contracts.Auth_Context,
	chain_id: domain.Task_Chain_ID,
	event_type: string,
) -> (domain.Task_Subscription, bool, domain.Domain_Error) {
	if service == nil || service.repo == nil {
		return domain.Task_Subscription{}, false, domain.domain_error(.Internal_Error, "taskchain service is not configured")
	}
	chain, ok, err := get_chain_for_read(service, auth, chain_id)
	if !ok do return domain.Task_Subscription{}, false, err

	subscriber_id := auth.agent_instance_id
	if subscriber_id == "" {
		return domain.Task_Subscription{}, false, domain.domain_error(.Validation_Failed, "subscriber agent instance is required")
	}

	evt := strings.trim_space(event_type)
	if evt == "" do evt = "all"
	if evt != "all" && evt != "chain_status" && evt != "task_status" {
		return domain.Task_Subscription{}, false, domain.domain_error(.Validation_Failed, "invalid subscription event_type")
	}

	sub_id := platform.generate_id(service.ids, "sub_")
	now := platform.clock_now(service.clock)

	sub := domain.Task_Subscription{
		subscription_id              = sub_id,
		owner_user_id                = chain.owner_user_id,
		subscriber_agent_instance_id = subscriber_id,
		chain_id                     = chain_id,
		task_id                      = "",
		event_type                   = evt,
		created_at                   = now,
	}

	return iface.taskchain_save_subscription(service.repo, sub)
}

unsubscribe_taskchain :: proc(
	service: ^Taskchain_Service,
	auth: contracts.Auth_Context,
	chain_id: domain.Task_Chain_ID,
	event_type: string,
) -> (bool, domain.Domain_Error) {
	if service == nil || service.repo == nil {
		return false, domain.domain_error(.Internal_Error, "taskchain service is not configured")
	}
	chain, ok, err := get_chain_for_read(service, auth, chain_id)
	if !ok do return false, err

	subscriber_id := auth.agent_instance_id
	if subscriber_id == "" {
		return false, domain.domain_error(.Validation_Failed, "subscriber agent instance is required")
	}

	subs, list_err := iface.taskchain_list_subscriptions_by_chain(service.repo, chain_id, chain.owner_user_id)
	if list_err.code != .None do return false, list_err
	defer destroy_subscriptions(subs)

	evt := strings.trim_space(event_type)
	removed_any := false
	for s in subs {
		if s.subscriber_agent_instance_id == subscriber_id && s.task_id == "" && (evt == "" || s.event_type == evt) {
			rem_ok, _ := iface.taskchain_remove_subscription(service.repo, s.subscription_id, chain.owner_user_id)
			if rem_ok do removed_any = true
		}
	}

	return removed_any, domain.Domain_Error{}
}

subscribe_task :: proc(
	service: ^Taskchain_Service,
	auth: contracts.Auth_Context,
	task_id: domain.Task_ID,
	event_type: string,
) -> (domain.Task_Subscription, bool, domain.Domain_Error) {
	if service == nil || service.repo == nil {
		return domain.Task_Subscription{}, false, domain.domain_error(.Internal_Error, "taskchain service is not configured")
	}
	task, ok, err := get_task_for_read(service, auth, task_id)
	if !ok do return domain.Task_Subscription{}, false, err

	subscriber_id := auth.agent_instance_id
	if subscriber_id == "" {
		return domain.Task_Subscription{}, false, domain.domain_error(.Validation_Failed, "subscriber agent instance is required")
	}

	evt := strings.trim_space(event_type)
	if evt == "" do evt = "all"
	if evt != "all" && evt != "task_status" {
		return domain.Task_Subscription{}, false, domain.domain_error(.Validation_Failed, "invalid subscription event_type for task")
	}

	sub_id := platform.generate_id(service.ids, "sub_")
	now := platform.clock_now(service.clock)

	sub := domain.Task_Subscription{
		subscription_id              = sub_id,
		owner_user_id                = task.owner_user_id,
		subscriber_agent_instance_id = subscriber_id,
		chain_id                     = task.chain_id,
		task_id                      = task_id,
		event_type                   = evt,
		created_at                   = now,
	}

	return iface.taskchain_save_subscription(service.repo, sub)
}

unsubscribe_task :: proc(
	service: ^Taskchain_Service,
	auth: contracts.Auth_Context,
	task_id: domain.Task_ID,
	event_type: string,
) -> (bool, domain.Domain_Error) {
	if service == nil || service.repo == nil {
		return false, domain.domain_error(.Internal_Error, "taskchain service is not configured")
	}
	task, ok, err := get_task_for_read(service, auth, task_id)
	if !ok do return false, err

	subscriber_id := auth.agent_instance_id
	if subscriber_id == "" {
		return false, domain.domain_error(.Validation_Failed, "subscriber agent instance is required")
	}

	subs, list_err := iface.taskchain_list_subscriptions_by_task(service.repo, task_id, task.owner_user_id)
	if list_err.code != .None do return false, list_err
	defer destroy_subscriptions(subs)

	evt := strings.trim_space(event_type)
	removed_any := false
	for s in subs {
		if s.subscriber_agent_instance_id == subscriber_id && s.task_id == task_id && (evt == "" || s.event_type == evt) {
			rem_ok, _ := iface.taskchain_remove_subscription(service.repo, s.subscription_id, task.owner_user_id)
			if rem_ok do removed_any = true
		}
	}

	return removed_any, domain.Domain_Error{}
}

list_subscriptions :: proc(
	service: ^Taskchain_Service,
	auth: contracts.Auth_Context,
	chain_id: domain.Task_Chain_ID,
) -> ([]domain.Task_Subscription, domain.Domain_Error) {
	if service == nil || service.repo == nil {
		return nil, domain.domain_error(.Internal_Error, "taskchain service is not configured")
	}
	chain, ok, err := get_chain_for_read(service, auth, chain_id)
	if !ok do return nil, err

	return iface.taskchain_list_subscriptions_by_chain(service.repo, chain_id, chain.owner_user_id)
}

destroy_subscriptions :: proc(subs: []domain.Task_Subscription) {
	for s in subs {
		delete(s.subscription_id)
		delete(string(s.owner_user_id))
		delete(s.subscriber_agent_instance_id)
		delete(string(s.chain_id))
		delete(string(s.task_id))
		delete(s.event_type)
		delete(s.created_at)
	}
	delete(subs)
}

chain_status_string :: proc(status: domain.Task_Chain_Status) -> string {
	#partial switch status {
	case .Completed: return "completed"
	case .Cancelled: return "cancelled"
	case .Archived: return "archived"
	case .Active: return "active"
	}
	return "active"
}

build_task_status_notice :: proc(service: ^Taskchain_Service, task: domain.Task, actor_instance_id: string) -> string {
	hm := status_human_message(service, task, actor_instance_id)
	if hm != "" do return hm
	tag := "Task Status"
	verb := "updated"
	#partial switch task.status {
	case .Completed:
		tag = "Task Completed"
		verb = "completed"
	case .Cancelled:
		tag = "Task Cancelled"
		verb = "cancelled"
	case .Paused:
		tag = "Task Paused"
		verb = "paused"
	case .Validated_Good:
		tag = "Review Consensus"
		verb = "approved"
	case .Assigned:
		tag = "Task Assigned"
		verb = "assigned"
	case .Queued:
		tag = "Task Queued"
		verb = "queued"
	}
	assignee := primary_assignee_instance(task.assignee_ref_json)
	defer delete(assignee)
	actor := actor_instance_id if actor_instance_id != "" else assignee
	return build_human_readable_task_notice(service, task, actor, tag, verb, "")
}

fanout_chain_status_changed :: proc(
	service: ^Taskchain_Service,
	auth: contracts.Auth_Context,
	chain: domain.Task_Chain,
	primary_wakes: []string = nil,
) {
	if service == nil || service.repo == nil || service.bridge_command_sink.send_runtime_command == nil || service.agents == nil do return
	actor := auth.agent_instance_id if auth.kind == .Instance_Token else ""

	subs, err := iface.taskchain_list_subscriptions_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
	if err.code != .None do return
	defer destroy_subscriptions(subs)

	primary_targets := make(map[string]bool)
	defer delete(primary_targets)
	for pw in primary_wakes do primary_targets[pw] = true

	if chain.status == .Completed || chain.status == .Cancelled || chain.status == .Archived {
		members, merr := iface.taskchain_list_members_by_chain(service.repo, chain.chain_id, chain.owner_user_id)
		if merr.code == .None {
			for m in members do primary_targets[m.agent_instance_id] = true
			delete(members)
		}
	}

	title := strings.trim_space(chain.title)
	if title == "" do title = string(chain.chain_id)
	title_disp := truncate_runes(title, NOTICE_TITLE_MAX_RUNES)
	defer delete(title_disp)
	status_str := chain_status_string(chain.status)
	human_message := fmt.aprintf(`[Chain Status] Task chain "%s" (%s) status changed to %s.`, title_disp, string(chain.chain_id), status_str)
	defer delete(human_message)

	delivered := make(map[string]bool)
	defer delete(delivered)

	now := platform.clock_now(service.clock)

	for s in subs {
		if s.task_id != "" do continue
		if s.event_type != "chain_status" && s.event_type != "all" do continue

		target := strings.trim_space(s.subscriber_agent_instance_id)
		if target == "" do continue
		if target == actor do continue
		if primary_targets[target] do continue
		if delivered[target] do continue
		delivered[target] = true

		inst, inst_ok, _ := iface.agent_get_instance(service.agents, target)
		if !inst_ok || inst.bridge_id == "" do continue

		cmd_id := platform.generate_id(service.ids, "cmd_")
		b := strings.builder_make()
		strings.write_string(&b, `{"type":"notify_task_nudge","origin":"subscription","command_id":"`)
		contracts.write_json_string(&b, cmd_id)
		strings.write_string(&b, `","agent_instance_id":"`)
		contracts.write_json_string(&b, target)
		strings.write_string(&b, `","task_id":"","chain_id":"`)
		contracts.write_json_string(&b, string(chain.chain_id))
		strings.write_string(&b, `","target_instance_id":"`)
		contracts.write_json_string(&b, target)
		strings.write_string(&b, `","target_role":"subscriber","action":"chain_status_changed","message":"`)
		contracts.write_json_string(&b, human_message)
		strings.write_string(&b, `","human_message":"`)
		contracts.write_json_string(&b, human_message)
		strings.write_string(&b, `","created_at":"`)
		contracts.write_json_string(&b, now)
		strings.write_string(&b, `"}`)

		_, _ = project.bridge_command_send_runtime(service.bridge_command_sink, project.Runtime_Command{
			bridge_id = inst.bridge_id,
			command_id = cmd_id,
			body_json = strings.to_string(b),
		})
		strings.builder_destroy(&b)
	}
}

dispatch_task_subscription_nudge :: proc(
	service: ^Taskchain_Service,
	s: domain.Task_Subscription,
	task: domain.Task,
	chain: domain.Task_Chain,
	actor: string,
	human_message: string,
	now: string,
	primary_targets: ^map[string]bool,
	delivered: ^map[string]bool,
) {
	if s.event_type != "task_status" && s.event_type != "all" do return

	target := strings.trim_space(s.subscriber_agent_instance_id)
	if target == "" do return
	if target == actor do return
	if primary_targets[target] do return
	if delivered[target] do return
	delivered[target] = true

	inst, inst_ok, _ := iface.agent_get_instance(service.agents, target)
	if !inst_ok || inst.bridge_id == "" do return

	cmd_id := platform.generate_id(service.ids, "cmd_")
	b := strings.builder_make()
	strings.write_string(&b, `{"type":"notify_task_nudge","origin":"subscription","command_id":"`)
	contracts.write_json_string(&b, cmd_id)
	strings.write_string(&b, `","agent_instance_id":"`)
	contracts.write_json_string(&b, target)
	strings.write_string(&b, `","task_id":"`)
	contracts.write_json_string(&b, string(task.task_id))
	strings.write_string(&b, `","chain_id":"`)
	contracts.write_json_string(&b, string(task.chain_id))
	strings.write_string(&b, `","target_instance_id":"`)
	contracts.write_json_string(&b, target)
	strings.write_string(&b, `","target_role":"subscriber","action":"task_status_changed","task_status":"`)
	contracts.write_json_string(&b, task_status_string(task.status))
	strings.write_string(&b, `","message":"`)
	contracts.write_json_string(&b, human_message)
	strings.write_string(&b, `","human_message":"`)
	contracts.write_json_string(&b, human_message)
	strings.write_string(&b, `","created_at":"`)
	contracts.write_json_string(&b, now)
	strings.write_string(&b, `"}`)

	_, _ = project.bridge_command_send_runtime(service.bridge_command_sink, project.Runtime_Command{
		bridge_id = inst.bridge_id,
		command_id = cmd_id,
		body_json = strings.to_string(b),
	})
	strings.builder_destroy(&b)
}

fanout_task_status_changed :: proc(
	service: ^Taskchain_Service,
	auth: contracts.Auth_Context,
	task: domain.Task,
	chain: domain.Task_Chain,
	primary_wakes: []string = nil,
) {
	if service == nil || service.repo == nil || service.bridge_command_sink.send_runtime_command == nil || service.agents == nil do return
	actor := auth.agent_instance_id if auth.kind == .Instance_Token else ""

	primary_targets := make(map[string]bool)
	defer delete(primary_targets)
	for pw in primary_wakes do primary_targets[pw] = true

	assignees := extract_instances_from_ref_blob(task.assignee_ref_json)
	defer delete(assignees)
	for id in assignees do primary_targets[id] = true

	reviewers := extract_instances_from_ref_blob(task.reviewer_refs_json)
	defer delete(reviewers)
	for id in reviewers do primary_targets[id] = true

	def_reviewers := extract_instances_from_ref_blob(chain.default_reviewer_refs_json)
	defer delete(def_reviewers)
	for id in def_reviewers do primary_targets[id] = true

	if chain.coordinator_agent_instance_id != "" do primary_targets[chain.coordinator_agent_instance_id] = true

	chain_subs, _ := iface.taskchain_list_subscriptions_by_chain(service.repo, task.chain_id, task.owner_user_id)
	defer destroy_subscriptions(chain_subs)

	task_subs, _ := iface.taskchain_list_subscriptions_by_task(service.repo, task.task_id, task.owner_user_id)
	defer destroy_subscriptions(task_subs)

	human_message := build_task_status_notice(service, task, actor)
	defer delete(human_message)

	delivered := make(map[string]bool)
	defer delete(delivered)

	now := platform.clock_now(service.clock)

	for s in chain_subs {
		if s.task_id == "" {
			dispatch_task_subscription_nudge(service, s, task, chain, actor, human_message, now, &primary_targets, &delivered)
		}
	}
	for s in task_subs {
		dispatch_task_subscription_nudge(service, s, task, chain, actor, human_message, now, &primary_targets, &delivered)
	}
}
