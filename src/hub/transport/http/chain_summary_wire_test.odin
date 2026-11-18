package http

// REQ-OVF-3: summary reads are read-only, default to the caller's chain, return
// the summary metadata (including the overflow latch) and stay owner-scoped.

import "core:fmt"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

@(private = "file")
summary_get_request :: proc(f: ^wire_fixture, body: string) -> Request {
	return Request{
		method      = "POST",
		path        = "/api/v1/agent-actions/chain/summary/get",
		body        = body,
		request_id  = "req_wire_summary",
		remote_addr = "127.0.0.1:4444",
		headers     = f.agent_headers[:],
	}
}

@(test)
test_chain_summary_get_read_only_default_chain_and_owner_scope :: proc(t: ^testing.T) {
	f := wire_setup(t, "summary_get")
	defer wire_teardown(f)

	_, saved, _ := iface.taskchain_save_chain_summary(&f.tc_repo, domain.Chain_Summary{
		chain_id = f.chain_id, owner_user_id = f.owner, body = "# Chain\nCurated", line_count = 2,
		version = 7, updated_at = "2026-11-18T00:00:00Z", overflow_active = true,
	})
	testing.expect(t, saved, "summary fixture saved")

	// Default chain: no chain_id -> the caller instance's chain, with metadata.
	resp := agent_action_chain_summary_get_handler(&f.ah, summary_get_request(f, `{"params":{}}`))
	testing.expect_value(t, resp.status, 200)
	for want in ([]string{fmt.tprintf(`"chain_id":"%s"`, f.chain_id), `"summary":"# Chain\nCurated"`, `"line_count":2`, `"max_lines":60`, `"overflow_active":true`, `"version":7`, `"updated_at":"2026-11-18T00:00:00Z"`}) {
		testing.expectf(t, strings.contains(resp.body, want), "get response carries %s: %s", want, resp.body)
	}

	// Read-only: write-shaped params are ignored and nothing is stored.
	write_shaped := strings.concatenate({`{"params":{"chain_id":"`, string(f.chain_id), `","summary":"get","body":"get"}}`})
	defer delete(write_shaped)
	ro := agent_action_chain_summary_get_handler(&f.ah, summary_get_request(f, write_shaped))
	testing.expect_value(t, ro.status, 200)
	after, _, _ := iface.taskchain_get_chain_summary(&f.tc_repo, f.chain_id, f.owner)
	testing.expect_value(t, after.body, "# Chain\nCurated")
	testing.expect_value(t, after.version, 7)
	testing.expect(t, after.overflow_active, "latch untouched by a read")

	// A same-owner chain without a summary row reads as empty, version 0.
	other := domain.Task_Chain_ID("chain_wire_summary_empty")
	_, _, _ = iface.taskchain_save_chain(&f.tc_repo, domain.Task_Chain{
		chain_id = other, owner_user_id = f.owner, title = "empty", publish_state = .Draft, status = .Active,
		kind = domain.CHAIN_KIND_MIXED_WORK, created_at = "2026-09-25T10:00:00Z", updated_at = "2026-09-25T10:00:00Z",
	})
	empty_body := strings.concatenate({`{"params":{"chain_id":"`, string(other), `"}}`})
	defer delete(empty_body)
	empty := agent_action_chain_summary_get_handler(&f.ah, summary_get_request(f, empty_body))
	testing.expect_value(t, empty.status, 200)
	testing.expectf(t, strings.contains(empty.body, `"summary":""`) && strings.contains(empty.body, `"version":0`) && strings.contains(empty.body, `"overflow_active":false`), "empty summary read: %s", empty.body)

	// Owner isolation: another owner's chain is not found, and its row is not leaked.
	other_owner := domain.Task_Chain_ID("chain_wire_summary_foreign")
	_, _, _ = iface.taskchain_save_chain(&f.tc_repo, domain.Task_Chain{
		chain_id = other_owner, owner_user_id = "wire_foreign_owner", title = "other_owner", publish_state = .Draft, status = .Active,
		kind = domain.CHAIN_KIND_MIXED_WORK, created_at = "2026-09-25T10:00:00Z", updated_at = "2026-09-25T10:00:00Z",
	})
	_, _, _ = iface.taskchain_save_chain_summary(&f.tc_repo, domain.Chain_Summary{chain_id = other_owner, owner_user_id = "wire_foreign_owner", body = "secret", updated_at = "2026-11-18T00:00:00Z"})
	other_owner_body := strings.concatenate({`{"params":{"chain_id":"`, string(other_owner), `"}}`})
	defer delete(other_owner_body)
	denied := agent_action_chain_summary_get_handler(&f.ah, summary_get_request(f, other_owner_body))
	testing.expect_value(t, denied.status, 404)
	testing.expect(t, !strings.contains(denied.body, "secret"), "other_owner summary body is never returned")

	// Unauthenticated: no agent headers -> rejected before any read.
	anon := summary_get_request(f, `{"params":{}}`)
	anon.headers = nil
	testing.expect(t, agent_action_chain_summary_get_handler(&f.ah, anon).status == 401, "missing credentials rejected")

	// Cookie GET route returns the same metadata for the owner.
	cookie := get_task_chain_summary_handler(&f.th, wire_cookie_request(f, "GET", fmt.tprintf("/api/v1/task-chains/%s/summary", f.chain_id), ""))
	testing.expect_value(t, cookie.status, 200)
	testing.expectf(t, strings.contains(cookie.body, `"overflow_active":true`) && strings.contains(cookie.body, `"max_lines":60`), "cookie GET metadata: %s", cookie.body)
}
