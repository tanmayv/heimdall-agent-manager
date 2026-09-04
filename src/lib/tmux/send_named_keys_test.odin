package tmux

import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// Live tmux regression for the startup-probe launch bug: auto_enter_pre_keys such
// as "Down" / "Tab Tab" are tmux NAMED keys, but the probe used to send them via
// send_text (send-keys -l), which types the literal characters instead of pressing
// the key. On a fresh machine the folder-trust / ToS / bypass prompt then stayed on
// its default option and the launch hung at startup_blocked. send_named_keys sends
// each whitespace-separated token as a key press. We prove the two paths differ by
// feeding a `cat`-to-file pane a multi-token spec: named keys => "bird" (each token
// a key, spaces are separators), literal text => "b i r d" (spaces typed verbatim).
// If send_named_keys had (wrongly) used -l, both would be identical.
@(test)
send_named_keys_presses_discrete_keys_not_literal :: proc(t: ^testing.T) {
	if !tmux_binary_available() do return

	out_named := "/tmp/ham-named-keys-named.txt"
	out_literal := "/tmp/ham-named-keys-literal.txt"

	named, named_ok := run_cat_pane_capture("ham-test-nk-named", out_named, "b i r d", true)
	literal, literal_ok := run_cat_pane_capture("ham-test-nk-literal", out_literal, "b i r d", false)

	testing.expect(t, named_ok, "named cat pane produced output")
	testing.expect(t, literal_ok, "literal cat pane produced output")
	testing.expect_value(t, named, "bird")
	testing.expect_value(t, literal, "b i r d")
}

// run_cat_pane_capture spins up an isolated detached tmux session whose sole
// window runs `cat > out_file`, sends the spec (via send_named_keys when
// use_named, else send_text), flushes with Enter + Ctrl-D so cat closes its
// stdin and writes the file, then reads it back. The session is always killed.
@(private = "file")
run_cat_pane_capture :: proc(session, out_file, spec: string, use_named: bool) -> (string, bool) {
	_, _, _, _ = os.process_exec(os.Process_Desc{command = []string{"tmux", "kill-session", "-t", session}}, context.allocator)
	os.remove(out_file)
	cmd := strings.concatenate({"cat > ", shell_quote(out_file)})
	state, _, _, err := os.process_exec(os.Process_Desc{command = []string{"tmux", "new-session", "-d", "-s", session, "-n", "w", cmd}}, context.allocator)
	if err != nil || !state.success do return "", false
	defer { _, _, _, _ = os.process_exec(os.Process_Desc{command = []string{"tmux", "kill-session", "-t", session}}, context.allocator) }
	time.sleep(400 * time.Millisecond)

	pane := pane_of(session, "w")
	if pane == "" do return "", false

	sent := use_named ? send_named_keys(pane, spec, false) : send_text(pane, spec, false)
	if !sent do return "", false

	// Flush the current line then close cat's stdin (Ctrl-D) so the file is fully
	// written before we read it.
	time.sleep(200 * time.Millisecond)
	_, _, _, _ = os.process_exec(os.Process_Desc{command = []string{"tmux", "send-keys", "-t", pane, "Enter"}}, context.allocator)
	time.sleep(150 * time.Millisecond)
	_, _, _, _ = os.process_exec(os.Process_Desc{command = []string{"tmux", "send-keys", "-t", pane, "C-d"}}, context.allocator)
	time.sleep(300 * time.Millisecond)

	bytes, read_err := os.read_entire_file(out_file, context.allocator)
	if read_err != nil do return "", false
	return strings.trim_space(string(bytes)), true
}

@(private = "file")
tmux_binary_available :: proc() -> bool {
	state, _, _, err := os.process_exec(os.Process_Desc{command = []string{"tmux", "-V"}}, context.allocator)
	return err == nil && state.success
}

@(private = "file")
pane_of :: proc(session, window: string) -> string {
	target := strings.concatenate({session, ":", window})
	state, stdout, _, err := os.process_exec(os.Process_Desc{command = []string{"tmux", "display-message", "-p", "-t", target, "#{pane_id}"}}, context.allocator)
	if err != nil || !state.success do return ""
	return strings.trim_space(string(stdout))
}
