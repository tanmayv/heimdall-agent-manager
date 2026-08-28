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

	fmt.println("PASS: bridge fs management")
}
