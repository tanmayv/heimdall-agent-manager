// T15 (spec §18, report §7 Phase 1): GitHub offline, hub offline, >100 releases, mutable
// assets and fast -> stable without downgrade, with the real launcher and supervisor.
package e2e

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "../procs"
import "../testkit"

// expect_unchanged: op `op_id` ended `state` (code containing `code` unless ""), and the
// installed release kept running untouched (same runtime process, same pointers).
expect_unchanged :: proc(i: ^Inst, op_id, state, code: string, tree: string, rt: procs.Id) -> bool {
	@(static) want_op: string
	want_op = op_id
	if !wait_for(i, fmt.tprintf("%s ends", op_id), 120 * time.Second, proc(i: ^Inst) -> bool {return op_done(i, want_op)}) do return false
	st, c, note := op_final(i, op_id)
	log.infof("%s: %s -> %s %s (%s)", i.name, op_id, st, c, note)
	ok := testing.expectf(i.s.t, st == state, "%s: %s ended %s %s (%s), want %s", i.name, op_id, st, c, note, state)
	if code != "" do ok &= testing.expectf(i.s.t, strings.contains(c, code) || strings.contains(note, code), "%s: %s error %q note %q, want %s", i.name, op_id, c, note, code)
	ok &= testing.expectf(i.s.t, current(i) == tree && known_good(i) == tree, "%s: still on %s (current %s, known-good %s)", i.name, tree, current(i), known_good(i))
	ok &= testing.expectf(i.s.t, procs.alive(rt) && last_runtime(i).id == rt, "%s: the same runtime keeps running", i.name)
	return ok
}

// GitHub offline (connections dropped, then HTTP 503): an update fails before anything
// changes and the installed release keeps running, the same process; once GitHub is back
// the update goes through.
@(test)
test_github_offline :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	s: Suite
	defer suite_close(&s)
	if !suite_open(&s, t, "github") do return
	a := new_inst(&s, "a")
	a.first_check_s = NEVER
	t0 := strings.clone(publish(&s, "v0.6.0"))
	defer delete(t0)
	if !install(a, "v0.6.0") do return
	rt := last_runtime(a).id
	publish(&s, "v0.6.1")

	testkit.github_set_mode(&s.gh, .Offline)
	before := testkit.github_requests(&s.gh)
	send_intent(a, "op_gh_offline", "update_now")
	if !expect_unchanged(a, "op_gh_offline", "failed", "", t0, rt) do return
	testing.expectf(t, testkit.github_requests(&s.gh) > before, "the supervisor did try GitHub")

	testkit.github_set_mode(&s.gh, .Unavailable)
	send_intent(a, "op_gh_503", "update_now")
	if !expect_unchanged(a, "op_gh_503", "failed", "", t0, rt) do return

	// A download that fails half way: the bundle asset is gone (404) while the API still
	// lists it.
	testkit.github_set_mode(&s.gh, .Online)
	testkit.github_set_missing_download(&s.gh, "v0.6.1")
	send_intent(a, "op_gh_404", "update_now")
	ok := expect_unchanged(a, "op_gh_404", "failed", "download", t0, rt)
	testkit.github_set_missing_download(&s.gh, "")
	if !ok do return
	r := release_of(&s, "v0.6.1")

	send_intent(a, "op_gh_back", "update_now")
	g_want = r.tree
	if !wait_for(a, "update after GitHub is back", 120 * time.Second, proc(i: ^Inst) -> bool {return known_good(i) == g_want}) do return
	st, _, _ := op_final(a, "op_gh_back")
	testing.expectf(t, st == "committed", "op_gh_back %s", st)
	testing.expect_value(t, stop_launcher(a), 0)
}

// Hub offline (spec §14 hub rule):
//   1. the hub was never reachable: the install commits with note probation_offline;
//   2. hub up: an update commits and its probation saw the hub (no note);
//   3. the hub goes down before an update: the update still goes through, offline
//      (committed, probation_offline) — an outage never blocks or rolls back an update;
//   4. hub up, but the candidate's runtime cannot reach it while the old one could: rolled
//      back (hub_unreachable) and pinned; the rollback itself does not need the hub.
@(test)
test_hub_offline :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	s: Suite
	defer suite_close(&s)
	if !suite_open(&s, t, "hub") do return
	a := new_inst(&s, "a")
	a.first_check_s = NEVER
	publish(&s, "v0.6.0")
	if !install(a, "v0.6.0") do return
	st, _, note := op_final(a, "op_install_v0_6_0")
	testing.expectf(t, st == "committed" && strings.contains(note, "probation_offline"), "offline install: %s note %q", st, note)

	// 2.
	set_hub(a, true)
	time.sleep(3 * time.Second) // runtime-status.json says connected
	t1 := strings.clone(publish(&s, "v0.6.1"))
	defer delete(t1)
	send_intent(a, "op_hub_up", "install_version", `,"version":"v0.6.1"`)
	g_want = t1
	if !wait_for(a, "v0.6.1 committed with the hub up", 120 * time.Second, proc(i: ^Inst) -> bool {return known_good(i) == g_want}) do return
	st, _, note = op_final(a, "op_hub_up")
	testing.expectf(t, st == "committed" && !strings.contains(note, "probation_offline"), "hub-up update: %s note %q", st, note)

	// 3.
	set_hub(a, false)
	time.sleep(3 * time.Second)
	t2 := strings.clone(publish(&s, "v0.6.2"))
	defer delete(t2)
	send_intent(a, "op_hub_down", "install_version", `,"version":"v0.6.2"`)
	g_want = t2
	if !wait_for(a, "v0.6.2 committed with the hub down", 120 * time.Second, proc(i: ^Inst) -> bool {return known_good(i) == g_want}) do return
	st, _, note = op_final(a, "op_hub_down")
	testing.expectf(t, st == "committed" && strings.contains(note, "probation_offline"), "hub-down update: %s note %q", st, note)

	// 4.
	set_hub(a, true)
	time.sleep(3 * time.Second)
	t3 := publish(&s, "v0.6.3")
	_ = os.make_directory_all(pj(a.data, "fake-hub-down"))
	_ = os.write_entire_file(pj(a.data, "fake-hub-down", t3), transmute([]byte)string("x"))
	send_intent(a, "op_hub_cand", "install_version", `,"version":"v0.6.3"`)
	if !expect_rolled_back(a, "op_hub_cand", t2, "0.6.3") do return
	_, code, _ := op_final(a, "op_hub_cand")
	testing.expectf(t, code == "hub_unreachable", "op_hub_cand error %s, want hub_unreachable", code)
	testing.expect_value(t, stop_launcher(a), 0)
}

// >100 releases, mutable assets, fast -> stable:
//   1. fast channel; the newest fast release v0.7.0 is older than 120 later (lower) ones,
//      so it is on page 2 of the list: it is found (paging to exhaustion) and installed;
//   2. v0.7.0 is re-built and re-published (same version, other digest, valid signature):
//      update_now refuses it (digest_conflict), nothing changes;
//   3. v0.7.1's bundle bytes are swapped after publish (manifest unchanged): the download
//      fails verification (bundle_mismatch), nothing changes;
//   4. set_channel stable (stable latest v0.6.0 < installed): update_now never downgrades.
@(test)
test_many_releases_and_mutable_assets :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	s: Suite
	defer suite_close(&s)
	if !suite_open(&s, t, "releases") do return
	a := new_inst(&s, "a")
	a.first_check_s = NEVER
	set_channel(a, "fast")
	publish(&s, "v0.6.0")
	t7 := strings.clone(publish(&s, "v0.7.0", {stable = false}))
	defer delete(t7)
	for n in 100 ..< 220 do testkit.github_publish_stub(&s.gh, fmt.tprintf("v0.6.%d", n))
	if !install(a, "v0.6.0") do return

	// 1.
	send_intent(a, "op_rel_fast", "update_now")
	g_want = t7
	if !wait_for(a, "v0.7.0 from page 2 committed", 150 * time.Second, proc(i: ^Inst) -> bool {return known_good(i) == g_want}) do return
	testing.expectf(t, testkit.github_pages_2plus(&s.gh) > 0, "the resolver read page 2+")
	rt := last_runtime(a).id

	// 2. Same version, different digest.
	nr := build_release(&s, "v0.7.0", {stable = false, pad_bytes = 4096})
	testing.expect(t, nr.sha256 != release_of(&s, "v0.7.0").sha256, "re-built release differs")
	testing.expect(t, testkit.github_republish(&s.gh, nr), "republish v0.7.0")
	send_intent(a, "op_rel_conflict", "update_now")
	if !expect_unchanged(a, "op_rel_conflict", "failed", "digest_conflict", t7, rt) do return

	// 3. Asset bytes swapped after publish.
	publish(&s, "v0.7.1", {stable = false})
	other := build_release(&s, "v0.7.1", {stable = false, pad_bytes = 8192})
	testing.expect(t, testkit.github_replace_bundle(&s.gh, "v0.7.1", other.bundle), "replace v0.7.1 bundle")
	other.bundle = nil
	testkit.release_destroy(&other)
	send_intent(a, "op_rel_mutated", "update_now")
	if !expect_unchanged(a, "op_rel_mutated", "failed", "bundle_mismatch", t7, rt) do return

	// 4. fast -> stable: no downgrade.
	send_intent(a, "op_rel_channel", "set_channel", `,"channel":"stable"`)
	if !wait_for(a, "set_channel stable", 30 * time.Second, proc(i: ^Inst) -> bool {return op_done(i, "op_rel_channel")}) do return
	send_intent(a, "op_rel_stable", "update_now")
	if !wait_for(a, "op_rel_stable ends", 60 * time.Second, proc(i: ^Inst) -> bool {return op_done(i, "op_rel_stable")}) do return
	st, code, note := op_final(a, "op_rel_stable")
	testing.expectf(t, st == "noop", "stable update from 0.7.0: %s %s (%s), want noop", st, code, note)
	testing.expect_value(t, current(a), t7)
	testing.expect(t, procs.alive(rt), "runtime untouched")
	testing.expect_value(t, stop_launcher(a), 0)
}
