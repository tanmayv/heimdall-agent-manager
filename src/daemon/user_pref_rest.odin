package main

import "core:fmt"
import "core:net"
import "core:strings"

PREFERENCE_KEYS := []string{
	"starter_prompt",
	"bootstrap_header",
	"bootstrap_title",
	"bootstrap_profile_guidance",
	"msg_agent_message",
	"msg_task_updated",
	"msg_task_updated_empty",
	"msg_memory_updated",
	"msg_memory_proposal_updated",
	"msg_user_chat",
	"msg_token_refreshed",
	"msg_stop_requested",
}

get_preference_default :: proc(key: string, agent_class := "") -> (value: string, interrupt: bool) {
	switch key {
	case "starter_prompt":
		if agent_class != "" {
			for cmd in server_config.wrapper.agent_commands {
				if cmd.name == agent_class && cmd.starter_prompt != "" {
					return cmd.starter_prompt, false
				}
			}
		}
		if len(server_config.wrapper.agent_commands) > 0 {
			for cmd in server_config.wrapper.agent_commands {
				if cmd.starter_prompt != "" do return cmd.starter_prompt, false
			}
		}
		return "First, run: {ctl_bin} --token {token} start-success. Then read your bootstrap file (AGENTS.md or CLAUDE.md) for context, identity, and what you can do.", false

	case "bootstrap_header":
		return "<!-- HEIMDALL-MANAGED-BOOTSTRAP v1: safe to overwrite -->", false

	case "bootstrap_title":
		return "# Agent bootstrap for Heimdall AI Manager", false

	case "bootstrap_profile_guidance":
		profile_desc := "- Pi profile: this generated `AGENTS.md` is the primary run-directory instruction file. Read inbox/task state before beginning new work.\n"
		if agent_class == "claude" {
			profile_desc = "- Claude profile: this generated `CLAUDE.md` is the primary local instruction file. Keep tool/reference notes concise and fetch details through Heimdall CLI/RPC when needed.\n"
		} else if agent_class == "codex" {
			profile_desc = "- Codex profile: this generated `AGENTS.md` follows repository-agent instruction conventions. Prefer scoped, auditable edits and run relevant validation before handoff.\n"
		}

		return fmt.tprintf(
			"# Heimdall Tooling\n" +
			"- Use repo-local `{{ctl_bin}} --config ./config.toml ...` for Heimdall task, chat, project, and memory workflows when available.\n" +
			"- Track non-trivial/verifiable work in Heimdall tasks; keep status current and request review when complete.\n\n" +
			"%s\n" +
			"# Agent Operating Rules\n" +
			"These rules govern how you work. Follow them every session.\n\n" +
			"## 1. Always track work in Heimdall tasks\n" +
			"Every non-trivial unit of work must be tracked in a Heimdall task. On startup:\n" +
			"- Run `tasks next` to claim your assigned work. If a task is already `in_progress` for you, continue it.\n" +
			"- Check `inbox` for pending messages before starting anything new.\n" +
			"- Do not start new work without a task to anchor it.\n\n" +
			"## 2. Ad-hoc work goes in the ad-hoc chain\n" +
			"If a user asks you to do something that is not part of your current assigned task chain, create or reuse a chain called `ad-hoc-{{instance}}`. Create a task in that chain, do the work, and mark it complete.\n\n" +
			"## 3. Always reply to user@operator messages\n" +
			"When you receive a message from `user@operator` (or any user), always send a reply via `chat send-to-user`. Never leave a user message unanswered.\n\n" +
			"## 4. Confirm before acting on unverified requests\n" +
			"If a user asks you to do something and you have no task evidence or memory that this was previously planned and approved:\n" +
			"1. Do NOT start the work.\n" +
			"2. Send the user a plan of action via `chat send-to-user` describing what you will do and why.\n" +
			"3. Wait for confirmation before proceeding.\n\n" +
			"# Rich Interactive Messaging (Q&A Cards)\n" +
			"When you need to ask the user a question, present options, or request confirmation, do NOT send plain text. Instead, use rich interactive cards so the user can answer with a single click. Choose the correct type below based on the scenario:\n\n" +
			"## 1. Smart Replies (Highly Encouraged & Default for Simple Queries)\n" +
			"**Scenario:** Use this for simple, single-turn questions that have short, common responses (e.g. Yes/No, Proceed/Stop, confirming choices, selecting a model, or asking to view a diff).\n" +
			"**UX Behavior:** The UI renders these as quick-action pill buttons directly above the text input composer, allowing the user to click to reply instantly or type a custom message.\n" +
			"**CLI Command:** Use `--type smart_answer` and pass a JSON payload containing only `body` (the question text) and `suggested_replies` (array of strings) inside `--data`. The CLI will automatically validate the schema and inject the type key:\n" +
			"`{{ctl_bin}} chat send-to-user --user-id user@operator --type smart_answer --data '{{\"body\":\"Should I proceed with committing these changes?\",\"suggested_replies\":[\"Yes, do it\",\"No, wait\",\"Show diff first\"]}}'`\n\n" +
			"## 2. Single Question Card (Pill Buttons inside Message)\n" +
			"**Scenario:** Use this when you want to ask a single multiple-choice question where the answer choices are embedded directly inside the message bubble history rather than above the input box (e.g. choosing a setup template or a specific file to edit).\n" +
			"**UX Behavior:** The UI renders the choices as pill buttons directly inside the chat bubble history. Clicking one submits the response and disables other choices.\n" +
			"**CLI Command:** Use `--type questions` and pass a JSON payload containing `question` (the question text) and `suggested_answers` (array of strings) inside `--data`:\n" +
			"`{{ctl_bin}} chat send-to-user --user-id user@operator --type questions --data '{{\"question\":\"Which setup template should I initialize?\",\"suggested_answers\":[\"Web Frontend\",\"CLI Tool\",\"Daemon Service\"]}}'`\n\n" +
			"## 3. Multi-Question Wizard (Questionnaire Card)\n" +
			"**Scenario:** Use this ONLY when you have a set of multiple distinct questions to ask the user (e.g. configuring a new project, setting up environment preferences, or running an interactive onboarding survey).\n" +
			"**UX Behavior:** The UI renders this as a gorgeous step-by-step wizard card (one question at a time) with 'Back' and 'Next' buttons, concluding with a 'Submit' button. Upon submission, it compiles all answers into a single structured response and sends it back to you.\n" +
			"**CLI Command:** Use `--type questions` and pass a JSON payload containing a `questions` array of objects (each having `text` and `options`) inside `--data`:\n" +
			"`{{ctl_bin}} chat send-to-user --user-id user@operator --type questions --data '{{\"questions\":[{{\"text\":\"What language should I use?\",\"options\":[\"Odin\",\"TS\"]}},{{\"text\":\"Should I run validation tests?\",\"options\":[\"Yes, run all\",\"No, skip\"]}}]}}'`",
			profile_desc,
		), false

	case "msg_agent_message":
		return "{pending_count} Unread Messages from {from_agent_id}.", false

	case "msg_task_updated":
		return "Task {task_id} {status} by {changed_by}: {body}", false

	case "msg_task_updated_empty":
		return "Task {task_id} {status} by {changed_by}.", false

	case "msg_memory_updated":
		return "Memory {memory_id} {event} by {changed_by} for {subject_agent} ({status}). Fetch details with: {ctl_bin} memory show --token <your token> --memory-id {memory_id}", false

	case "msg_memory_proposal_updated":
		return "Memory proposal {proposal_id} {event} by {changed_by} for {subject_agent}. Review with: {ctl_bin} memory history --token <your token> --memory-id {memory_id}", false

	case "msg_user_chat":
		return "{pending_count} User Chat Messages from {user_id}. Read with: {ctl_bin} chat fetch-user --token <your token> --user-id {user_id}", true

	case "msg_token_refreshed":
		return "SYSTEM: Heimdall daemon restarted and issued a new agent token. Your previous token is invalid. New token: {new_token} — update all pending ham-ctl commands to use this token. Run: {ctl_bin} --daemon-url {daemon_url} --token {new_token} start-success", true

	case "msg_stop_requested":
		if server_config.wrapper.stop_message != "" {
			return server_config.wrapper.stop_message, true
		}
		return "SYSTEM: Stop requested. You have {time} seconds to save your work.", true
	}
	return "", false
}

handle_get_preferences :: proc(client: net.TCP_Socket, ctx: ^Route_Context) {
	user_id, ok := rest_authorize(client, ctx)
	if !ok do return

	custom_prefs, db_ok := user_pref_db_load_all(user_id)
	if !db_ok {
		write_response(client, 500, "Internal Server Error", `{"error":"database_error","message":"failed to load preferences"}`)
		return
	}
	defer delete(custom_prefs)

	b := strings.builder_make()
	strings.write_string(&b, `{"preferences":[`)

	for key, idx in PREFERENCE_KEYS {
		if idx > 0 do strings.write_string(&b, ",")

		val := ""
		interrupt := false
		is_custom := false

		if custom, found := custom_prefs[key]; found {
			val = custom.value
			interrupt = custom.interrupt
			is_custom = true
		} else {
			val, interrupt = get_preference_default(key)
		}

		def_val, def_int := get_preference_default(key)

		strings.write_string(&b, `{"key":"`)
		strings.write_string(&b, key)
		strings.write_string(&b, `","value":"`)
		json_write_string(&b, val)
		strings.write_string(&b, `","interrupt":`)
		strings.write_string(&b, interrupt ? "true" : "false")
		strings.write_string(&b, `,"is_custom":`)
		strings.write_string(&b, is_custom ? "true" : "false")
		strings.write_string(&b, `,"default_value":"`)
		json_write_string(&b, def_val)
		strings.write_string(&b, `","default_interrupt":`)
		strings.write_string(&b, def_int ? "true" : "false")
		strings.write_string(&b, `}`)

		if is_custom {
			delete(custom_prefs[key].value)
		}
	}

	strings.write_string(&b, `]}`)
	write_response(client, 200, "OK", strings.to_string(b))
}

handle_post_preference :: proc(client: net.TCP_Socket, body: string, ctx: ^Route_Context) {
	user_id, ok := rest_authorize(client, ctx)
	if !ok do return

	key := extract_json_string(body, "key", "")
	value := extract_json_string(body, "value", "")
	interrupt := extract_json_bool(body, "interrupt", false)

	if key == "" {
		write_response(client, 400, "Bad Request", `{"error":"bad_request","message":"missing key"}`)
		return
	}

	// Validate key
	valid_key := false
	for k in PREFERENCE_KEYS {
		if k == key {
			valid_key = true
			break
		}
	}
	if !valid_key {
		write_response(client, 400, "Bad Request", `{"error":"bad_request","message":"invalid preference key"}`)
		return
	}

	if !user_pref_db_set(user_id, key, value, interrupt) {
		write_response(client, 500, "Internal Server Error", `{"error":"database_error","message":"failed to save preference"}`)
		return
	}

	// Return updated preference
	pref, found := user_pref_db_get(user_id, key)
	if !found {
		write_response(client, 500, "Internal Server Error", `{"error":"database_error","message":"failed to retrieve saved preference"}`)
		return
	}
	defer delete(pref.value)

	def_val, def_int := get_preference_default(key)

	resp := fmt.tprintf(
		`{"ok":true,"preference":{"key":"%s","value":"%s","interrupt":%t,"is_custom":true,"default_value":"%s","default_interrupt":%t}}`,
		key, pref.value, pref.interrupt, def_val, def_int,
	)
	write_response(client, 200, "OK", resp)
}

handle_delete_preference :: proc(client: net.TCP_Socket, key: string, ctx: ^Route_Context) {
	user_id, ok := rest_authorize(client, ctx)
	if !ok do return

	// Validate key
	valid_key := false
	for k in PREFERENCE_KEYS {
		if k == key {
			valid_key = true
			break
		}
	}
	if !valid_key {
		write_response(client, 400, "Bad Request", `{"error":"bad_request","message":"invalid preference key"}`)
		return
	}

	if !user_pref_db_delete(user_id, key) {
		write_response(client, 500, "Internal Server Error", `{"error":"database_error","message":"failed to delete preference"}`)
		return
	}

	// Return fallback default preference
	def_val, def_int := get_preference_default(key)

	resp := fmt.tprintf(
		`{"ok":true,"preference":{"key":"%s","value":"%s","interrupt":%t,"is_custom":false,"default_value":"%s","default_interrupt":%t}}`,
		key, def_val, def_int, def_val, def_int,
	)
	write_response(client, 200, "OK", resp)
}

serialize_all_preferences_json :: proc(user_id: string, agent_class := "") -> string {
	custom_prefs, db_ok := user_pref_db_load_all(user_id)
	defer if db_ok {
		for key, value in custom_prefs {
			delete(custom_prefs[key].value)
		}
		delete(custom_prefs)
	}

	b := strings.builder_make()
	strings.write_string(&b, "{")
	
	first := true
	for key in PREFERENCE_KEYS {
		if !first do strings.write_string(&b, ",")
		first = false

		val := ""
		interrupt := false
		if db_ok {
			if custom, found := custom_prefs[key]; found {
				val = custom.value
				interrupt = custom.interrupt
			}
		}
		
		if val == "" {
			val, interrupt = get_preference_default(key, agent_class)
		}

		strings.write_string(&b, `"`)
		strings.write_string(&b, key)
		strings.write_string(&b, `":"`)
		json_write_string(&b, val)
		strings.write_string(&b, `","`)
		strings.write_string(&b, key)
		strings.write_string(&b, `_interrupt":`)
		strings.write_string(&b, interrupt ? "true" : "false")
	}
	strings.write_string(&b, "}")
	return strings.to_string(b)
}
