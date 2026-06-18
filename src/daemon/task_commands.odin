package main

Task_Create_Command :: struct {
	task_id: string,
	chain_id: string,
	title: string,
	description: string,
	acceptance_criteria: string,
	priority: string,
	status: string,
	assignee_agent_instance_id: string,
	reviewer_agent_instance_id: string,
	coordinator_agent_instance_id: string,
	depends_on: string,
	created_by: string,
	author_agent_instance_id: string,
}

Task_Chain_Create_Command :: struct {
	chain_id: string,
	title: string,
	description: string,
	status: string,
	coordinator_agent_instance_id: string,
	default_reviewer_agent_instance_id: string,
	author_agent_instance_id: string,
}

Task_Status_Command :: struct {
	task_id: string,
	chain_id: string,
	status: string,
	body: string,
	author_agent_instance_id: string,
}

Task_Comment_Command :: struct {
	task_id: string,
	chain_id: string,
	body: string,
	author_agent_instance_id: string,
}

Task_Assign_Command :: struct {
	task_id: string,
	chain_id: string,
	agent_instance_id: string,
	author_agent_instance_id: string,
}

Task_Participant_Command :: struct {
	task_id: string,
	chain_id: string,
	agent_instance_id: string,
	role: string,
	author_agent_instance_id: string,
}

Task_Review_Command :: struct {
	task_id: string,
	chain_id: string,
	result: string,
	comment: string,
	author_agent_instance_id: string,
}

Task_Chain_Status_Command :: struct {
	chain_id: string,
	status: string,
	final_summary: string,
	author_agent_instance_id: string,
}
