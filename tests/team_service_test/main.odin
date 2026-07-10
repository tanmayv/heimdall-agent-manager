package team_service_test

import "core:fmt"
import "core:os"
import daemon "odin_test:daemon"

main :: proc() {
	data_dir := "/tmp/heimdall-team-service-test"
	_, _, _, _ = os.process_exec(os.Process_Desc{command = []string{"rm", "-rf", data_dir}}, context.allocator)
	check(daemon.team_service_init(data_dir), "team_service_init failed")

	coding_id := daemon.team_service_create_for_chain("proj", "chain-coding", "coding", "")
	check(coding_id != "", "coding team allocation failed")
	coding := daemon.team_service_show(coding_id)
	check(coding.team.status == "latent", "coding team should start latent")
	check(len(coding.members) == 3, "coding team should have three members")
	for member in coding.members {
		check(member.agent_record_id == "", "coding member should not be provisioned to an agent yet")
		check(!member.is_user_proxy, "coding member should not be user_proxy")
	}

	solo_id := daemon.team_service_create_for_chain("proj", "chain-solo", "solo", "")
	check(solo_id != "", "solo team allocation failed")
	solo := daemon.team_service_show(solo_id)
	check(solo.team.status == "latent", "solo team should start latent")
	check(len(solo.members) == 3, "solo team should have coordinator + worker + user_proxy members")
	check(count_role(solo.members, "coordinator") == 1, "solo team should keep a coordinator member")
	check(count_user_proxy(solo.members) == 1, "solo team should have one synthetic user_proxy")

	duplicate_solo_id := daemon.team_service_create_for_chain("proj", "chain-solo", "coding", "different-name")
	check(duplicate_solo_id == solo_id, "second create for a chain must return the existing team")
	check(len(daemon.team_service_list("proj", "")) == 2, "second create for a chain must not create another team")

	teams := daemon.team_service_list("proj", "latent")
	check(len(teams) == 2, "list should return both latent teams for project")
	check(daemon.team_service_archive(coding_id, "unit-test"), "archive failed")
	archived := daemon.team_service_show(coding_id)
	check(archived.team.status == "archived", "archive should set team status")
	check(!daemon.team_service_archive("missing-team", "unit-test"), "archive should fail for missing team")
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
