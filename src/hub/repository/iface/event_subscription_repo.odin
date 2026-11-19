package iface

import domain "odin_test:hub/domain"

// All calls require the caller's UoW. put borrows row; list transfers its
// array and strings to the caller. Remove is scoped to both tenant and agent.
Event_Subscription_Repository :: struct {
 ctx: rawptr,
 put: proc(ctx: rawptr, row: domain.Event_Subscription) -> domain.Domain_Error,
 list: proc(ctx: rawptr, owner, agent: string) -> ([]domain.Event_Subscription, domain.Domain_Error),
 remove: proc(ctx: rawptr, owner, agent, subscription_id: string) -> domain.Domain_Error,
}
