package domain

// Feature code consumes these account-scoped parameters, never a plan ID.
User_Entitlements :: struct {
	max_bridges: int,
	terminal_streaming_enabled: bool,
}

Billing_Plan :: struct {
	plan_id: string,
	plan_label: string,
	price_id: string,
	entitlements: User_Entitlements,
}

Account_Billing :: struct {
	user_id: string,
	plan_id: string,
	plan_label: string,
	status: string,
	customer_id: string,
	subscription_id: string,
	price_id: string,
	renews_at: string,
	cancels_at: string,
	grace_until: string,
	last_event_ns: i64,
	entitlements: User_Entitlements,
	checkout_pending: bool,
	created_at: string,
	updated_at: string,
}

Billing_Checkout :: struct {
	reference: string,
	user_id: string,
	plan_id: string,
	price_id: string,
	transaction_id: string,
	expires_at: string,
}

Billing_Event :: struct {
	event_id: string,
	event_type: string,
	occurred_ns: i64,
	checkout_reference: string,
	subscription_id: string,
	customer_id: string,
	price_id: string,
	status: string,
	renews_at: string,
	cancels_at: string,
	grace_until: string,
}
