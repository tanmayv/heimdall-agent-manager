package domain

Task_Subscription :: struct {
	subscription_id:              string,
	owner_user_id:                User_ID,
	subscriber_agent_instance_id: string,
	chain_id:                     Task_Chain_ID,
	task_id:                      Task_ID,
	event_type:                   string,
	created_at:                   string,
}
