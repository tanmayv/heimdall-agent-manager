package iface

import domain "odin_test:hub/domain"

// All calls require the caller's UoW. put borrows row; list transfers its
// array and strings to the caller. Remove is scoped to both tenant and agent.
Event_Subscription_Repository :: struct {
	ctx:           rawptr,
	owns_chain:    proc(ctx: rawptr, owner, chain: string) -> (bool, domain.Domain_Error),
	all:           proc(ctx: rawptr) -> ([]domain.Event_Subscription, domain.Domain_Error),
	deliveries:    proc(
		ctx: rawptr,
		owner, agent: string,
		include_acknowledged: bool,
	) -> (
		[]domain.Event_Delivery,
		domain.Domain_Error,
	),
	delivered:     proc(ctx: rawptr, owner, agent: string, row: domain.Event_Delivery) -> domain.Domain_Error,
	mark_delivery: proc(ctx: rawptr, owner, agent, subscription, event: string, resolved: bool) -> domain.Domain_Error,
	stale:         proc(ctx: rawptr, owner, topic: string, generation: i64) -> (bool, domain.Domain_Error),
	deletions:     proc(ctx: rawptr) -> ([]string, domain.Domain_Error),
	deleted:       proc(ctx: rawptr, consumer: string) -> domain.Domain_Error,
	put:           proc(ctx: rawptr, row: domain.Event_Subscription) -> domain.Domain_Error,
	list:          proc(ctx: rawptr, owner, agent: string) -> ([]domain.Event_Subscription, domain.Domain_Error),
	remove:        proc(ctx: rawptr, owner, agent, subscription_id: string) -> domain.Domain_Error,
}
