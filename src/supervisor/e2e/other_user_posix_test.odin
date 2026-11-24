#+build linux, darwin
package e2e

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

SUDO :: "/usr/bin/sudo"

// via_sh: run `cmd` under a plain /bin/sh parent of ours. os.process_wait cannot watch
// the setuid sudo process itself on macOS (the wait fails); the shell it is a child of can.
via_sh :: proc(cmd: []string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	append(&out, "/bin/sh", "-c", `"$@"; exit $?`, "sh")
	append(&out, ..cmd)
	return out[:]
}

// other_share makes files A wrote readable for B (directories traversable).
other_share :: proc(b: ^Other, path: string) {
	_ = run_cmd(b.s, {"/bin/chmod", "-R", "a+rX", path})
}

Other_Proc :: struct {
	p: os.Process,
	f: ^os.File,
}

// other_prepare: B must traverse the shared root and run the copied binaries.
other_prepare :: proc(b: ^Other) -> bool {
	bins := []string{"/bin/chmod", "0755", pj(b.bin, "ham-launcher"), pj(b.bin, "ham-supervisor")}
	res := run_cmd(b.s, bins)
	if !testing.expectf(b.s.t, res.ok && res.code == 0, "chmod binaries: %s", res.output) do return false
	res = run_cmd(b.s, {"/bin/chmod", "-R", "a+rX", b.root})
	if !testing.expectf(b.s.t, res.ok && res.code == 0, "chmod root: %s", res.output) do return false
	res = run_cmd(b.s, {"/bin/chmod", "0777", b.root})
	return testing.expectf(b.s.t, res.ok && res.code == 0, "chmod root: %s", res.output)
}

other_owner_json :: proc(b: ^Other) -> string {
	res := run_cmd(b.s, {"/usr/bin/id", "-u", b.user})
	return fmt.tprintf(`{{"uid":%s}}`, strings.trim_space(res.output))
}

// other_make_instance: B creates its roots and instance.json, then opens the roots to
// everyone, so that only the ownership check stops another user (step 3 of the test).
other_make_instance :: proc(b: ^Other, body: string) -> bool {
	i := b.inst
	res := other_run(b, {"/bin/sh", "-c", `mkdir -p "$1/supervisor" "$2" && chmod -R 0777 "$1" "$2"`, "sh", i.data, i.state})
	if !testing.expectf(b.s.t, res.ok && res.code == 0, "B mkdir: ok=%v code=%d %s", res.ok, res.code, res.output) do return false
	other_write(b, i.data, "instance.json", body)
	return testing.expect(b.s.t, os.exists(pj(i.data, "instance.json")), "B's instance.json")
}

// other_write: B writes dir/name (via a world-readable transfer file of A's).
other_write :: proc(b: ^Other, dir, name, body: string) {
	xfer := pj(b.root, "xfer")
	_ = os.make_directory_all(xfer)
	src := pj(xfer, fmt.tprintf("%d-%s", time.tick_now()._nsec, name))
	_ = os.write_entire_file(src, transmute([]byte)body)
	other_share(b, xfer)
	res := other_run(b, {"/bin/sh", "-c", `mkdir -p "$1" && cp "$2" "$1/$3.tmp" && mv "$1/$3.tmp" "$1/$3"`, "sh", dir, src, name})
	testing.expectf(b.s.t, res.ok && res.code == 0, "B writes %s: %s", name, res.output)
}

other_view_inst :: proc(b: ^Other) -> ^Inst {
	v := new(Inst)
	v.s = b.s
	v.name = strings.clone("b-view")
	v.id = strings.clone(b.inst.id)
	v.data = strings.clone(pj(b.s.base, "b-view", "data"))
	v.state = strings.clone(pj(b.s.base, "b-view", "state"))
	append(&b.s.insts, v)
	return v
}

// other_refresh copies B's data root (without release trees) to the view, as root.
other_refresh :: proc(b: ^Other) {
	script := `rm -rf "$2" && mkdir -p "$2" && cd "$1" && tar cf - --exclude releases . | (cd "$2" && tar xf -) && chown -R "$3" "$2"`
	_ = run_cmd(b.s, via_sh({SUDO, "-n", "/bin/sh", "-c", script, "sh", b.inst.data, b.view.data, fmt.tprintf("%d", posix.getuid())}))
}

other_spawn :: proc(b: ^Other, command: []string, env: []string, log_path: string) -> (Other_Proc, bool) {
	f, err := os.create(log_path)
	if err != nil do return {}, false
	full := make([dynamic]string, context.temp_allocator)
	append(&full, SUDO, "-n", "-u", b.user, "/usr/bin/env")
	append(&full, ..env)
	append(&full, ..command)
	p, perr := os.process_start({command = via_sh(full[:]), stdout = f, stderr = f})
	if perr != nil {
		testing.expectf(b.s.t, false, "start %v: %v", full[:], perr)
		os.close(f)
		return {}, false
	}
	return {p = p, f = f}, true
}

other_wait :: proc(p: ^Other_Proc, timeout: time.Duration) -> (exited: bool, code: int) {
	st, err := os.process_wait(p.p, timeout)
	if err != nil || !st.exited {
		log.warnf("other_wait: %v exited=%v", err, st.exited)
		return false, -1
	}
	if p.f != nil {
		os.close(p.f)
		p.f = nil
	}
	return true, st.exit_code
}

other_kill :: proc(p: ^Other_Proc) {
	_ = os.process_kill(p.p)
	_, _ = os.process_wait(p.p, 5 * time.Second)
	if p.f != nil {
		os.close(p.f)
		p.f = nil
	}
}

other_cleanup :: proc(b: ^Other) {
	if b.root == "" do return
	_ = run_cmd(b.s, via_sh({SUDO, "-n", "/usr/bin/pkill", "-KILL", "-u", b.user}))
	if !testing.failed(b.s.t) do _ = run_cmd(b.s, via_sh({SUDO, "-n", "/bin/rm", "-rf", b.root}))
}
