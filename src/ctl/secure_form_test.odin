package main

import "core:encoding/json"
import "core:testing"

@(test)
test_secure_form_cli_admission_defaults_and_bounds :: proc(t: ^testing.T) {
	run, schema, valid := ctl_secure_form_args("run", {"secure-form", "run", "--form", "form.json", "--script", "/scripts/login.sh"})
	testing.expect(t, valid && schema == "form.json" && run.timeout == 180 && run.execution_timeout == 60)
	_, _, relative := ctl_secure_form_args("run", {"--form", "form.json", "--script", "login.sh"})
	testing.expect(t, !relative)
	_, _, short := ctl_secure_form_args("run", {"--form", "form.json", "--script", "/scripts/login.sh", "--timeout", "9"})
	testing.expect(t, !short)
	_, _, long_execution := ctl_secure_form_args("run", {"--form", "form.json", "--script", "/scripts/login.sh", "--execution-timeout", "601"})
	testing.expect(t, !long_execution)
	_, _, duplicate := ctl_secure_form_args("run", {"--form", "form.json", "--form", "other.json", "--script", "/scripts/login.sh"})
	testing.expect(t, !duplicate)
	_, _, spoof := ctl_secure_form_args("run", {"--form", "form.json", "--script", "/scripts/login.sh", "--instance", "other"})
	testing.expect(t, !spoof)
	id :: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	retry, _, predecessor := ctl_secure_form_args("retry", {"--request", id, "--after-attempt", "2"})
	testing.expect(t, predecessor && retry.request_id == id && retry.after_attempt == 2)
	_, _, wrong := ctl_secure_form_args("retry", {"--request", id, "--after-attempt", "02"})
	testing.expect(t, !wrong)
}

@(test)
test_secure_form_cli_encodes_only_method_params :: proc(t: ^testing.T) {
	opts := Secure_Form_CLI_Request{
		schema = "demo", script = "/demo.sh", request_id = "public", poll_token = "private",
		after_attempt = 1, attempt = 2, timeout = 180, execution_timeout = 60, env = {"NORMAL=value"},
	}
	for method in ([]string{"agent.secure_form.run", "agent.secure_form.retry", "agent.secure_form.poll", "agent.secure_form.cancel"}) {
		raw, marshal_err := ctl_secure_form_encode(method, opts)
		defer delete(raw)
		root, parse_err := json.parse_string(string(raw), .JSON, true, context.temp_allocator)
		obj, ok := root.(json.Object)
		if !testing.expect(t, marshal_err == nil && parse_err == nil && ok) do return
		switch method {
		case "agent.secure_form.run":
			testing.expect(t, len(obj) == 5 && "schema" in obj && !("poll_token" in obj))
		case "agent.secure_form.retry":
			testing.expect(t, len(obj) == 3 && "after_attempt" in obj && !("script" in obj))
		case:
			testing.expect(t, len(obj) == 3 && "poll_token" in obj && !("env" in obj))
		}
	}
}

@(test)
test_secure_form_owner_link_has_no_private_reply_fields :: proc(t: ^testing.T) {
	id :: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	link :: "https://ui.example.test/#/secure-forms/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	reply := Secure_Form_CLI_Reply{request_id = id, poll_token = "private-poll", stdout_b64 = "private-output"}
	testing.expect_value(t, ctl_secure_form_owner_link_line(reply, id), "")
	reply.owner_link = link
	testing.expect_value(t, ctl_secure_form_owner_link_line(reply, id), "secure-form owner link: " + link)
	testing.expect_value(t, ctl_secure_form_owner_link_line(reply, "different-id"), "")
	reply.owner_link = "https://user:password@hub.example.test/#/secure-forms/" + id
	testing.expect_value(t, ctl_secure_form_owner_link_line(reply, id), "")
}
