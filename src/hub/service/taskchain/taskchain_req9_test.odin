package taskchain

// REQ-SHELL-9 chain-close tests — trigger A, END TO END, through the REAL SQLite
// repositories rather than fakes.
//
// WHY REAL REPOSITORIES HERE. The service-level tests in
// src/hub/service/shell_session/shell_session_req9_test.odin drive the reap directly with
// fakes and prove what it does with the rows it is handed. They cannot prove the two
// claims that matter most about this trigger, both of which are properties of the QUERY
// and of the WIRING:
//   - that list_by_chain's kind narrowing (built from domain.SHELL_SESSION_SCOPE_RULES)
//     genuinely makes it impossible for a run or a shell to reach the reap, and
//   - that each of the three chain-close paths actually calls it.
// A fake repository would answer the first question by construction, which is to say not
// at all. So this file uses the same SQLite setup the rest of this package's tests use.
//
//   t9_auto_complete_reaps_the_chains_servers   THE PATH THAT MATTERS: quorum auto-complete
//   t9_change_chain_status_reaps                the dedicated verb
//   t9_update_chain_status_reaps                the PATCH path
//   t9_real_query_cannot_reach_a_run_or_a_shell AC3, through the real SQL
//   t9_cancelled_and_archived_also_reap         AC8
//   t9_reopening_a_chain_does_not_resurrect     the documented consequence

import "core:fmt"
import "core:os"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"
import shell_session "odin_test:hub/service/shell_session"

@(private = "file")
R9_OWNER :: "user_req9"

// --- fixture -----------------------------------------------------------------

@(private = "file")
Fx9 :: struct {
	conn:      sqlite.Conn,
	tc_impl:   sqlite.Taskchain_Repo_SQLite,
	tc_repo:   iface.Taskchain_Repository,
	ag_impl:   sqlite.Agent_Repo_SQLite,
	ag_repo:   iface.Agent_Repository,
	sh_impl:   sqlite.Shell_Session_Repo_SQLite,
	sh_repo:   iface.Shell_Session_Repository,
	shell_svc: shell_session.Shell_Session_Service,
	svc:       Taskchain_Service,
	clock:     platform.Clock,
	ids:       platform.ID_Generator,
	db_path:   string,
}

// The sink is left UNSET on purpose. With no send_runtime_command the kill cannot be
// delivered, so every reap in this file exercises the QUEUED path — which is the
// interesting one: the durable intent on the row is what the test reads, and it is what
// survives a bridge that is not there. Delivery is asserted in the service-level tests.
@(private = "file")
fx9_make :: proc(fx: ^Fx9, t: ^testing.T, name: string) -> bool {
	fx.db_path = fmt.tprintf("/tmp/test_req9_%s_%d.db", name, os.get_pid())
	os.remove(fx.db_path)

	open_ok: bool
	fx.conn, open_ok, _ = sqlite.open(fx.db_path)
	if !testing.expect(t, open_ok, "sqlite open ok") do return false
	mig_ok, _ := sqlite.run_migrations(&fx.conn)
	if !testing.expect(t, mig_ok, "migrations ok") do return false

	fx.tc_impl = sqlite.Taskchain_Repo_SQLite{conn = &fx.conn}
	fx.tc_repo = sqlite.new_taskchain_repository(&fx.tc_impl, &fx.conn)
	fx.ag_impl = sqlite.Agent_Repo_SQLite{conn = &fx.conn}
	fx.ag_repo = sqlite.new_agent_repository(&fx.ag_impl, &fx.conn)
	fx.sh_impl = sqlite.Shell_Session_Repo_SQLite{conn = &fx.conn}
	fx.sh_repo = sqlite.new_shell_session_repository(&fx.sh_impl, &fx.conn)

	fx.clock = platform.real_clock()
	fx.ids = platform.real_id_generator()
	fx.shell_svc = shell_session.new_shell_session_service(repo = &fx.sh_repo, ids = &fx.ids, clock = &fx.clock)
	fx.svc = new_taskchain_service(&fx.tc_repo, &fx.ag_repo, &fx.clock, &fx.ids)
	set_shell_session_service(&fx.svc, &fx.shell_svc)
	return true
}

@(private = "file")
fx9_free :: proc(fx: ^Fx9) {
	shell_session.shell_session_service_free(&fx.shell_svc)
	sqlite.close(&fx.conn)
	os.remove(fx.db_path)
}

@(private = "file")
fx9_chain :: proc(fx: ^Fx9, chain_id: string, status := domain.Task_Chain_Status.Active) {
	_, _, _ = iface.taskchain_save_chain(&fx.tc_repo, domain.Task_Chain{
		chain_id      = domain.Task_Chain_ID(chain_id),
		owner_user_id = domain.User_ID(R9_OWNER),
		title         = "REQ-SHELL-9 chain",
		publish_state = .Published,
		status        = status,
		kind          = "team_work",
		created_at    = "2026-09-29T10:00:00Z",
		updated_at    = "2026-09-29T10:00:00Z",
	})
}

@(private = "file")
fx9_task :: proc(fx: ^Fx9, chain_id, task_id: string, status: domain.Task_Status) {
	_, _, _ = iface.taskchain_save_task(&fx.tc_repo, domain.Task{
		task_id       = domain.Task_ID(task_id),
		chain_id      = domain.Task_Chain_ID(chain_id),
		owner_user_id = domain.User_ID(R9_OWNER),
		title         = "REQ-SHELL-9 task",
		publish_state = .Published,
		status        = status,
		created_at    = "2026-09-29T10:00:00Z",
		updated_at    = "2026-09-29T10:00:00Z",
	})
}

// fx9_session writes a row through the REAL repository, so every column the scope rules
// care about is stored and read back exactly as production would.
@(private = "file")
fx9_session :: proc(fx: ^Fx9, session_id, kind, chain_id, agent_id: string) {
	_, _ = iface.shell_session_upsert(&fx.sh_repo, domain.Shell_Session{
		session_id        = session_id,
		owner_user_id     = R9_OWNER,
		bridge_id         = "brg_req9",
		chain_id          = chain_id,
		agent_instance_id = agent_id,
		kind              = kind,
		cmd               = "npm run dev",
		status            = domain.Shell_Session_Status_Running,
		started_at        = "2026-09-29T10:00:00Z",
		created_at        = "2026-09-29T10:00:00Z",
	})
}

// fx9_intent reads the durable kill intent back off the row. Non-empty means the reap
// recorded a kill that the reconnect replay will deliver.
@(private = "file")
fx9_intent :: proc(fx: ^Fx9, session_id: string) -> string {
	s, found, _ := iface.shell_session_get(&fx.sh_repo, R9_OWNER, session_id)
	if !found do return "<missing>"
	defer domain.shell_session_destroy(s)
	// Cloned into the temp allocator: the row is destroyed above, and the caller only
	// ever compares the value.
	return fmt.tprintf("%s", s.kill_requested_at)
}

@(private = "file")
fx9_auth :: proc() -> contracts.Auth_Context {
	return contracts.Auth_Context{kind = .User_Token, user_id = R9_OWNER}
}

// --- tests -------------------------------------------------------------------

// THE PATH THAT MATTERS. sync_chain_status_from_tasks is the quorum auto-complete: the
// last task goes terminal, the chain completes, and nobody called a status verb. It is
// how a chain finishes in the normal case, and it is the path REQ-SHELL-9's description
// did not name — hooking only the two manual verbs would have shipped a feature that
// passes its tests and reaps nothing in production.
@(test)
t9_auto_complete_reaps_the_chains_servers :: proc(t: ^testing.T) {
	fx: Fx9
	if !fx9_make(&fx, t, "auto") do return
	defer fx9_free(&fx)

	fx9_chain(&fx, "chain_auto")
	fx9_task(&fx, "chain_auto", "task_1", .Completed)
	fx9_session(&fx, "srv_auto", domain.Shell_Session_Kind_Server, "chain_auto", "")

	chain, ok, _ := sync_chain_status_from_tasks(&fx.svc, "chain_auto", domain.User_ID(R9_OWNER))

	testing.expect(t, ok, "sync ok")
	testing.expect_value(t, chain.status, domain.Task_Chain_Status.Completed)
	testing.expect(t, fx9_intent(&fx, "srv_auto") != "", "auto-completing a chain must reap its servers")
}

@(test)
t9_change_chain_status_reaps :: proc(t: ^testing.T) {
	fx: Fx9
	if !fx9_make(&fx, t, "verb") do return
	defer fx9_free(&fx)

	fx9_chain(&fx, "chain_verb")
	fx9_session(&fx, "srv_verb",  domain.Shell_Session_Kind_Server, "chain_verb",  "")
	// The negative, on the real query: another chain's server keeps running.
	fx9_chain(&fx, "chain_other")
	fx9_session(&fx, "srv_other", domain.Shell_Session_Kind_Server, "chain_other", "")

	_, ok, _ := change_chain_status(&fx.svc, fx9_auth(), "chain_verb", .Completed)

	testing.expect(t, ok, "change_chain_status ok")
	testing.expect(t, fx9_intent(&fx, "srv_verb") != "", "the closed chain's server must be reaped")
	testing.expect_value(t, fx9_intent(&fx, "srv_other"), "")
}

@(test)
t9_update_chain_status_reaps :: proc(t: ^testing.T) {
	fx: Fx9
	if !fx9_make(&fx, t, "patch") do return
	defer fx9_free(&fx)

	fx9_chain(&fx, "chain_patch")
	fx9_session(&fx, "srv_patch", domain.Shell_Session_Kind_Server, "chain_patch", "")

	_, ok, _ := update_chain(&fx.svc, fx9_auth(), "chain_patch", Update_Chain_Input{status = "completed"})

	testing.expect(t, ok, "update_chain ok")
	testing.expect(t, fx9_intent(&fx, "srv_patch") != "", "a PATCH that closes a chain must reap too")
}

// AC3 THROUGH THE REAL SQL. list_by_chain AND-s in a kind clause built from
// domain.SHELL_SESSION_SCOPE_RULES, and Server is the only kind whose scope key includes
// .Chain — so a run and a shell are unreachable from this trigger by construction, not by
// a filter someone could delete. The run carries a chain_id here ON PURPOSE, which a real
// run never would: even a mis-scoped row must not be reachable.
@(test)
t9_real_query_cannot_reach_a_run_or_a_shell :: proc(t: ^testing.T) {
	fx: Fx9
	if !fx9_make(&fx, t, "kinds") do return
	defer fx9_free(&fx)

	fx9_chain(&fx, "chain_kinds")
	fx9_session(&fx, "srv_k",   domain.Shell_Session_Kind_Server, "chain_kinds", "")
	fx9_session(&fx, "run_k",   domain.Shell_Session_Kind_Run,    "chain_kinds", "inst_1")
	fx9_session(&fx, "shell_k", domain.Shell_Session_Kind_Shell,  "chain_kinds", "")

	_, ok, _ := change_chain_status(&fx.svc, fx9_auth(), "chain_kinds", .Completed)

	testing.expect(t, ok, "change_chain_status ok")
	testing.expect(t, fx9_intent(&fx, "srv_k") != "", "the server is reaped")
	testing.expect_value(t, fx9_intent(&fx, "run_k"), "")
	testing.expect_value(t, fx9_intent(&fx, "shell_k"), "")
}

// AC8. Cancelled reaps because the hub already tells every member "All task activities
// halted" on a cancel, so a surviving server would make that message a lie. Archived
// reaps because Active -> Archived is a legal transition, making it a real close path for
// a chain that was never completed.
@(test)
t9_cancelled_and_archived_also_reap :: proc(t: ^testing.T) {
	fx: Fx9
	if !fx9_make(&fx, t, "canarch") do return
	defer fx9_free(&fx)

	fx9_chain(&fx, "chain_cancel")
	fx9_session(&fx, "srv_cancel", domain.Shell_Session_Kind_Server, "chain_cancel", "")
	fx9_chain(&fx, "chain_archive")
	fx9_session(&fx, "srv_archive", domain.Shell_Session_Kind_Server, "chain_archive", "")

	_, c_ok, _ := change_chain_status(&fx.svc, fx9_auth(), "chain_cancel", .Cancelled)
	// Straight from Active, which is what makes archiving a close path in its own right
	// rather than a no-op after a completion.
	_, a_ok, _ := change_chain_status(&fx.svc, fx9_auth(), "chain_archive", .Archived)

	testing.expect(t, c_ok, "cancel ok")
	testing.expect(t, a_ok, "archive ok")
	testing.expect(t, fx9_intent(&fx, "srv_cancel") != "", "a cancelled chain must reap")
	testing.expect(t, fx9_intent(&fx, "srv_archive") != "", "an archived chain must reap")
}

// The documented consequence of reaping at all: reopening a chain does not bring its
// servers back. The processes are gone and the hub cannot restart what it did not keep.
// Asserted rather than left implied, because a future reader is entitled to know whether
// the absence of a restart is a decision or an oversight.
@(test)
t9_reopening_a_chain_does_not_resurrect :: proc(t: ^testing.T) {
	fx: Fx9
	if !fx9_make(&fx, t, "reopen") do return
	defer fx9_free(&fx)

	fx9_chain(&fx, "chain_reopen")
	fx9_session(&fx, "srv_reopen", domain.Shell_Session_Kind_Server, "chain_reopen", "")

	_, close_ok, _ := change_chain_status(&fx.svc, fx9_auth(), "chain_reopen", .Completed)
	testing.expect(t, close_ok, "close ok")
	intent_after_close := fx9_intent(&fx, "srv_reopen")
	testing.expect(t, intent_after_close != "", "closed, so reaped")

	_, open_ok, _ := change_chain_status(&fx.svc, fx9_auth(), "chain_reopen", .Active)

	testing.expect(t, open_ok, "reopen ok")
	// The intent stands; nothing cleared it and nothing restarted the process.
	testing.expect_value(t, fx9_intent(&fx, "srv_reopen"), intent_after_close)
}
