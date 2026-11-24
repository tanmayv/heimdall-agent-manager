package domain

Event_Webhook :: struct {
 webhook_id, owner_user_id, name: string,
 token_hash: string `json:"-"`,
 enabled: bool,
 created_at, updated_at, last_received_at: string,
}
event_webhook_destroy :: proc(row: ^Event_Webhook) {
 delete(row.webhook_id); delete(row.owner_user_id); delete(row.name); delete(row.token_hash)
 delete(row.created_at); delete(row.updated_at); delete(row.last_received_at)
 row^={}
}
event_webhooks_destroy :: proc(rows: []Event_Webhook) {
 for &row in rows do event_webhook_destroy(&row)
 delete(rows)
}
