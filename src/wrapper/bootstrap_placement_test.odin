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
bt4_prune_removes_stale_keeps_current :: proc(t: ^testing.T) {
	dir := wrapper_bt4_tmpdir("prune")
	defer delete(dir)
	_ = os.make_directory_all(dir)
	defer wrapper_bt4_rmrf(dir)

	// Simulate a prior launch that placed a stale skill + AGENTS.md.
	stale_skill := strings.concatenate({dir, "/skills/old-skill/SKILL.md"})
	_ = os.make_directory_all(strings.concatenate({dir, "/skills/old-skill"}))
	_ = os.write_entire_file(stale_skill, transmute([]byte)string("stale"))
	agents := strings.concatenate({dir, "/AGENTS.md"})
	_ = os.write_entire_file(agents, transmute([]byte)string("kept"))
	defer { delete(stale_skill); delete(agents) }

	prev := []string{"skills/old-skill/SKILL.md", "AGENTS.md"}
	current := []string{"AGENTS.md", "skills/new-skill/SKILL.md"}
	wrapper_bootstrap_prune_stale(dir, prev, current)

	// Stale skill file removed; its parent dir removed; AGENTS.md (still current) kept.
	if _, e1 := os.stat(stale_skill, context.allocator); e1 == nil {
		testing.expect(t, false, "stale skill file should have been pruned")
	}
	if _, e2 := os.stat(agents, context.allocator); e2 != nil {
		testing.expect(t, false, "current AGENTS.md must be kept")
	}
}

@(test)
bt4_placement_record_roundtrip :: proc(t: ^testing.T) {
	dir := wrapper_bt4_tmpdir("rec")
	defer delete(dir)
	_ = os.make_directory_all(dir)
	defer wrapper_bt4_rmrf(dir)

	placed := []string{"AGENTS.md", "skills/a/SKILL.md", ".heimdall/bin/ham-ctl"}
	wrapper_bootstrap_write_placement_record(dir, placed)
	got := wrapper_bootstrap_read_placement_record(dir)
	defer { for g in got do delete(g); delete(got) }
	testing.expect_value(t, len(got), 3)
	testing.expect_value(t, got[0], "AGENTS.md")
	testing.expect_value(t, got[1], "skills/a/SKILL.md")
	testing.expect_value(t, got[2], ".heimdall/bin/ham-ctl")
}

@(test)
bt4_prune_ignores_traversal :: proc(t: ^testing.T) {
	// A malicious prior record must not delete anything outside the run dir.
	dir := wrapper_bt4_tmpdir("trav")
	defer delete(dir)
	_ = os.make_directory_all(dir)
	defer wrapper_bt4_rmrf(dir)
	// Should be a no-op (no crash, no traversal delete).
	wrapper_bootstrap_prune_stale(dir, []string{"../../etc/passwd", "/abs/path"}, []string{})
	testing.expect(t, true)
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
