package main

import "base:runtime"
import "core:sync"
import "core:testing"
import contracts "odin_test:contracts"

// cs_seed_terminal_receipt plants the receipt a rejected refresh leaves behind:
// Waiting_Repair / unauthenticated / recoverable, last attempt at last_wall_ms.
@(private = "file")
cs_seed_terminal_receipt :: proc(key: string, last_wall_ms: i64) {
	sync.mutex_lock(&bridge_retry_journal_mutex)
	defer sync.mutex_unlock(&bridge_retry_journal_mutex)
	b := bridge_retry_journal_get_locked(key)
	if b == nil do return
	b^ = {state = .Waiting_Repair, attempts = 2, first_ms = last_wall_ms - 4000, deadline_ms = last_wall_ms + 116_000, last_wall_ms = last_wall_ms, code = .Unauthenticated, class = .recoverable}
}

// Re-enrolling with --reuse-bridge keeps the journal key refresh:<hub>:<bridge_id>.
// The receipt the REJECTED credential earned must not stop renewal of the new one.
@(test)
test_reenrolled_credential_ignores_older_terminal_refresh_receipt :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	context.allocator = runtime.heap_allocator()
	f := cs_setup("reenroll_receipt"); defer cs_teardown(f)
	cs_seed_terminal_receipt(f.env.key, CS_T0_WALL - 3600_000) // the old credential's failure, an hour before issue
	outcome, _ := cs_drive(f)
	testing.expect_value(t, outcome, Bridge_Renewal_Outcome.Published)
	testing.expect_value(t, cs_hub.exchanges, 1)
	phase, _ := bridge_credential_phase()
	testing.expect_value(t, phase, Bridge_Credential_Phase.Valid)
	_ = bridge_retry_operator_resume_sync(f.env.key, refresh = true)
}

// A terminal receipt earned by the CURRENT credential still stops renewal: the
// fix only forgets receipts about a credential that no longer exists.
@(test)
test_terminal_refresh_receipt_for_current_credential_still_stops :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	context.allocator = runtime.heap_allocator()
	f := cs_setup("current_receipt"); defer cs_teardown(f)
	cs_seed_terminal_receipt(f.env.key, CS_T0_WALL + 1000) // failed after this credential was issued
	outcome, _ := cs_drive(f)
	testing.expect_value(t, outcome, Bridge_Renewal_Outcome.Renewal_Stopped)
	testing.expect_value(t, cs_hub.exchanges, 0)
	_, reason := bridge_credential_phase()
	testing.expect_value(t, reason, "refresh_receipt_terminal")
	_ = bridge_retry_operator_resume_sync(f.env.key, refresh = true)
}

// Without a known issue time (no metadata) nothing can prove the receipt is stale.
@(test)
test_terminal_refresh_receipt_kept_when_issue_time_unknown :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex); defer sync.mutex_unlock(&bridge_test_config_mutex)
	context.allocator = runtime.heap_allocator()
	f := cs_setup("unknown_issue"); defer cs_teardown(f)
	g_bridge_cred.known = false
	g_bridge_cred.issued_wall_ms = 0
	b := Bridge_Operation_Budget{state = .Waiting_Repair, last_wall_ms = CS_T0_WALL - 3600_000, code = contracts.Error_Code.Unauthenticated, class = .recoverable}
	testing.expect(t, !bridge_refresh_receipt_predates_credential(b), "unknown issue time never discards a receipt")
}
