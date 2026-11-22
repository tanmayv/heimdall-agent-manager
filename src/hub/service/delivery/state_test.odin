package delivery

import "core:mem"
import "core:testing"
import nats "odin_test:lib/nats"

@(test)
test_route_validation :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	state_scenario(t, .Validation)
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_route_refuses_incapable_bridge :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	state_scenario(t, .Incapable)
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_off1_route_does_not_check_liveness :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	state_scenario(t, .Offline_Route)
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_result_is_idempotent :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	real_scenario(t, .Idempotent)
	testing.expect_value(t, nats.shutdown(5000).status, i32(0))
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_succeeded_from_older_attempt_counts :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	real_scenario(t, .Older_Success)
	testing.expect_value(t, nats.shutdown(5000).status, i32(0))
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_retry_on_final_attempt_is_fatal :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	state_scenario(t, .Final_Retry)
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_fatal_terminates :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	real_scenario(t, .Fatal)
	testing.expect_value(t, nats.shutdown(5000).status, i32(0))
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_fatal_is_replaced_when_sink_allows :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	real_scenario(t, .Fatal_Replace)
	testing.expect_value(t, nats.shutdown(5000).status, i32(0))
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_off2_routed_delivery_is_replaced_on_disconnect :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	state_scenario(t, .Offline_Replace)
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_off2b_forwarded_delivery_is_not_replaced :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	state_scenario(t, .Offline_Forwarded)
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_off2_max_three_rounds :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	state_scenario(t, .Max_Rounds)
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_off3_expired_on_reconnect :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	state_scenario(t, .Expired_Online)
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_off5_expire_due_at_start :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	state_scenario(t, .Expired_Start)
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_incapable_bridge_gets_no_consumer :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	state_scenario(t, .Incapable_Online)
	testing.expect_value(t, nats.shutdown(5000).status, i32(0))
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_deleted_bridge_closes_deliveries :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	state_scenario(t, .Deleted)
	testing.expect_value(t, nats.shutdown(5000).status, i32(0))
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_downgraded_bridge_closes_deliveries :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	state_scenario(t, .Downgrade)
	downgrade_replace_scenario(t)
	testing.expect_value(t, nats.shutdown(5000).status, i32(0))
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_answers_are_queued_not_sent_on_caller_thread :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	state_scenario(t, .Queued)
	testing.expect_value(t, nats.shutdown(5000).status, i32(0))
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_prune_runs_when_a_delivery_becomes_final :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	state_scenario(t, .Prune)
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_prune_at_most_once_per_hour :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	state_scenario(t, .Prune_Hour)
	testing.expect_value(t, len(track.allocation_map), 0)
}
