// Owner-wide shell-session listing: the repository behaviour behind
// GET /api/v1/shells with no scope.
//
// Build & run (from the repo root, inside the nix dev shell):
//   odin build tests/hub_shell_session_owner_list_test.odin -file \
//     -collection:odin_test=src -out:/tmp/ham-shell-owner-list-test
//   /tmp/ham-shell-owner-list-test
//
// It asserts the five things the route promises and nothing else can prove from
// the outside: sessions come back from MORE THAN ONE bridge, each filter
// narrows, two filters AND rather than OR, the keyset cursor walks to
// exhaustion without repeating or dropping a row, and another owner's sessions
// are never visible. The last case re-runs the chain-scoped list to show the
// shared query builder did not move it.
package hub_shell_session_owner_list_test

import "core:fmt"
import "core:os"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"

failures := 0

check :: proc(ok: bool, msg: string) {
	if ok {
		fmt.println("  ok:", msg)
		return
	}
	fmt.eprintln("FAIL:", msg)
	failures += 1
}

// ids_of renders the session ids of a page in order, so a failed expectation
// prints what actually came back instead of just a count.
ids_of :: proc(items: [dynamic]domain.Shell_Session) -> string {
	out := ""
	for s, i in items {
		if i > 0 do out = fmt.tprintf("%s,%s", out, s.session_id)
		else do out = s.session_id
	}
	return out
}

expect_ids :: proc(items: [dynamic]domain.Shell_Session, want: string, msg: string) {
	got := ids_of(items)
	check(got == want, fmt.tprintf("%s (want [%s], got [%s])", msg, want, got))
}

seed :: proc(repo: ^iface.Shell_Session_Repository, session_id, owner, bridge, project, chain, status, started_at: string) {
	ok, err := iface.shell_session_upsert(repo, domain.Shell_Session{
		session_id    = session_id,
		owner_user_id = owner,
		bridge_id     = bridge,
		project_id    = project,
		chain_id      = chain,
		kind          = "interactive",
		cmd           = "bash",
		status        = status,
		started_at    = started_at,
		created_at    = started_at,
	})
	if !ok {
		fmt.eprintln("FAIL: seed", session_id, err.message)
		os.exit(1)
	}
}

main :: proc() {
	db_path := "/tmp/shell_session_owner_list_test.db"
	_ = os.remove(db_path)
	defer _ = os.remove(db_path)

	conn, open_ok, open_err := sqlite.open(db_path)
	if !open_ok {
		fmt.eprintln("FAIL: open db:", open_err.message)
		os.exit(1)
	}
	defer sqlite.close(&conn)

	mig_ok, mig_err := sqlite.run_migrations(&conn, "src/hub/repository/sqlite/migrations")
	if !mig_ok {
		fmt.eprintln("FAIL: run_migrations:", mig_err.message)
		os.exit(1)
	}

	impl: sqlite.Shell_Session_Repo_SQLite
	repo := sqlite.new_shell_session_repository(&impl, &conn)

	// Two bridges, two projects, two chains, two statuses — every filter has at
	// least one row it must keep and one it must drop. started_at ascends with
	// the id so the DESC ordering is sh_06 .. sh_01, which is also the order the
	// session_id keyset cursor walks.
	//            id       owner  bridge   project  chain  status     started_at
	seed(&repo, "sh_01", "u_one", "brg_a", "prj_1", "chn_1", "running", "2026-01-01T00:00:01Z")
	seed(&repo, "sh_02", "u_one", "brg_a", "prj_1", "chn_2", "exited",  "2026-01-01T00:00:02Z")
	seed(&repo, "sh_03", "u_one", "brg_a", "prj_2", "chn_1", "running", "2026-01-01T00:00:03Z")
	seed(&repo, "sh_04", "u_one", "brg_b", "prj_1", "chn_1", "exited",  "2026-01-01T00:00:04Z")
	seed(&repo, "sh_05", "u_one", "brg_b", "prj_2", "chn_2", "running", "2026-01-01T00:00:05Z")
	seed(&repo, "sh_06", "u_one", "brg_b", "prj_2", "chn_1", "running", "2026-01-01T00:00:06Z")
	// sh_07 is `starting` and sh_08 is `failed`: the two statuses a naive
	// live->"running" / finished->"exited" mapping would silently drop. They are
	// what the status-group assertions in section 6 are for.
	seed(&repo, "sh_07", "u_one", "brg_a", "prj_1", "chn_1", "starting", "2026-01-01T00:00:07Z")
	seed(&repo, "sh_08", "u_one", "brg_b", "prj_2", "chn_2", "failed",   "2026-01-01T00:00:08Z")
	// A second owner, matching every filter u_one uses. It must never appear.
	seed(&repo, "sh_90", "u_two", "brg_a", "prj_1", "chn_1", "running", "2026-01-01T00:00:09Z")

	no_filter :: iface.Shell_Session_List_Filter{}

	// 1. The point of the task: no scope at all returns shells from >1 bridge.
	fmt.println("1. unscoped listing spans bridges")
	all, all_cursor, all_err := iface.shell_session_list_by_owner(&repo, "u_one", no_filter, "", 50)
	defer domain.shell_sessions_destroy(all)
	check(all_err.code == .None, "no error")
	expect_ids(all, "sh_08,sh_07,sh_06,sh_05,sh_04,sh_03,sh_02,sh_01", "all eight of u_one's sessions, newest first")
	saw_a, saw_b := false, false
	for s in all {
		if s.bridge_id == "brg_a" do saw_a = true
		if s.bridge_id == "brg_b" do saw_b = true
		if s.owner_user_id != "u_one" do check(false, fmt.tprintf("leaked a session owned by %s", s.owner_user_id))
	}
	check(saw_a && saw_b, "rows came from BOTH brg_a and brg_b")
	check(all_cursor == "", "a short page reports no next_cursor")

	// 2. Each filter narrows on its own.
	fmt.println("2. each filter narrows")
	by_bridge, _, _ := iface.shell_session_list_by_owner(&repo, "u_one", iface.Shell_Session_List_Filter{bridge_id = "brg_a"}, "", 50)
	defer domain.shell_sessions_destroy(by_bridge)
	expect_ids(by_bridge, "sh_07,sh_03,sh_02,sh_01", "bridge_id=brg_a")

	by_project, _, _ := iface.shell_session_list_by_owner(&repo, "u_one", iface.Shell_Session_List_Filter{project_id = "prj_2"}, "", 50)
	defer domain.shell_sessions_destroy(by_project)
	expect_ids(by_project, "sh_08,sh_06,sh_05,sh_03", "project_id=prj_2")

	by_chain, _, _ := iface.shell_session_list_by_owner(&repo, "u_one", iface.Shell_Session_List_Filter{chain_id = "chn_1"}, "", 50)
	defer domain.shell_sessions_destroy(by_chain)
	expect_ids(by_chain, "sh_07,sh_06,sh_04,sh_03,sh_01", "chain_id=chn_1")

	by_status, _, _ := iface.shell_session_list_by_owner(&repo, "u_one", iface.Shell_Session_List_Filter{status = "running"}, "", 50)
	defer domain.shell_sessions_destroy(by_status)
	expect_ids(by_status, "sh_06,sh_05,sh_03,sh_01", "status=running")

	// 3. Two filters AND. Under OR this would return five rows (the four on
	//    brg_b or running); under AND it is exactly the two that are both.
	fmt.println("3. filters AND, they do not OR")
	and_two, _, _ := iface.shell_session_list_by_owner(&repo, "u_one", iface.Shell_Session_List_Filter{bridge_id = "brg_b", status = "running"}, "", 50)
	defer domain.shell_sessions_destroy(and_two)
	expect_ids(and_two, "sh_06,sh_05", "bridge_id=brg_b AND status=running")

	and_three, _, _ := iface.shell_session_list_by_owner(&repo, "u_one", iface.Shell_Session_List_Filter{bridge_id = "brg_b", project_id = "prj_2", chain_id = "chn_1"}, "", 50)
	defer domain.shell_sessions_destroy(and_three)
	expect_ids(and_three, "sh_06", "bridge_id=brg_b AND project_id=prj_2 AND chain_id=chn_1")

	// An AND with no overlap is empty, not a fallback to the wider set.
	empty, empty_cursor, _ := iface.shell_session_list_by_owner(&repo, "u_one", iface.Shell_Session_List_Filter{bridge_id = "brg_a", project_id = "prj_2", status = "exited"}, "", 50)
	defer domain.shell_sessions_destroy(empty)
	expect_ids(empty, "", "a contradictory filter set returns nothing")
	check(empty_cursor == "", "empty page has no cursor")

	// 4. Keyset paging walks to exhaustion: limit 2 over 6 rows.
	fmt.println("4. cursor paging terminates")
	seen := make([dynamic]string)
	defer delete(seen)
	cursor := ""
	cursor_owned := ""  // the repo hands back an owned cursor; free the previous one each hop
	pages := 0
	for {
		page, next, page_err := iface.shell_session_list_by_owner(&repo, "u_one", no_filter, cursor, 2)
		check(page_err.code == .None, fmt.tprintf("page %d has no error", pages))
		pages += 1
		// Cloned because the ids are checked after the page is freed. `defer` in a
		// loop body fires per ITERATION, so an un-cloned id here is read back from
		// freed memory — which is exactly how this test failed the first time.
		for s in page do append(&seen, strings.clone(s.session_id))
		domain.shell_sessions_destroy(page)
		delete(cursor_owned)
		cursor_owned = next
		cursor = next
		if next == "" do break
		if pages > 10 {
			check(false, "paging did not terminate within 10 pages")
			break
		}
	}
	defer delete(cursor_owned)
	defer for id in seen do delete(id)
	check(len(seen) == 8, fmt.tprintf("walked exactly 8 rows, no repeats or drops (got %d: %v)", len(seen), seen))
	// 4 full pages of 2 then one empty page, because a full last page cannot
	// know it was the last one.
	check(pages == 5, fmt.tprintf("took 5 pages (4 full + 1 empty terminator), got %d", pages))
	dupes := false
	for a, i in seen {
		for b, j in seen {
			if i != j && a == b do dupes = true
		}
	}
	check(!dupes, "no session id appeared on two pages")

	// 5. Owner isolation, and the scoped lists still behave.
	fmt.println("5. owner isolation and scoped-list regression")
	other, _, _ := iface.shell_session_list_by_owner(&repo, "u_two", no_filter, "", 50)
	defer domain.shell_sessions_destroy(other)
	expect_ids(other, "sh_90", "u_two sees only its own session")

	chain_scoped, _, _ := iface.shell_session_list_by_chain(&repo, "u_one", "chn_1", "", "", 50)
	defer domain.shell_sessions_destroy(chain_scoped)
	expect_ids(chain_scoped, "sh_07,sh_06,sh_04,sh_03,sh_01", "list_by_chain(chn_1) unchanged, matches the chain_id filter")

	bridge_scoped, _, _ := iface.shell_session_list_by_bridge(&repo, "u_one", "brg_a", "running", "", 50)
	defer domain.shell_sessions_destroy(bridge_scoped)
	expect_ids(bridge_scoped, "sh_03,sh_01", "list_by_bridge(brg_a, running) unchanged")

	project_scoped, _, _ := iface.shell_session_list_by_project(&repo, "u_one", "prj_2", "", "", 50)
	defer domain.shell_sessions_destroy(project_scoped)
	expect_ids(project_scoped, "sh_08,sh_06,sh_05,sh_03", "list_by_project(prj_2) unchanged")

	// 6. Status GROUPS. `live` and `finished` are not statuses — no row's status
	//    column ever holds either — they are the terminal/non-terminal split the
	//    domain owns, made expressible by a query.
	fmt.println("6. status groups live/finished")
	live, _, live_err := iface.shell_session_list_by_owner(&repo, "u_one", iface.Shell_Session_List_Filter{status = domain.Shell_Session_Status_Group_Live}, "", 50)
	defer domain.shell_sessions_destroy(live)
	check(live_err.code == .None, "live group has no error")
	// sh_07 is `starting`. THIS is the assertion that rules out live->"running".
	expect_ids(live, "sh_07,sh_06,sh_05,sh_03,sh_01", "status=live is every non-terminal session, INCLUDING starting")

	finished, _, _ := iface.shell_session_list_by_owner(&repo, "u_one", iface.Shell_Session_List_Filter{status = domain.Shell_Session_Status_Group_Finished}, "", 50)
	defer domain.shell_sessions_destroy(finished)
	// sh_08 is `failed` and sh_04 is `exited`; a killed row is covered below.
	// THIS is the assertion that rules out finished->"exited".
	expect_ids(finished, "sh_08,sh_04,sh_02", "status=finished is every terminal session, INCLUDING failed")

	// The two groups partition the set: every session is in exactly one.
	check(len(live) + len(finished) == len(all), fmt.tprintf("live(%d) + finished(%d) == all(%d)", len(live), len(finished), len(all)))
	for l in live {
		if domain.shell_session_is_terminal(l) do check(false, fmt.tprintf("live group contained terminal session %s (%s)", l.session_id, l.status))
	}
	for f in finished {
		if !domain.shell_session_is_terminal(f) do check(false, fmt.tprintf("finished group contained live session %s (%s)", f.session_id, f.status))
	}

	// `killed` is terminal too — the third member of the set, and the one a
	// status-by-status mapping is most likely to forget.
	seed(&repo, "sh_09", "u_one", "brg_a", "prj_1", "chn_1", "killed", "2026-01-01T00:00:10Z")
	finished2, _, _ := iface.shell_session_list_by_owner(&repo, "u_one", iface.Shell_Session_List_Filter{status = domain.Shell_Session_Status_Group_Finished}, "", 50)
	defer domain.shell_sessions_destroy(finished2)
	expect_ids(finished2, "sh_09,sh_08,sh_04,sh_02", "status=finished picks up a killed session too")

	live2, _, _ := iface.shell_session_list_by_owner(&repo, "u_one", iface.Shell_Session_List_Filter{status = domain.Shell_Session_Status_Group_Live}, "", 50)
	defer domain.shell_sessions_destroy(live2)
	expect_ids(live2, "sh_07,sh_06,sh_05,sh_03,sh_01", "status=live is unchanged by a killed session appearing")

	// A group composes with the other filters exactly like a concrete status.
	live_on_b, _, _ := iface.shell_session_list_by_owner(&repo, "u_one", iface.Shell_Session_List_Filter{bridge_id = "brg_b", status = domain.Shell_Session_Status_Group_Live}, "", 50)
	defer domain.shell_sessions_destroy(live_on_b)
	expect_ids(live_on_b, "sh_06,sh_05", "bridge_id=brg_b AND status=live")

	// Concrete statuses still mean exactly themselves — the groups are additive
	// vocabulary, they did not redefine anything.
	still_exact, _, _ := iface.shell_session_list_by_owner(&repo, "u_one", iface.Shell_Session_List_Filter{status = "exited"}, "", 50)
	defer domain.shell_sessions_destroy(still_exact)
	expect_ids(still_exact, "sh_04,sh_02", "status=exited is still exactly the exited rows, not the finished group")

	// 7. The groups work on the SCOPED routes too, not just the owner-wide one.
	fmt.println("7. groups honoured on the scoped list routes")
	chain_live, _, _ := iface.shell_session_list_by_chain(&repo, "u_one", "chn_1", domain.Shell_Session_Status_Group_Live, "", 50)
	defer domain.shell_sessions_destroy(chain_live)
	expect_ids(chain_live, "sh_07,sh_06,sh_03,sh_01", "list_by_chain(chn_1, live) includes starting")

	bridge_finished, _, _ := iface.shell_session_list_by_bridge(&repo, "u_one", "brg_a", domain.Shell_Session_Status_Group_Finished, "", 50)
	defer domain.shell_sessions_destroy(bridge_finished)
	expect_ids(bridge_finished, "sh_09,sh_02", "list_by_bridge(brg_a, finished) includes killed")

	project_live, _, _ := iface.shell_session_list_by_project(&repo, "u_one", "prj_2", domain.Shell_Session_Status_Group_Live, "", 50)
	defer domain.shell_sessions_destroy(project_live)
	expect_ids(project_live, "sh_06,sh_05,sh_03", "list_by_project(prj_2, live) excludes the failed row")

	if failures > 0 {
		fmt.eprintln("")
		fmt.eprintfln("FAILED: %d check(s)", failures)
		os.exit(1)
	}
	fmt.println("")
	fmt.println("PASS: hub_shell_session_owner_list_test")
}
