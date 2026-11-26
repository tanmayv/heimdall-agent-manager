package mcp

// Fixed field order is also the retry digest's canonical representation, so
// new keys are appended. `roles` stays only so chains.configure can refuse it
// with fleet_roles_removed (REQ-SCHED-8); `paused` is the row's pause switch;
// `max_parallel` and `review_reserve` are the chain cap (REQ-SCHED-34).
TASK_TOOL_KEYS :: [?]string{"chain_id","task_id","request_id","expected_revision","action","title","description","goal","reason","assignee_agent_id","bridge_id","provider","model","provider_profile","acceptance","reviewers","depends_on","roles","capacity","requires_user_approval","agent_id","priority","paused","max_parallel","review_reserve"}
Task_Tool_Arguments :: struct {
	chain_id,task_id,request_id,expected_revision,action,title,description,goal,reason,assignee_agent_id,bridge_id,provider,model,provider_profile,agent_id,priority:string,
	acceptance,reviewers,depends_on,roles:[]string,
	capacity,max_parallel,review_reserve:int,
	requires_user_approval,paused:bool,
	present:u64,
}
task_argument_present :: proc(args:Task_Tool_Arguments,key:string)->bool {
	for known,i in TASK_TOOL_KEYS do if known==key do return args.present & (u64(1)<<u64(i))!=0
	return false
}
