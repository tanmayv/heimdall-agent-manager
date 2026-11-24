package domain

DELIVERY_KIND_PROMPT :: "prompt"
DELIVERY_KIND_NOTICE :: "notice"
DELIVERY_KIND_BOT :: "bot"
DELIVERY_KIND_LEASE :: "lease"
DELIVERY_ROUTED :: "routed"
DELIVERY_FORWARDED :: "forwarded"
DELIVERY_DELIVERED :: "delivered"
DELIVERY_DONE :: "done"
DELIVERY_FAILED :: "failed"
DELIVERY_REPLACED :: "replaced"
DELIVERY_MAX_ROUNDS :: 3

Pipeline_Delivery :: struct {
	delivery_id, owner_user_id, kind, bridge_id, agent_instance_id, ref, message_id: string,
	state, outcome, reason:                                                          string,
	round:                                                                           int,
	excluded_bridges_json:                                                           string,
	attempt:                                                                         int,
	ack_reply:                                                                       string,
	stream_sequence:                                                                 i64,
	retry_at, expires_at, created_at, forwarded_at, updated_at:                      string,
}

pipeline_delivery_open :: proc(state: string) -> bool {
	return state == DELIVERY_ROUTED || state == DELIVERY_FORWARDED
}

pipeline_delivery_destroy :: proc(d: ^Pipeline_Delivery) {
	if d == nil do return
	delete(d.delivery_id); delete(d.owner_user_id); delete(d.kind)
	delete(d.bridge_id); delete(d.agent_instance_id); delete(d.ref); delete(d.message_id)
	delete(d.state); delete(d.outcome); delete(d.reason); delete(d.excluded_bridges_json)
	delete(d.ack_reply); delete(d.retry_at); delete(d.expires_at)
	delete(d.created_at); delete(d.forwarded_at); delete(d.updated_at)
	d^ = {}
}

pipeline_deliveries_destroy :: proc(rows: []Pipeline_Delivery) {
	for &d in rows do pipeline_delivery_destroy(&d)
	delete(rows)
}
