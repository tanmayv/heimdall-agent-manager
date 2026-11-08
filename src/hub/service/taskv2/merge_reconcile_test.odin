package taskv2

import "core:testing"

// F1: the first merge conflict (since the last successful merge) is answered
// automatically with a reconcile attempt; a repeat conflict stays parked for
// the coordinator.
@(test)
test_merge_conflict_auto_reconcile_is_bounded :: proc(t: ^testing.T) {
	fx, log, ok := lease_fixture(t, "merge_auto")
	defer lease_fixture_close(fx, log)
	if !ok do return
	chain := seed_live_chain(t, fx, "chain_merge_auto")
	task := publish_task(t, fx, chain, "task_1")
	_, _, _ = append_event(&fx.repo, &fx.clock, task, hub_actor(), EV_MERGE_CONFLICT, `{"branch":"b"}`)
	testing.expect(t, merge_conflict_auto_reconcile_allowed(&fx.svc, task), "first conflict auto-reconciles")
	_, _, _ = append_event(&fx.repo, &fx.clock, task, hub_actor(), EV_ANSWERED, `{"auto":true}`)
	_, _, _ = append_event(&fx.repo, &fx.clock, task, hub_actor(), EV_MERGE_CONFLICT, `{"branch":"b"}`)
	testing.expect(t, !merge_conflict_auto_reconcile_allowed(&fx.svc, task), "a repeat conflict stays parked for the coordinator")
	_, _, _ = append_event(&fx.repo, &fx.clock, task, hub_actor(), EV_MERGED, `{"branch":"b"}`)
	_, _, _ = append_event(&fx.repo, &fx.clock, task, hub_actor(), EV_MERGE_CONFLICT, `{"branch":"b"}`)
	testing.expect(t, merge_conflict_auto_reconcile_allowed(&fx.svc, task), "a successful merge resets the bound")
}
