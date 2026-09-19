package bridge_fs_management_test

import "core:fmt"
import "core:os"
import "core:strings"
import bridge "odin_test:bridge"

check :: proc(ok: bool, msg: string) { if ok do return; fmt.eprintln("FAIL:", msg); os.exit(1) }

main :: proc() {
	// Build a temp sandbox: <tmp>/hamfs-<pid>/{root/{proj/.git, sub}, outside}
	base := fmt.tprintf("/tmp/hamfs-%d", os.get_pid())
	root := strings.concatenate({base, "/root"})
	proj := strings.concatenate({root, "/proj"})
	proj_git := strings.concatenate({proj, "/.git"})
	sub := strings.concatenate({root, "/sub"})
	outside := strings.concatenate({base, "/outside"})
	_ = os.make_directory_all(proj_git)
	_ = os.make_directory_all(sub)
	_ = os.make_directory_all(outside)
	defer os.remove_all(base) // best-effort recursive cleanup

	bridge.bridge_fs_init(root)

	// --- list: root shows proj (git) + sub, dirs flagged, no escape ---
	lr := bridge.bridge_fs_list_dir("")
	check(lr.ok, "list root ok")
	check(lr.path == bridge.bridge_fs_root, "list root path == resolved root")
	check(lr.parent == "", "root has no parent")
	saw_proj := false; saw_sub := false; proj_has_git := false
	for e in lr.entries {
		if e.name == "proj" { saw_proj = true; if e.is_dir && e.has_git do proj_has_git = true }
		if e.name == "sub" && e.is_dir do saw_sub = true
	}
	check(saw_proj && saw_sub, "root listing contains proj + sub")
	check(proj_has_git, "proj flagged has_git")

	// --- list a subdir: parent points back within root ---
	lp := bridge.bridge_fs_list_dir(proj)
	check(lp.ok, "list proj ok")
	check(lp.parent == bridge.bridge_fs_root, "proj parent == root")

	// --- containment: escapes are rejected ---
	esc1 := bridge.bridge_fs_list_dir(outside)               // absolute outside root
	check(!esc1.ok && esc1.error_code == "path_outside_root", "absolute outside root rejected")
	esc2 := bridge.bridge_fs_list_dir("../outside")          // relative .. escape
	check(!esc2.ok && esc2.error_code == "path_outside_root", "relative .. escape rejected")
	esc3 := bridge.bridge_fs_list_dir(strings.concatenate({root, "/../outside"})) // mixed escape
	check(!esc3.ok && esc3.error_code == "path_outside_root", "root/../outside rejected")

	// --- stat: existing dir, missing path, git detection, outside ---
	s_proj := bridge.bridge_fs_stat(proj)
	check(s_proj.ok && s_proj.exists && s_proj.is_dir && s_proj.has_git && s_proj.within_root, "stat proj: exists+dir+git+within")
	s_missing := bridge.bridge_fs_stat(strings.concatenate({root, "/nope"}))
	check(s_missing.ok && !s_missing.exists && s_missing.within_root, "stat missing: within root, not exists")
	s_out := bridge.bridge_fs_stat(outside)
	check(s_out.ok && !s_out.within_root && s_out.error_code == "path_outside_root", "stat outside: not within root")

	// --- mkdir: create new, idempotent, reject outside ---
	newp := strings.concatenate({root, "/created/deep"})
	m1 := bridge.bridge_fs_make_dir(newp)
	check(m1.ok && m1.created && m1.within_root, "mkdir -p created new")
	check(os.is_dir(newp), "mkdir actually created the dir on disk")
	m2 := bridge.bridge_fs_make_dir(newp)
	check(m2.ok && !m2.created, "mkdir idempotent (already exists)")
	m_out := bridge.bridge_fs_make_dir(strings.concatenate({base, "/evil"}))
	check(!m_out.ok && m_out.error_code == "path_outside_root", "mkdir outside root rejected")

	// --- write_file: create, overwrite, reject dir, reject outside root ---
	write_target := strings.concatenate({root, "/created/test.txt"})
	w1 := bridge.bridge_fs_write_file(write_target, "hello world 1")
	check(w1.ok && w1.within_root && w1.bytes_written == 13, "write_file created new file with content")
	rf1 := bridge.bridge_fs_read_file(write_target)
	check(rf1.ok && rf1.content == "hello world 1", "read_file matches write_file content")

	w2 := bridge.bridge_fs_write_file(write_target, "updated content 2")
	check(w2.ok && w2.within_root && w2.bytes_written == 17, "write_file overwrote existing file")
	rf2 := bridge.bridge_fs_read_file(write_target)
	check(rf2.ok && rf2.content == "updated content 2", "read_file matches updated content")

	// Target cannot be a directory
	w_dir := bridge.bridge_fs_write_file(sub, "should fail")
	check(!w_dir.ok && w_dir.error_code == "path_is_directory", "write_file rejects directory target")

	// Reject write outside root
	w_out := bridge.bridge_fs_write_file(strings.concatenate({base, "/escape.txt"}), "fail")
	check(!w_out.ok && w_out.error_code == "path_outside_root", "write_file outside root rejected")

	// --- batch_write: multi-file write and per-file saved/errors arrays ---
	batch_items := make([dynamic]bridge.Bridge_Fs_Write_Item)
	defer delete(batch_items)
	f1_path := strings.concatenate({root, "/created/batch1.txt"})
	f2_path := strings.concatenate({root, "/created/batch2.txt"})
	f_err_path := strings.concatenate({base, "/outside_batch.txt"})
	append(&batch_items, bridge.Bridge_Fs_Write_Item{path = f1_path, content = "batch content 1"})
	append(&batch_items, bridge.Bridge_Fs_Write_Item{path = f2_path, content = "batch content 2"})
	append(&batch_items, bridge.Bridge_Fs_Write_Item{path = f_err_path, content = "outside"})

	bw := bridge.bridge_fs_batch_write(batch_items)
	check(!bw.ok, "batch_write returns ok=false when errors present")
	check(len(bw.saved) == 2, "batch_write has 2 saved files")
	check(len(bw.errors) == 1, "batch_write has 1 error file")
	check(bw.errors[0].error_code == "path_outside_root", "batch_write error has path_outside_root")

	rf_b1 := bridge.bridge_fs_read_file(f1_path)
	check(rf_b1.ok && rf_b1.content == "batch content 1", "batch written file 1 content verified")
	rf_b2 := bridge.bridge_fs_read_file(f2_path)
	check(rf_b2.ok && rf_b2.content == "batch content 2", "batch written file 2 content verified")

	fmt.println("PASS: bridge fs management")
}
