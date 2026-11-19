package domain

// Delivery metadata is bounded independently of the JetStream backlog.
EVENT_DELIVERY_LIMIT :: 4096
EVENT_ACK_RECEIPT_LIMIT :: 256

// Repository reads own these strings; the API never accepts a subscriber id
// from its caller, but derives it from the authenticated durable identity.
Event_Subscription :: struct {
	subscription_id, owner_user_id, subscriber_agent_id, chain_id, task_id: string,
	source, filter_subjects, wake_policy, consumer_name, created_at:        string,
}

event_subscription_destroy :: proc(row: ^Event_Subscription) {
	delete(row.subscription_id); delete(row.owner_user_id)
	delete(row.subscriber_agent_id); delete(row.chain_id); delete(row.task_id)
	delete(row.source); delete(row.filter_subjects); delete(row.wake_policy)
	delete(row.consumer_name); delete(row.created_at)
	row^ = {}
}

Event_Delivery :: struct {
	subscription_id, event_id, ack_reply, topic_key: string,
	topic_generation, stream_sequence:               i64,
	acknowledged, resolved_sent:                     bool,
}
event_delivery_destroy :: proc(row: ^Event_Delivery) {
	delete(row.subscription_id); delete(row.event_id)
	delete(row.ack_reply); delete(row.topic_key)
	row^ = {}
}
