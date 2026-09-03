package main

// BT-4: tests for the wrapper's fetch-and-place bootstrap logic — kind->path
// placement (PROV-1), skill-name recovery, safe-name checks, and the stale-file
// prune pass across launches.

import "core:os"
import "core:strings"
import "core:testing"

@(test)
bt4_place_agents_md_provider_name :: proc(t: ^testing.T) {
	// Explicit provider bootstrap_file_name wins.
	p := wrapper_bootstrap_place("AGENTS_MD", "AGENTS.md", "codex", "AGENTS.md", "skills")
	defer delete(p)
	testing.expect_value(t, p, "AGENTS.md")
	// claude provider -> CLAUDE.md even when the bridge relative_path is AGENTS.md.
	c := wrapper_bootstrap_place("AGENTS_MD", "AGENTS.md", "claude", "", "skills")
	defer delete(c)
	testing.expect_value(t, c, "CLAUDE.md")
	// fallback to bridge relative_path.
	f := wrapper_bootstrap_place("AGENTS_MD", "AGENTS.md", "other", "", "skills")
	defer delete(f)
	testing.expect_value(t, f, "AGENTS.md")
}

@(test)
bt4_place_skill_rebuilds_slug_path :: proc(t: ^testing.T) {
	// SKILL placement rebuilds <skill_dir>/<slug>/SKILL.md from layout + slug.
	p := wrapper_bootstrap_place("SKILL", ".agents/skills/worker-task-management/SKILL.md", "codex", "", "skills")
	defer delete(p)
	testing.expect_value(t, p, "skills/worker-task-management/SKILL.md")
}

@(test)
bt4_place_ctl_wrapper_fixed :: proc(t: ^testing.T) {
	p := wrapper_bootstrap_place("CTL_WRAPPER", "whatever", "codex", "", "skills")
	defer delete(p)
	testing.expect_value(t, p, ".heimdall/bin/ham-ctl")
}

@(test)
bt4_skill_name_from_path :: proc(t: ^testing.T) {
	a := wrapper_bootstrap_skill_name_from_path(".agents/skills/coordinator-task-management/SKILL.md")
	defer delete(a)
	testing.expect_value(t, a, "coordinator-task-management")
	b := wrapper_bootstrap_skill_name_from_path("nope.txt")
	defer delete(b)
	testing.expect_value(t, b, "")
}

@(test)
bt4_is_safe_name :: proc(t: ^testing.T) {
	testing.expect(t, wrapper_bootstrap_is_safe_name("AGENTS.md"))
	testing.expect(t, !wrapper_bootstrap_is_safe_name("../escape"))
	testing.expect(t, !wrapper_bootstrap_is_safe_name("a/b"))
	testing.expect(t, !wrapper_bootstrap_is_safe_name("."))
}

@(test)
bt4_rmdir_all_clears_run_dir :: proc(t: ^testing.T) {
	// wrapper_bootstrap_rmdir_all removes all contents recursively so the run dir
	// is always a clean slate before materialisation (replaces the prune approach).
	dir := wrapper_bt4_tmpdir("rmdir")
	defer delete(dir)
	_ = os.make_directory_all(dir)
	// put a stale CLAUDE.md + a skill subdir
	claude := strings.concatenate({dir, "/CLAUDE.md"})
	_ = os.write_entire_file(claude, transmute([]byte)string("old content"))
	defer delete(claude)
	skill_dir := strings.concatenate({dir, "/skills/old-skill"})
	_ = os.make_directory_all(skill_dir)
	defer delete(skill_dir)
	skill_file := strings.concatenate({skill_dir, "/SKILL.md"})
	_ = os.write_entire_file(skill_file, transmute([]byte)string("old skill"))
	defer delete(skill_file)

	wrapper_bootstrap_rmdir_all(dir)
	_ = os.make_directory_all(dir) // recreate as materialise would

	// CLAUDE.md and skill must be gone; dir must exist and be empty
	if _, e := os.stat(claude, context.allocator); e == nil {
		testing.expect(t, false, "CLAUDE.md should have been removed")
	}
	if _, e := os.stat(skill_file, context.allocator); e == nil {
		testing.expect(t, false, "old skill file should have been removed")
	}
	if _, e := os.stat(dir, context.allocator); e != nil {
		testing.expect(t, false, "run dir should exist after recreate")
	}
}

// --- helpers ---------------------------------------------------------------

wrapper_bt4_counter: int

wrapper_bt4_tmpdir :: proc(tag: string) -> string {
	wrapper_bt4_counter += 1
	b := strings.builder_make()
	strings.write_string(&b, "/tmp/ham_bt4_")
	strings.write_string(&b, tag)
	strings.write_byte(&b, '_')
	strings.write_int(&b, wrapper_bt4_counter)
	return strings.to_string(b)
}

wrapper_bt4_rmrf :: proc(dir: string) {
	// best-effort recursive removal for the test temp dir.
	fd, err := os.open(dir)
	if err == nil {
		if infos, rerr := os.read_dir(fd, -1, context.allocator); rerr == nil {
			for info in infos {
				full := strings.concatenate({dir, "/", info.name})
				if info.type == .Directory { wrapper_bt4_rmrf(full) } else { _ = os.remove(full) }
				delete(full)
			}
			delete(infos)
		}
		os.close(fd)
	}
	_ = os.remove(dir)
}
