package iface

import domain "odin_test:hub/domain"

// All operations require the caller's unit of work. Inputs are borrowed;
// returned rows and slices belong to context.allocator (domain.pipeline_*_destroy).
Pipeline_Delivery_Repository :: struct {
	ctx:             rawptr,
	insert:          proc(ctx: rawptr, d: domain.Pipeline_Delivery) -> domain.Domain_Error,
	get:             proc(ctx: rawptr, delivery_id: string) -> (domain.Pipeline_Delivery, bool, domain.Domain_Error),
	awaiting_read:   proc(ctx: rawptr, message_id: string) -> ([]domain.Pipeline_Delivery, domain.Domain_Error),
	transition:      proc(
		ctx: rawptr,
		next: domain.Pipeline_Delivery,
		from_state: string,
	) -> (
		bool,
		domain.Domain_Error,
	),
	open_for_bridge: proc(
		ctx: rawptr,
		bridge_id, state_filter: string,
		limit: int,
	) -> (
		[]domain.Pipeline_Delivery,
		domain.Domain_Error,
	),
	open_by_ref:     proc(ctx: rawptr, ref: string) -> (domain.Pipeline_Delivery, bool, domain.Domain_Error),
	in_flight:       proc(ctx: rawptr, bridge_id, since: string) -> (int, domain.Domain_Error),
	expired:         proc(ctx: rawptr, now: string, limit: int) -> ([]domain.Pipeline_Delivery, domain.Domain_Error),
	prune:           proc(ctx: rawptr, cutoff: string) -> domain.Domain_Error,
}
