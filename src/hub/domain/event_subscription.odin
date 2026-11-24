package domain

// Delivery metadata is bounded independently of the JetStream backlog.
EVENT_DELIVERY_LIMIT :: 4096
EVENT_ACK_RECEIPT_LIMIT :: 256

// Repository reads own these strings. A subscription belongs to one agent
// instance (subscriber_instance_id, REQ-EVP-1); the API never accepts a
// subscriber id from its caller but uses the authenticated instance.
// subscriber_agent_id records that instance's durable agent for display only;
// nothing is keyed on it.
Event_Subscription :: struct {
	subscription_id, owner_user_id, subscriber_instance_id, subscriber_agent_id: string,
	chain_id, task_id, source, filter_subjects, wake_policy:                     string,
	consumer_name, created_at:                                                   string,
}

event_subscription_destroy :: proc(row: ^Event_Subscription) {
	delete(row.subscription_id); delete(row.owner_user_id)
	delete(row.subscriber_instance_id); delete(row.subscriber_agent_id); delete(row.chain_id); delete(row.task_id)
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

// Small owned snapshot; notification decisions reuse persisted runtime activity.
Event_Notice_Target :: struct {
	instance_id, bridge_id, runtime_status, activity_status, stopped_by: string,
	is_bot: bool,
}
event_notice_target_destroy :: proc(t: ^Event_Notice_Target) {
	delete(t.instance_id); delete(t.bridge_id); delete(t.runtime_status)
	delete(t.activity_status); delete(t.stopped_by); t^ = {}
}

// One row per subscription from a single target/delivery snapshot.
Event_Notice_Snapshot :: struct {
	subscription_id: string,
	target: Event_Notice_Target,
	oldest_delivery: string,
	outstanding: i64,
}
event_notice_snapshot_destroy :: proc(row: ^Event_Notice_Snapshot) {
	delete(row.subscription_id); delete(row.oldest_delivery)
	event_notice_target_destroy(&row.target)
	row^ = {}
}

// Owned chain invalidation returned in increasing revision order.
Event_Inbox_Change :: struct {
 owner_user_id, chain_id: string,
 revision: i64,
}
