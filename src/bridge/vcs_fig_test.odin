package main

import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(private = "file")
vcs_fig_test_stamp :: proc() -> string {
	ns := time.to_unix_nanoseconds(time.now())
	b := strings.builder_make()
	strings.write_int(&b, int(ns % 1_000_000_000))
	return strings.to_string(b)
}

@(private = "file")
vcs_fig_test_make_dir :: proc(t: ^testing.T, tag: string) -> string {
	base := os.get_env_alloc("TMPDIR", context.allocator)
	if strings.trim_space(base) == "" do base = "/tmp"
	base = strings.trim_right(base, "/")
	root := strings.concatenate({base, "/ham_vcs_fig_test_", tag, "_", vcs_fig_test_stamp()})
	_ = os.make_directory_all(root)
	if resolved, rerr := os.get_absolute_path(root, context.allocator); rerr == nil do root = resolved
	return root
}

@(test)
test_vcs_fig_provider_and_capabilities :: proc(t: ^testing.T) {
	p := vcs_fig_provider()
	testing.expect_value(t, p.name(), "fig")
	testing.expect(t, p.detect != nil, "detect proc present")
	testing.expect(t, p.status != nil, "status proc present")
	testing.expect(t, p.changed_files != nil, "changed_files proc present")
	testing.expect(t, p.diff_file != nil, "diff_file proc present")
	testing.expect(t, p.capabilities != nil, "capabilities proc present")
	testing.expect(t, p.stage_file != nil, "stage_file proc present")
	testing.expect(t, p.unstage_file != nil, "unstage_file proc present")

	caps := p.capabilities("/dummy/path")
	testing.expect_value(t, caps.provider, "fig")
	testing.expect(t, !caps.supports_staging, "fig supports_staging must be false")
	testing.expect(t, caps.supports_amend, "fig supports_amend must be true")
}

@(test)
test_vcs_fig_status_word_mapping :: proc(t: ^testing.T) {
	testing.expect_value(t, vcs_fig_status_word('M'), "modified")
	testing.expect_value(t, vcs_fig_status_word('A'), "added")
	testing.expect_value(t, vcs_fig_status_word('R'), "deleted")
	testing.expect_value(t, vcs_fig_status_word('!'), "deleted")
	testing.expect_value(t, vcs_fig_status_word('?'), "untracked")
	testing.expect_value(t, vcs_fig_status_word('X'), "modified") // fallback
}

@(test)
test_vcs_fig_diffstat_parsing :: proc(t: ^testing.T) {
	stat_out := ` file1.txt | 2 +
 dir/file2.txt | 6 ++++--
 file3.txt | 5 -----
 ./relative.txt | 4 ++--
 huge.txt | 200 ++++++++++++++++++++++++++++++++--------------------------------
 5 files changed, 107 insertions(+), 110 deletions(-)
`
	stats := make(map[string][2]int, 0, context.temp_allocator)
	vcs_fig_parse_diffstat_into(&stats, stat_out)

	testing.expect_value(t, stats["file1.txt"][0], 2)
	testing.expect_value(t, stats["file1.txt"][1], 0)

	testing.expect_value(t, stats["dir/file2.txt"][0], 4)
	testing.expect_value(t, stats["dir/file2.txt"][1], 2)

	testing.expect_value(t, stats["file3.txt"][0], 0)
	testing.expect_value(t, stats["file3.txt"][1], 5)

	testing.expect_value(t, stats["relative.txt"][0], 2)
	testing.expect_value(t, stats["relative.txt"][1], 2)

	testing.expect_value(t, stats["huge.txt"][0], 100)
	testing.expect_value(t, stats["huge.txt"][1], 100)
}

@(test)
test_vcs_fig_changed_files_parsing :: proc(t: ^testing.T) {
	status_out := `M src/main.odin
A src/new.odin
R src/removed.odin
! src/missing.odin
? notes.txt
`
	stats := make(map[string][2]int, 0, context.temp_allocator)
	stats["src/main.odin"] = [2]int{10, 3}
	stats["src/new.odin"] = [2]int{42, 0}

	files := vcs_fig_parse_changed_files(status_out, stats, "")
	defer {
		for f in files do delete(f.path)
		delete(files)
	}

	testing.expect_value(t, len(files), 5)

	testing.expect_value(t, files[0].path, "src/main.odin")
	testing.expect_value(t, files[0].status, "modified")
	testing.expect(t, !files[0].staged, "not staged")
	testing.expect_value(t, files[0].additions, 10)
	testing.expect_value(t, files[0].deletions, 3)

	testing.expect_value(t, files[1].path, "src/new.odin")
	testing.expect_value(t, files[1].status, "added")
	testing.expect(t, !files[1].staged, "not staged")
	testing.expect_value(t, files[1].additions, 42)
	testing.expect_value(t, files[1].deletions, 0)

	testing.expect_value(t, files[2].path, "src/removed.odin")
	testing.expect_value(t, files[2].status, "deleted")

	testing.expect_value(t, files[3].path, "src/missing.odin")
	testing.expect_value(t, files[3].status, "deleted")

	testing.expect_value(t, files[4].path, "notes.txt")
	testing.expect_value(t, files[4].status, "untracked")
}

@(test)
test_vcs_fig_diff_hunk_parsing :: proc(t: ^testing.T) {
	hg_diff := `diff --git a/src/test.odin b/src/test.odin
--- a/src/test.odin
+++ b/src/test.odin
@@ -1,4 +1,5 @@
 package test
-old_line := 1
+new_line := 1
+new_line_2 := 2
 end
`
	hunks := vcs_parse_unified_diff(hg_diff)
	defer vcs_test_free_hunks(hunks)

	testing.expect_value(t, len(hunks), 1)
	h := hunks[0]
	testing.expect_value(t, h.old_start, 1)
	testing.expect_value(t, h.old_len, 4)
	testing.expect_value(t, h.new_start, 1)
	testing.expect_value(t, h.new_len, 5)
	testing.expect_value(t, len(h.lines), 5)
	testing.expect_value(t, h.lines[0].op, " ")
	testing.expect_value(t, h.lines[1].op, "-")
	testing.expect_value(t, h.lines[2].op, "+")
	testing.expect_value(t, h.lines[3].op, "+")
	testing.expect_value(t, h.lines[4].op, " ")
}

@(test)
test_vcs_fig_upward_subdirectory_detection :: proc(t: ^testing.T) {
	root := vcs_fig_test_make_dir(t, "detect")
	defer {
		os.remove_all(root)
		delete(root)
	}

	// Build deep directory tree: <root>/google3/monitoring/shared/unified_topology/resources/geo_maps/gce_blocks
	deep_sub := strings.concatenate({root, "/google3/monitoring/shared/unified_topology/resources/geo_maps/gce_blocks"})
	defer delete(deep_sub)
	_ = os.make_directory_all(deep_sub)

	// 1. Without markers, detection must return false
	testing.expect(t, !vcs_fig_detect(deep_sub), "no markers -> false")

	// 2. Add .citc marker at root: upward detection must discover it
	citc_dir := strings.concatenate({root, "/.citc"})
	_ = os.make_directory_all(citc_dir)
	testing.expect(t, vcs_fig_detect(deep_sub), "ancestor .citc discovered from deep sub")
	testing.expect(t, vcs_fig_detect(root), "root .citc discovered")

	// Provider detection should prioritize fig
	p_citc, ok_citc := vcs_detect_provider(deep_sub)
	testing.expect(t, ok_citc, "citc detected by vcs_detect_provider")
	testing.expect_value(t, p_citc.name(), "fig")

	// 3. Replace .citc with .hg marker
	_ = os.remove_all(citc_dir)
	delete(citc_dir)

	hg_dir := strings.concatenate({root, "/.hg"})
	defer delete(hg_dir)
	_ = os.make_directory_all(hg_dir)
	testing.expect(t, vcs_fig_detect(deep_sub), "ancestor .hg discovered from deep sub")
	testing.expect(t, vcs_fig_detect(root), "root .hg discovered")

	p_hg, ok_hg := vcs_detect_provider(deep_sub)
	testing.expect(t, ok_hg, "hg detected by vcs_detect_provider")
	testing.expect_value(t, p_hg.name(), "fig")

	// 4. Nonexistent path must return false
	testing.expect(t, !vcs_fig_detect("/nonexistent/path/for/fig"), "nonexistent path returns false")
	testing.expect(t, !vcs_fig_detect(""), "empty path returns false")
}

@(test)
test_vcs_fig_detect_live_citc :: proc(t: ^testing.T) {
	citc_path := "/google/src/cloud/tanmayvijay/heimdall/google3"
	if !os.exists(citc_path) do return

	testing.expect(t, vcs_fig_detect(citc_path), "live citc google3 detected as fig")
	p, ok := vcs_detect_provider(citc_path)
	testing.expect(t, ok, "live citc provider detected")
	testing.expect_value(t, p.name(), "fig")
}

@(test)
test_vcs_fig_extract_citc_info :: proc(t: ^testing.T) {
	deep_path := "/google/src/cloud/tanmayvijay/teloneum-processor/google3/monitoring/cloud_latency/billing/teloneum/processor"
	ws1, rel1, ok1 := vcs_fig_extract_citc_info(deep_path)
	testing.expect(t, ok1, "deep path is recognized as citc")
	testing.expect_value(t, ws1, "teloneum-processor")
	testing.expect_value(t, rel1, "monitoring/cloud_latency/billing/teloneum/processor")

	g3_root := "/google/src/cloud/tanmayvijay/teloneum-processor/google3"
	ws2, rel2, ok2 := vcs_fig_extract_citc_info(g3_root)
	testing.expect(t, ok2, "google3 root is recognized as citc")
	testing.expect_value(t, ws2, "teloneum-processor")
	testing.expect_value(t, rel2, "")

	ws_root := "/google/src/cloud/tanmayvijay/teloneum-processor"
	ws3, rel3, ok3 := vcs_fig_extract_citc_info(ws_root)
	testing.expect(t, ok3, "workspace root is recognized as citc")
	testing.expect_value(t, ws3, "teloneum-processor")
	testing.expect_value(t, rel3, "")

	not_citc := "/home/tanmay/some/project"
	_, _, ok4 := vcs_fig_extract_citc_info(not_citc)
	testing.expect(t, !ok4, "non-citc path is not recognized as citc")
}

@(test)
test_vcs_fig_live_google3_citc_workspace :: proc(t: ^testing.T) {
	test_path := "/google/src/cloud/tanmayvijay/teloneum-processor/google3/monitoring/cloud_latency/billing/teloneum/processor"
	if !os.exists(test_path) do return

	// 1. Detect provider
	p, ok := vcs_detect_provider(test_path)
	testing.expect(t, ok, "detect_provider succeeded on Google3 CitC directory")
	testing.expect_value(t, p.name(), "fig")

	// 2. Capabilities
	caps := p.capabilities(test_path)
	testing.expect_value(t, caps.provider, "fig")
	testing.expect(t, !caps.supports_staging, "supports_staging false")
	testing.expect_value(t, caps.staging_model, "none")

	// 3. Status
	st, sok := p.status(test_path)
	testing.expect(t, sok, "status succeeded")
	testing.expect_value(t, st.provider, "fig")
	testing.expect_value(t, st.branch, "teloneum-processor")
	testing.expect_value(t, st.remote, "//depot/google3/monitoring/cloud_latency/billing/teloneum/processor")
	if st.branch != "" do delete(st.branch)
	if st.remote != "" do delete(st.remote)

	// 4. Changed files
	files, _, _, fok := p.changed_files(test_path, "", 10)
	testing.expect(t, fok, "changed_files succeeded")
	for f in files do delete(f.path)
	delete(files)

	// 5. Log
	entries, _, _, lok := p.log(test_path, "", 5)
	testing.expect(t, lok, "log succeeded")
	testing.expect(t, len(entries) > 0, "log returned entries")
	for e in entries {
		delete(e.hash)
		delete(e.short_hash)
		delete(e.subject)
		delete(e.author)
		delete(e.date)
	}
	delete(entries)

	// 6. Workspaces
	ws_list, wok := p.list_workspaces(test_path)
	testing.expect(t, wok, "list_workspaces succeeded")
	testing.expect(t, len(ws_list) > 0, "workspaces returned entries")
	found_current := false
	for w in ws_list {
		if w.label == "teloneum-processor" && w.is_current {
			found_current = true
		}
		delete(w.path)
		delete(w.label)
	}
	delete(ws_list)
	testing.expect(t, found_current, "teloneum-processor marked as is_current")
}

@(test)
test_vcs_fig_stage_unstage_and_amend :: proc(t: ^testing.T) {
	p := vcs_fig_provider()
	s_ok, s_err := p.stage_file("/dummy", "")
	testing.expect(t, !s_ok, "empty file stage fails")
	testing.expect_value(t, s_err, "missing_file")

	u_ok, u_err := p.unstage_file("/dummy", "")
	testing.expect(t, !u_ok, "empty file unstage fails")
	testing.expect_value(t, u_err, "missing_file")

	c_ok := p.commit("/dummy", "", false)
	testing.expect(t, !c_ok, "empty commit message fails")
}
