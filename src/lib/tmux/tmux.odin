package tmux

import "core:fmt"
import "core:os"
import "core:strings"

Launch_Result :: struct {
	session: string,
	window: string,
	pane_id: string,
}

ensure_agent_window :: proc(session, window, cwd: string, command: []string) -> (Launch_Result, bool) {
	shell_command := build_shell_command(cwd, command)

	if has_session(session) {
		new_window_cmd := []string{"tmux", "new-window", "-t", session, "-n", window, shell_command}
		state, _, stderr, err := os.process_exec(os.Process_Desc{command = new_window_cmd}, context.allocator)
		if err != nil || !state.success {
			// Assume the window already exists for the POC.
			if len(stderr) > 0 {
				fmt.println("tmux new-window skipped", string(stderr))
			}
		}
	} else {
		new_session_cmd := []string{"tmux", "new-session", "-d", "-s", session, "-n", window, shell_command}
		state, _, stderr, err := os.process_exec(os.Process_Desc{command = new_session_cmd}, context.allocator)
		if err != nil || !state.success {
			if len(stderr) > 0 {
				fmt.println("tmux new-session failed", string(stderr))
			}
		}
	}

	pane_id := pane_for_window(session, window)
	return Launch_Result{session = session, window = window, pane_id = pane_id}, pane_id != ""
}

has_session :: proc(session: string) -> bool {
	has_cmd := []string{"tmux", "has-session", "-t", session}
	state, _, _, err := os.process_exec(os.Process_Desc{command = has_cmd}, context.allocator)
	return err == nil && state.success
}

pane_for_window :: proc(session, window: string) -> string {
	cmd := []string{"tmux", "list-windows", "-t", session, "-F", "#{window_name}\t#{pane_id}"}
	state, stdout, _, err := os.process_exec(os.Process_Desc{command = cmd}, context.allocator)
	if err != nil || !state.success do return ""

	lines := strings.split(string(stdout), "\n")
	defer delete(lines)
	for line in lines {
		trimmed := strings.trim_space(line)
		if trimmed == "" do continue
		tab := strings.index_byte(trimmed, '\t')
		if tab < 0 do continue
		name := trimmed[:tab]
		pane := trimmed[tab + 1:]
		if name == window {
			return strings.clone(strings.trim_space(pane))
		}
	}
	return ""
}

ensure_not_copy_mode :: proc(pane_id: string) {
	if pane_id == "" do return
	check_cmd := []string{"tmux", "display-message", "-p", "-t", pane_id, "#{pane_in_mode}"}
	state, stdout, _, err := os.process_exec(os.Process_Desc{command = check_cmd}, context.allocator)
	if err != nil || !state.success do return
	if strings.trim_space(string(stdout)) != "1" do return

	cancel_cmd := []string{"tmux", "send-keys", "-t", pane_id, "-X", "cancel"}
	_, _, _, _ = os.process_exec(os.Process_Desc{command = cancel_cmd}, context.allocator)
}

send_line :: proc(pane_id, text: string) -> bool {
	return send_line_with_escape(pane_id, text, false)
}

send_line_with_escape :: proc(pane_id, text: string, escape_prefix: bool) -> bool {
	if pane_id == "" do return false
	ensure_not_copy_mode(pane_id)
	if escape_prefix {
		escape_cmd := []string{"tmux", "send-keys", "-t", pane_id, "Escape"}
		state, _, _, err := os.process_exec(os.Process_Desc{command = escape_cmd}, context.allocator)
		if err != nil || !state.success do return false
	}
	send_text_cmd := []string{"tmux", "send-keys", "-t", pane_id, "-l", text}
	state, _, _, err := os.process_exec(os.Process_Desc{command = send_text_cmd}, context.allocator)
	if err != nil || !state.success do return false
	enter_cmd := []string{"tmux", "send-keys", "-t", pane_id, "Enter"}
	state, _, _, err = os.process_exec(os.Process_Desc{command = enter_cmd}, context.allocator)
	return err == nil && state.success
}

capture_pane_text :: proc(pane_id: string, line_limit := 80) -> (string, bool) {
	if pane_id == "" do return "", false
	limit := line_limit
	if limit <= 0 do limit = 80
	start := fmt.tprintf("-%d", limit)
	cmd := []string{"tmux", "capture-pane", "-p", "-t", pane_id, "-S", start}
	state, stdout, _, err := os.process_exec(os.Process_Desc{command = cmd}, context.allocator)
	if err != nil || !state.success do return "", false
	return string(stdout), true
}

pane_exists :: proc(pane_id: string) -> bool {
	if pane_id == "" do return false
	cmd := []string{"tmux", "display-message", "-p", "-t", pane_id, "#{pane_id}"}
	state, stdout, _, err := os.process_exec(os.Process_Desc{command = cmd}, context.allocator)
	if err != nil || !state.success do return false
	return strings.trim_space(string(stdout)) != ""
}

kill_pane :: proc(pane_id: string) -> bool {
	if pane_id == "" do return false
	cmd := []string{"tmux", "kill-pane", "-t", pane_id}
	state, _, _, err := os.process_exec(os.Process_Desc{command = cmd}, context.allocator)
	return err == nil && state.success
}

kill_window :: proc(session, window: string) -> bool {
	window_id := window_id_for_window(session, window)
	if window_id == "" do return false
	cmd := []string{"tmux", "kill-window", "-t", window_id}
	state, _, _, err := os.process_exec(os.Process_Desc{command = cmd}, context.allocator)
	return err == nil && state.success
}

window_id_for_window :: proc(session, window: string) -> string {
	cmd := []string{"tmux", "list-windows", "-t", session, "-F", "#{window_name}\t#{window_id}"}
	state, stdout, _, err := os.process_exec(os.Process_Desc{command = cmd}, context.allocator)
	if err != nil || !state.success do return ""
	lines := strings.split(string(stdout), "\n")
	defer delete(lines)
	for line in lines {
		trimmed := strings.trim_space(line)
		if trimmed == "" do continue
		tab := strings.index_byte(trimmed, '\t')
		if tab < 0 do continue
		if trimmed[:tab] == window {
			return strings.clone(strings.trim_space(trimmed[tab + 1:]))
		}
	}
	return ""
}

build_shell_command :: proc(cwd: string, command: []string) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, "cd ")
	strings.write_string(&builder, shell_quote(cwd))
	strings.write_string(&builder, " && ")

	if len(command) == 0 {
		strings.write_string(&builder, "pi")
	} else {
		for arg, i in command {
			if i > 0 do strings.write_string(&builder, " ")
			strings.write_string(&builder, shell_quote(arg))
		}
	}

	return strings.to_string(builder)
}

shell_quote :: proc(value: string) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, "'")
	for ch in value {
		if ch == '\'' {
			strings.write_string(&builder, "'\\''")
		} else {
			strings.write_rune(&builder, ch)
		}
	}
	strings.write_string(&builder, "'")
	return strings.to_string(builder)
}
