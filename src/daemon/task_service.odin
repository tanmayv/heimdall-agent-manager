package main

import "core:fmt"
import "core:strings"

Task_Service_Result :: struct {
	ok: bool,
	status_code: int,
	message: string,
}

task_service_create_task :: proc(cmd: Task_Create_Command) -> Task_Service_Result {
	if cmd.task_id == "" || cmd.title == "" do return Task_Service_Result{ok = false, status_code = 400, message = `{"ok":false,"message":"task create requires task_id and title"}`}
	status := cmd.status
	if status == "" do status = "pending"
	priority := cmd.priority
	if priority == "" do priority = "normal"
	event := Task_Event{kind = .Task_Created, task_id = cmd.task_id, chain_id = cmd.chain_id, title = cmd.title, description = cmd.description, acceptance_criteria = cmd.acceptance_criteria, priority = priority, status = status, assignee_agent_instance_id = cmd.assignee_agent_instance_id, reviewer_agent_instance_id = cmd.reviewer_agent_instance_id, coordinator_agent_instance_id = cmd.coordinator_agent_instance_id, depends_on = cmd.depends_on, created_by = cmd.created_by, author_agent_instance_id = cmd.author_agent_instance_id}
	if !task_store_append_event(event) do return Task_Service_Result{ok = false, status_code = 500, message = `{"ok":false,"message":"append task create failed"}`}
	task_notify_event(event)
	return Task_Service_Result{ok = true, status_code = 200, message = `{"ok":true}`}
}

task_service_create_chain :: proc(cmd: Task_Chain_Create_Command) -> Task_Service_Result {
	if cmd.chain_id == "" || cmd.title == "" do return Task_Service_Result{ok = false, status_code = 400, message = `{"ok":false,"message":"chain create requires chain_id and title"}`}
	status := cmd.status
	if status == "" do status = "active"
	event := Task_Event{kind = .Chain_Created, chain_id = cmd.chain_id, title = cmd.title, description = cmd.description, status = status, coordinator_agent_instance_id = cmd.coordinator_agent_instance_id, default_reviewer_agent_instance_id = cmd.default_reviewer_agent_instance_id, author_agent_instance_id = cmd.author_agent_instance_id}
	if !task_store_append_event(event) do return Task_Service_Result{ok = false, status_code = 500, message = `{"ok":false,"message":"append chain create failed"}`}
	return Task_Service_Result{ok = true, status_code = 200, message = `{"ok":true}`}
}

task_service_comment :: proc(task_id, chain_id, body, author_agent_instance_id: string) -> Task_Service_Result {
	return task_service_comment_command(Task_Comment_Command{task_id = task_id, chain_id = chain_id, body = body, author_agent_instance_id = author_agent_instance_id})
}

task_service_comment_command :: proc(cmd: Task_Comment_Command) -> Task_Service_Result {
	if cmd.task_id == "" || cmd.body == "" do return Task_Service_Result{ok = false, status_code = 400, message = `{"ok":false,"message":"task comment requires task_id and body"}`}
	event := Task_Event{kind = .Task_Comment, task_id = cmd.task_id, chain_id = cmd.chain_id, body = cmd.body, author_agent_instance_id = cmd.author_agent_instance_id}
	if !task_store_append_event(event) do return Task_Service_Result{ok = false, status_code = 500, message = `{"ok":false,"message":"append task comment failed"}`}
	task_notify_event(event)
	return Task_Service_Result{ok = true, status_code = 200, message = `{"ok":true}`}
}

task_service_assign :: proc(task_id, chain_id, agent_instance_id, author_agent_instance_id: string) -> Task_Service_Result {
	return task_service_assign_command(Task_Assign_Command{task_id = task_id, chain_id = chain_id, agent_instance_id = agent_instance_id, author_agent_instance_id = author_agent_instance_id})
}

task_service_assign_command :: proc(cmd: Task_Assign_Command) -> Task_Service_Result {
	if cmd.task_id == "" || cmd.agent_instance_id == "" do return Task_Service_Result{ok = false, status_code = 400, message = `{"ok":false,"message":"task assignment requires task_id and agent_instance_id"}`}
	event := Task_Event{kind = .Task_Assigned, task_id = cmd.task_id, chain_id = cmd.chain_id, agent_instance_id = cmd.agent_instance_id, role = "assignee", author_agent_instance_id = cmd.author_agent_instance_id}
	if !task_store_append_event(event) do return Task_Service_Result{ok = false, status_code = 500, message = `{"ok":false,"message":"append task assignment failed"}`}
	task_notify_event(event)
	return Task_Service_Result{ok = true, status_code = 200, message = `{"ok":true}`}
}

task_service_add_participant :: proc(task_id, chain_id, agent_instance_id, role, author_agent_instance_id: string) -> Task_Service_Result {
	return task_service_participant_command(Task_Participant_Command{task_id = task_id, chain_id = chain_id, agent_instance_id = agent_instance_id, role = role, author_agent_instance_id = author_agent_instance_id})
}

task_service_participant_command :: proc(cmd: Task_Participant_Command) -> Task_Service_Result {
	if cmd.task_id == "" || cmd.agent_instance_id == "" || cmd.role == "" do return Task_Service_Result{ok = false, status_code = 400, message = `{"ok":false,"message":"participant requires task_id, agent_instance_id, and role"}`}
	event := Task_Event{kind = .Task_Participant_Added, task_id = cmd.task_id, chain_id = cmd.chain_id, agent_instance_id = cmd.agent_instance_id, role = cmd.role, author_agent_instance_id = cmd.author_agent_instance_id}
	if !task_store_append_event(event) do return Task_Service_Result{ok = false, status_code = 500, message = `{"ok":false,"message":"append participant failed"}`}
	task_notify_event(event)
	return Task_Service_Result{ok = true, status_code = 200, message = `{"ok":true}`}
}

task_service_set_status :: proc(task_id, chain_id, status, body, author_agent_instance_id: string) -> Task_Service_Result {
	return task_service_status_command(Task_Status_Command{task_id = task_id, chain_id = chain_id, status = status, body = body, author_agent_instance_id = author_agent_instance_id})
}

task_service_status_command :: proc(cmd: Task_Status_Command) -> Task_Service_Result {
	if cmd.task_id == "" || cmd.status == "" || strings.trim_space(cmd.body) == "" do return Task_Service_Result{ok = false, status_code = 400, message = `{"ok":false,"message":"task status change requires task_id, status, and non-empty body"}`}
	event := Task_Event{kind = .Task_Status_Changed, task_id = cmd.task_id, chain_id = cmd.chain_id, status = cmd.status, body = cmd.body, author_agent_instance_id = cmd.author_agent_instance_id}
	if !task_store_append_event(event) do return Task_Service_Result{ok = false, status_code = 500, message = `{"ok":false,"message":"append task status failed"}`}
	task_notify_event(event)
	if task_status_complete(cmd.status) do task_auto_unblock_dependents(cmd.task_id, cmd.author_agent_instance_id)
	return Task_Service_Result{ok = true, status_code = 200, message = `{"ok":true}`}
}

task_service_review :: proc(task_id, chain_id, result, comment, author_agent_instance_id: string) -> Task_Service_Result {
	return task_service_review_command(Task_Review_Command{task_id = task_id, chain_id = chain_id, result = result, comment = comment, author_agent_instance_id = author_agent_instance_id})
}

task_service_review_command :: proc(cmd: Task_Review_Command) -> Task_Service_Result {
	if cmd.task_id == "" || cmd.result == "" || strings.trim_space(cmd.comment) == "" do return Task_Service_Result{ok = false, status_code = 400, message = `{"ok":false,"message":"review requires task_id, result, and non-empty comment"}`}
	status := ""
	switch cmd.result {
	case "approved": status = "approved"
	case "needs_improvements": status = "needs_improvements"
	case "rejected": status = "rejected"
	case: return Task_Service_Result{ok = false, status_code = 400, message = `{"ok":false,"message":"review result must be approved, needs_improvements, or rejected"}`}
	}
	event := Task_Event{kind = .Task_Review_Submitted, task_id = cmd.task_id, chain_id = cmd.chain_id, status = status, body = cmd.comment, author_agent_instance_id = cmd.author_agent_instance_id}
	if !task_store_append_event(event) do return Task_Service_Result{ok = false, status_code = 500, message = `{"ok":false,"message":"append review failed"}`}
	task_notify_event(event)
	if task_status_complete(status) do task_auto_unblock_dependents(cmd.task_id, cmd.author_agent_instance_id)
	return Task_Service_Result{ok = true, status_code = 200, message = `{"ok":true}`}
}

task_service_complete_chain :: proc(chain_id, final_summary, author_agent_instance_id: string) -> Task_Service_Result {
	if chain_id == "" || strings.trim_space(final_summary) == "" do return Task_Service_Result{ok = false, status_code = 400, message = `{"ok":false,"message":"chain complete requires chain_id and non-empty summary"}`}
	return task_service_chain_status_command(Task_Chain_Status_Command{chain_id = chain_id, status = "completed", final_summary = final_summary, author_agent_instance_id = author_agent_instance_id})
}

task_service_set_chain_status :: proc(chain_id, status, final_summary, author_agent_instance_id: string) -> Task_Service_Result {
	return task_service_chain_status_command(Task_Chain_Status_Command{chain_id = chain_id, status = status, final_summary = final_summary, author_agent_instance_id = author_agent_instance_id})
}

task_service_chain_status_command :: proc(cmd: Task_Chain_Status_Command) -> Task_Service_Result {
	if cmd.chain_id == "" || cmd.status == "" do return Task_Service_Result{ok = false, status_code = 400, message = `{"ok":false,"message":"chain status requires chain_id and status"}`}
	chain_idx := task_chain_index(cmd.chain_id)
	stored_summary := task_chains[chain_idx].final_summary
	if (cmd.status == "done" || cmd.status == "archived" || cmd.status == "completed") && strings.trim_space(cmd.final_summary) == "" && stored_summary == "" {
		return Task_Service_Result{ok = false, status_code = 400, message = `{"ok":false,"message":"final_summary required"}`}
	}
	if cmd.final_summary != "" {
		task_store_append_event(Task_Event{kind = .Chain_Final_Summary_Set, chain_id = cmd.chain_id, body = cmd.final_summary, author_agent_instance_id = cmd.author_agent_instance_id})
	}
	kind := Task_Event_Kind.Chain_Status_Changed
	if cmd.status == "completed" || cmd.status == "done" do kind = .Chain_Completed
	body := cmd.final_summary
	if !task_store_append_event(Task_Event{kind = kind, chain_id = cmd.chain_id, status = cmd.status, body = body, author_agent_instance_id = cmd.author_agent_instance_id}) do return Task_Service_Result{ok = false, status_code = 500, message = `{"ok":false,"message":"append chain status failed"}`}
	archive_ok := true
	if cmd.status == "done" || cmd.status == "archived" || cmd.status == "completed" {
		archive_ok = task_archive_chain_to_hub(cmd.chain_id)
	}
	return Task_Service_Result{ok = true, status_code = 200, message = `{"ok":true,"archive_ok":true}` if archive_ok else `{"ok":true,"archive_ok":false,"archive_pending":true}`}
}

task_service_retry_pending_archives :: proc() -> Task_Service_Result {
	retried := task_store_retry_pending_archives()
	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":true,"retried":`)
	strings.write_string(&builder, fmt.tprintf("%d", retried))
	strings.write_string(&builder, `}`)
	return Task_Service_Result{ok = true, status_code = 200, message = strings.to_string(builder)}
}
