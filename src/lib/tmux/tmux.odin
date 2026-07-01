package tmux

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

Launch_Result :: struct {
	session: string,
	window: string,
	pane_id: string,
}

Session_Lock :: struct {
	path: string,
	held: bool,
}

ensure_agent_window :: proc(session, window, cwd: string, command: []string) -> (Launch_Result, bool) {
	lock := acquire_session_lock(session)
	defer release_session_lock(lock)
	return ensure_agent_window_unlocked(session, window, cwd, command)
}

ensure_agent_window_unlocked :: proc(session, window, cwd: string, command: []string) -> (Launch_Result, bool) {
	shell_command := build_shell_command(cwd, command)

	if !has_session(session) {
		// Create a stable bootstrap window first. Agent windows are always created
		// through the same new-window path, avoiding first-agent special cases.
		new_session_cmd := []string{"tmux", "new-session", "-d", "-s", session, "-n", "heimdall-bootstrap"}
		state, _, stderr, err := os.process_exec(os.Process_Desc{command = new_session_cmd}, context.allocator)
		if err != nil || !state.success {
			if has_session(session) {
				fmt.println("tmux new-session raced; session already exists", session)
			} else if len(stderr) > 0 {
				fmt.println("tmux new-session failed", string(stderr))
			}
		}
	}

	if has_session(session) {
		new_window_cmd := []string{"tmux", "new-window", "-t", session, "-n", window, shell_command}
		state, _, stderr, err := os.process_exec(os.Process_Desc{command = new_window_cmd}, context.allocator)
		if err != nil || !state.success {
			if len(stderr) > 0 {
				fmt.println("tmux new-window skipped", string(stderr))
			}
		}
	}

	for tries := 0; tries < 5; tries += 1 {
		pane_id := pane_for_window(session, window)
		if pane_id != "" {
			return Launch_Result{session = session, window = window, pane_id = pane_id}, true
		}
		if tries == 0 && has_session(session) {
			new_window_cmd := []string{"tmux", "new-window", "-t", session, "-n", window, shell_command}
			_, _, _, _ = os.process_exec(os.Process_Desc{command = new_window_cmd}, context.allocator)
		}
		time.sleep(150 * time.Millisecond)
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
		if window_name_base(name) == window {
			return strings.clone(strings.trim_space(pane))
		}
	}
	return ""
}

// window_name_base strips any of our known status prefixes ("[Starting] ",
// "[Blocked] ") from a tmux window name, so collision detection and lookups
// match the agent identity rather than its current transient status.
window_name_base :: proc(name: string) -> string {
	prefixes := []string{"[Starting] ", "[Blocked] "}
	for p in prefixes {
		if strings.has_prefix(name, p) do return name[len(p):]
	}
	return name
}

rename_window_for_pane :: proc(pane_id, new_name: string) -> bool {
	if pane_id == "" do return false
	cmd := []string{"tmux", "rename-window", "-t", pane_id, new_name}
	state, _, _, err := os.process_exec(os.Process_Desc{command = cmd}, context.allocator)
	return err == nil && state.success
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

send_text :: proc(pane_id, text: string, enter := false) -> bool {
	if pane_id == "" do return false
	ensure_not_copy_mode(pane_id)
	send_text_cmd := []string{"tmux", "send-keys", "-t", pane_id, "-l", text}
	state, _, _, err := os.process_exec(os.Process_Desc{command = send_text_cmd}, context.allocator)
	if err != nil || !state.success do return false
	if !enter do return true
	time.sleep(300 * time.Millisecond)
	enter_cmd := []string{"tmux", "send-keys", "-t", pane_id, "Enter"}
	state, _, _, err = os.process_exec(os.Process_Desc{command = enter_cmd}, context.allocator)
	return err == nil && state.success
}

send_line_with_escape :: proc(pane_id, text: string, escape_prefix: bool) -> bool {
	if pane_id == "" do return false
	ensure_not_copy_mode(pane_id)
	if escape_prefix {
		escape_cmd := []string{"tmux", "send-keys", "-t", pane_id, "Escape"}
		state, _, _, err := os.process_exec(os.Process_Desc{command = escape_cmd}, context.allocator)
		if err != nil || !state.success do return false
		time.sleep(1 * time.Second)
	}
	send_text_cmd := []string{"tmux", "send-keys", "-t", pane_id, "-l", text}
	state, _, _, err := os.process_exec(os.Process_Desc{command = send_text_cmd}, context.allocator)
	if err != nil || !state.success do return false
	// Give the TUI a moment to process the typed text before Enter arrives.
	// Without this, Claude Code's readline handler may not have consumed all
	// buffered characters, causing Enter to submit an incomplete line or be
	// swallowed entirely.
	time.sleep(300 * time.Millisecond)
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
	lock := acquire_session_lock(session)
	defer release_session_lock(lock)
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
		if window_name_base(trimmed[:tab]) == window {
			return strings.clone(strings.trim_space(trimmed[tab + 1:]))
		}
	}
	return ""
}

version :: proc() -> (string, bool) {
	cmd := []string{"tmux", "-V"}
	state, stdout, _, err := os.process_exec(os.Process_Desc{command = cmd}, context.allocator)
	if err != nil || !state.success do return "", false
	return strings.clone(strings.trim_space(string(stdout))), true
}

kill_session :: proc(name: string) -> bool {
	if name == "" do return false
	cmd := []string{"tmux", "kill-session", "-t", name}
	state, _, _, err := os.process_exec(os.Process_Desc{command = cmd}, context.allocator)
	return err == nil && state.success
}

create_throwaway_session :: proc(name: string) -> bool {
	if name == "" do return false
	cmd := []string{"tmux", "new-session", "-d", "-s", name}
	state, _, _, err := os.process_exec(os.Process_Desc{command = cmd}, context.allocator)
	return err == nil && state.success
}

build_shell_command :: proc(cwd: string, command: []string) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, "cd ")
	strings.write_string(&builder, shell_quote(cwd))
	strings.write_string(&builder, " && ( ")

	if len(command) == 0 {
		strings.write_string(&builder, "pi")
	} else {
		for arg, i in command {
			if i > 0 do strings.write_string(&builder, " ")
			strings.write_string(&builder, shell_quote(arg))
		}
	}

	strings.write_string(&builder, " ); echo 'Agent exited. Press Enter to close...'; read")
	return strings.to_string(builder)
}

acquire_session_lock :: proc(session: string) -> Session_Lock {
	lock_path := session_lock_path(session)
	_ = os.make_directory_all(parent_dir(lock_path))
	for tries := 0; tries < 300; tries += 1 {
		err := os.make_directory(lock_path)
		if err == nil {
			return Session_Lock{path = lock_path, held = true}
		}
		time.sleep(100 * time.Millisecond)
	}
	fmt.println("tmux session lock timed out; continuing without lock", lock_path)
	return Session_Lock{path = lock_path, held = false}
}

release_session_lock :: proc(lock: Session_Lock) {
	if !lock.held || lock.path == "" do return
	_ = os.remove(lock.path)
}

session_lock_path :: proc(session: string) -> string {
	data_dir := os.get_env_alloc("HEIMDALL_HOME", context.allocator)
	if data_dir == "" {
		home := os.get_env_alloc("HOME", context.allocator)
		if home != "" do data_dir = fmt.tprintf("%s/.local/share/heimdall", home)
	}
	if data_dir == "" do data_dir = ".heimdall"
	return fmt.tprintf("%s/locks/tmux-%s.lock", data_dir, safe_lock_part(session))
}

parent_dir :: proc(path: string) -> string {
	slash := strings.last_index_byte(path, '/')
	if slash <= 0 do return "."
	return path[:slash]
}

safe_lock_part :: proc(value: string) -> string {
	builder := strings.builder_make()
	for ch in value {
		switch ch {
		case 'a'..='z', 'A'..='Z', '0'..='9', '_', '-', '@', '.': strings.write_rune(&builder, ch)
		case: strings.write_string(&builder, "_")
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
