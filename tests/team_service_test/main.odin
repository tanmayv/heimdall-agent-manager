package team_service_test

import "core:fmt"
import "core:os"
import "core:strings"
import daemon "odin_test:daemon"

main :: proc() {
	data_dir := "/tmp/heimdall-team-service-test"
	_, _, _, _ = os.process_exec(os.Process_Desc{command = []string{"rm", "-rf", data_dir}}, context.allocator)
	check(daemon.team_service_init(data_dir), "team_service_init failed")

	coding_id := daemon.team_service_create_for_chain("proj", "chain-coding", "coding", "", "coord@coding")
	check(coding_id != "", "coding team allocation failed")
	coding := daemon.team_service_show(coding_id)
	check(coding.team.status == "latent", "coding team should start latent")
	check(len(coding.members) == 4, "coding team should have four members")
	check(count_role(coding.members, "tester") == 1, "coding team should include one tester member")
	for member in coding.members {
		check(member.agent_record_id == "", "coding member should not be provisioned to an agent yet")
		check(!member.is_user_proxy, "coding member should not be user_proxy")
		if member.role_key == "coordinator" do check(member.agent_instance_id == "coord@coding", "explicit chain coordinator should bind team coordinator member")
	}

	solo_id := daemon.team_service_create_for_chain("proj", "chain-solo", "solo", "", "coord@solo")
	check(solo_id != "", "solo team allocation failed")
	solo := daemon.team_service_show(solo_id)
	check(solo.team.status == "latent", "solo team should start latent")
	check(len(solo.members) == 3, "solo team should have coordinator + worker + user_proxy members")
	check(count_role(solo.members, "coordinator") == 1, "solo team should keep a coordinator member")
	check(count_user_proxy(solo.members) == 1, "solo team should have one synthetic user_proxy")

	duplicate_solo_id := daemon.team_service_create_for_chain("proj", "chain-solo", "coding", "different-name", "other@solo")
	check(duplicate_solo_id == solo_id, "second create for a chain must return the existing team")
	check(len(daemon.team_service_list("proj", "")) == 2, "second create for a chain must not create another team")

	teams := daemon.team_service_list("proj", "latent")
	check(len(teams) == 2, "list should return both latent teams for project")
	check(daemon.team_service_archive(coding_id, "unit-test"), "archive failed")
	archived := daemon.team_service_show(coding_id)
	check(archived.team.status == "archived", "archive should set team status")
	check(!daemon.team_service_archive("missing-team", "unit-test"), "archive should fail for missing team")

	// user_proxy reviewer flow: operator smart-reply LGTM is recorded as the
	// synthetic user_proxy review and auto-approves the review_ready task.
	daemon.chat_store_init(data_dir)
	daemon.task_store_init(data_dir)
	chain_res := daemon.task_service_create_chain(daemon.Task_Chain_Create_Command{chain_id = "chain-proxy", project_id = "proj", kind = "solo", title = "Proxy chain", coordinator_agent_instance_id = "coord@solo", author_agent_instance_id = "coord@solo"})
	check(chain_res.ok, "proxy chain create failed")
	proxy_team := daemon.team_service_show("team-chain-proxy")
	proxy_worker := member_agent_instance_id(proxy_team.members, "worker")
	check(proxy_worker != "", "proxy worker team member missing")
	task_res := daemon.task_service_create_task(daemon.Task_Create_Command{chain_id = "chain-proxy", title = "Proxy reviewed task", status = "in_progress", assignee_agent_instance_id = proxy_worker, reviewer_agent_instance_id = "user_proxy", author_agent_instance_id = "coord@solo", created_by = "coord@solo"})
	check(task_res.ok, "proxy task create failed")
	task_id := daemon.extract_json_string(task_res.message, "task_id", "")
	check(task_id != "", "proxy task id missing")
	done_res := daemon.task_service_set_status(task_id, "chain-proxy", "review_ready", "ready for user review", "worker@solo")
	check(done_res.ok, "proxy task review_ready failed")
	ordinary_chat := daemon.task_service_user_proxy_review_reply("operator@local", "coord@solo", "LGTM, but also check X")
	check(!ordinary_chat.ok, "ordinary coordinator chat must not be consumed as user_proxy vote")
	vote_builder := strings.builder_make()
	strings.write_string(&vote_builder, `{"action":"user_proxy_review","task_id":"`)
	strings.write_string(&vote_builder, task_id)
	strings.write_string(&vote_builder, `","result":"lgtm"}`)
	vote_res := daemon.task_service_user_proxy_review_reply("operator@local", "coord@solo", strings.to_string(vote_builder))
	check(vote_res.ok, "operator user_proxy LGTM failed")
	check(daemon.extract_json_string(vote_res.message, "status", "") == "approved", "operator user_proxy LGTM should approve task")
}

member_agent_instance_id :: proc(members: []daemon.Team_Member_Record, role_key: string) -> string {
	for member in members {
		if member.role_key == role_key do return member.agent_instance_id
	}
	return ""
}

count_user_proxy :: proc(members: []daemon.Team_Member_Record) -> int {
	count := 0
	for member in members {
		if member.is_user_proxy do count += 1
	}
	return count
}

count_role :: proc(members: []daemon.Team_Member_Record, role_key: string) -> int {
	count := 0
	for member in members {
		if member.role_key == role_key do count += 1
	}
	return count
}

check :: proc(ok: bool, message: string) {
	if ok do return
	fmt.eprintln(message)
	os.exit(1)
}
