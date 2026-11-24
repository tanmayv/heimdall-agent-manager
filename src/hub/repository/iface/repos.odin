package iface

Repositories :: struct {
 webhooks: Event_Webhook_Repository,
	pipeline_deliveries: Pipeline_Delivery_Repository,
	bots: Bot_Repository,
 event_subscriptions: Event_Subscription_Repository,
	event_outbox: Event_Outbox_Repository,
	users: User_Repository,
	bridges: Bridge_Repository,
	agents: Agent_Repository,
	projects: Project_Repository,
	content: Content_Repository,
	taskchains: Taskchain_Repository,
	search: Search_Repository,
	actions: Action_Repository,
	push_subscriptions: Push_Repository,
	cards: Card_Repository,
	issues: Issue_Repository,
	attention: Attention_Repository,
}
