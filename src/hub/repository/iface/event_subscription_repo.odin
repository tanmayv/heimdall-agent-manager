package iface

import domain "odin_test:hub/domain"

// All calls require the caller's UoW. put borrows row; list transfers its
// array and strings to the caller. Every subscriber-scoped call takes the owner
// and the subscriber INSTANCE id (REQ-EVP-1/4c); no call reads another
// instance's subscriptions, even one of the same durable agent.
Event_Subscription_Repository :: struct {
	ctx:           rawptr,
	by_owner: proc(ctx: rawptr, owner: string) -> ([]domain.Event_Subscription, domain.Domain_Error),
	// Returns the canonical bot identity for this owned instance, or empty.
	bot_agent: proc(ctx: rawptr, owner, instance: string) -> (string, domain.Domain_Error),
	// The owning instance only (REQ-EVP-4a); empty when it no longer exists.
	notice_target: proc(ctx: rawptr, row: domain.Event_Subscription) -> (domain.Event_Notice_Target, domain.Domain_Error),
	due_deliveries: proc(ctx: rawptr, owner, instance, subscription, before: string) -> ([]domain.Event_Delivery, domain.Domain_Error),
	owns_chain:    proc(ctx: rawptr, owner, chain: string) -> (bool, domain.Domain_Error),
	all:           proc(ctx: rawptr) -> ([]domain.Event_Subscription, domain.Domain_Error),
	// ids must contain 1..100 ids; lookup uses the event-id index.
	deliveries:    proc(
		ctx: rawptr,
		owner, instance: string,
		ids: []string,
	) -> (
		[]domain.Event_Delivery,
		domain.Domain_Error,
	),
	// One joined query returns only stale previously-delivered topics.
	resolutions:   proc(
		ctx: rawptr,
		owner, instance: string,
		limit: int,
	) -> (
		[]domain.Event_Delivery,
		domain.Domain_Error,
	),
	exists:        proc(ctx: rawptr, owner, instance, subscription: string) -> (bool, domain.Domain_Error),
	available:     proc(ctx: rawptr, owner, instance, subscription: string) -> (int, domain.Domain_Error),
	queue_delete:  proc(ctx: rawptr, consumer: string) -> domain.Domain_Error,
	prune:         proc(ctx: rawptr, before: string) -> domain.Domain_Error,
	delivered:     proc(ctx: rawptr, owner, instance: string, row: domain.Event_Delivery) -> domain.Domain_Error,
	mark_delivery: proc(ctx: rawptr, owner, instance, subscription, event: string, resolved: bool) -> domain.Domain_Error,
	stale:         proc(ctx: rawptr, owner, topic: string, generation: i64) -> (bool, domain.Domain_Error),
	deletions:     proc(ctx: rawptr) -> ([]string, domain.Domain_Error),
	deleted:       proc(ctx: rawptr, consumer: string) -> domain.Domain_Error,
	put:           proc(ctx: rawptr, row: domain.Event_Subscription) -> domain.Domain_Error,
	list:          proc(ctx: rawptr, owner, instance: string) -> ([]domain.Event_Subscription, domain.Domain_Error),
	remove:        proc(ctx: rawptr, owner, instance, subscription_id: string) -> domain.Domain_Error,
}
