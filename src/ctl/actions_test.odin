package main

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import httpc "odin_test:lib/httpc"

// Track ordinary allocations independently of command-scoped temporary storage.
// Releasing the temporary arena is the same ownership boundary as a CLI command.
ctl_actions_test_tracked :: proc(t: ^testing.T, scenario: proc(t: ^testing.T)) {
	heap, scratch: mem.Tracking_Allocator
	mem.tracking_allocator_init(&heap, context.allocator)
	defer mem.tracking_allocator_destroy(&heap)
	arena: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) do return
	defer virtual.arena_destroy(&arena)
	mem.tracking_allocator_init(&scratch, virtual.arena_allocator(&arena))
	defer mem.tracking_allocator_destroy(&scratch)
	{
		context.allocator = mem.tracking_allocator(&heap)
		context.temp_allocator = mem.tracking_allocator(&scratch)
		scenario(t)
		free_all(context.temp_allocator)
	}
	testing.expect_value(t, len(scratch.allocation_map), 0)
	testing.expect_value(t, len(heap.allocation_map), 0)
}

ctl_actions_test_json :: proc(t: ^testing.T, req: Ctl_Request, expected: string) {
	body, ok := ctl_request_body_text(req.body)
	if !testing.expect(t, ok, "JSON body encoded") do return
	got, gok := ctl_parse_json_document(body)
	want, wok := ctl_parse_json_document(expected)
	if !testing.expect(t, gok && wok, body) do return
	got_json, gerr := json.marshal(got, json.Marshal_Options{sort_maps_by_key = true}, context.temp_allocator)
	want_json, werr := json.marshal(want, json.Marshal_Options{sort_maps_by_key = true}, context.temp_allocator)
	testing.expect(t, gerr == nil && werr == nil)
	testing.expect_value(t, string(got_json), string(want_json))
}

@(test)
test_ctl_actions_create_body :: proc(t: ^testing.T) {
	ctl_actions_test_tracked(t, proc(t: ^testing.T) {
		req, ok := ctl_actions_request({"create"}, {
			"--prompt", "Review \"quoted\" text", "--name", "Nightly", "--agent-id", "agt_1",
			"--project", "prj_1", "--instance-strategy", "fresh_per_run", "--min-interval", "90", "--disabled",
			"--trigger", "cron:0 9 * * 1-5@America/New_York",
			"--trigger", "event:chain.state,state=completed",
			"--rule", "*:claude", "--rule", "brg_1:codex:gpt",
		})
		testing.expect(t, ok)
		testing.expect_value(t, req.method, httpc.Method.POST)
		testing.expect_value(t, ctl_test_target(t, req), "/api/v1/actions")
		ctl_actions_test_json(t, req, `{"name":"Nightly","prompt_text":"Review \"quoted\" text","enabled":false,"min_interval_s":90,
			"target":{"kind":"agent","agent_id":"agt_1","project_id":"prj_1","instance_strategy":"fresh_per_run",
			"rules":[{"bridge_id":"*","provider":"claude","model":"*"},{"bridge_id":"brg_1","provider":"codex","model":"gpt"}]},
			"triggers":[{"kind":"schedule","config":{"mode":"cron","cron_expr":"0 9 * * 1-5","timezone":"America/New_York"}},
			{"kind":"event","config":{"event_type":"chain.state","data":{"state":"completed"}}}]}`)
		// The server supplies defaults; creating a disabled action is explicit.
		minimal, mok := ctl_actions_request({"create"}, {"--prompt", "P", "--instance", "inst_1"})
		testing.expect(t, mok)
		ctl_actions_test_json(t, minimal, `{"prompt_text":"P","target":{"kind":"instance","instance_id":"inst_1"}}`)
		// Bot capability is deliberately left to the server.
		bot, bok := ctl_actions_request({"create"}, {"--prompt", "P", "--bot", "bot_1"})
		testing.expect(t, bok)
		ctl_actions_test_json(t, bot, `{"prompt_text":"P","target":{"kind":"bot","bot_id":"bot_1"}}`)
		for args in ([][]string{
			{"--instance", "inst_1"},
			{"--prompt", "P"},
			{"--prompt", "P", "--agent-id", "a", "--instance", "i"},
			{"--prompt", "P", "--bot", "b", "--rule", "*:codex"},
			{"--prompt", "P", "--agent-id", "a", "--rule", "bad"},
			{"--prompt", "P", "--agent-id", "a", "--rule", "b:p:"},
			{"--prompt", "P", "--agent-id", "a", "--min-interval", "wat"},
			{"--prompt", "P", "--agent-id"},
		}) {
			_, valid := ctl_actions_request({"create"}, args)
			testing.expect(t, !valid, "malformed create is rejected before I/O")
		}
	})
}

@(test)
test_ctl_actions_trigger_specs :: proc(t: ^testing.T) {
	ctl_actions_test_tracked(t, proc(t: ^testing.T) {
		cases := []struct {spec, config: string}{
			{"cron:0 9 * * 1-5@America/New_York", `{"mode":"cron","cron_expr":"0 9 * * 1-5","timezone":"America/New_York"}`},
			{"cron:0 * * * *", `{"mode":"cron","cron_expr":"0 * * * *","timezone":"UTC"}`},
			// No cron validation here, and the LAST @ is the separator.
			{"cron:not@validated@UTC", `{"mode":"cron","cron_expr":"not@validated","timezone":"UTC"}`},
			{"every:600", `{"mode":"interval","interval_s":600}`},
			{"at:2026-12-01T09:00:00+05:30", `{"mode":"once","run_at":"2026-12-01T09:00:00+05:30"}`},
			{"event:chain.state,chain=chain_1,state=completed,other=a=b", `{"event_type":"chain.state","chain_id":"chain_1","data":{"state":"completed","other":"a=b"}}`},
		}
		for c in cases {
			req, ok := ctl_actions_request({"update", "act_1"}, {"--trigger", c.spec})
			testing.expect(t, ok, c.spec)
			kind := "schedule"
			if strings.has_prefix(c.spec, "event:") do kind = "event"
			ctl_actions_test_json(t, req, strings.concatenate({`{"triggers":[{"kind":"`, kind, `","config":`, c.config, `}]}`}, context.temp_allocator))
		}
		raw := `{"id":"trg_1","kind":"schedule","enabled":false,"config":{"mode":"once","run_at":"2026-12-01T09:00:00Z","blackout_dates":["2026-12-02"],"active_from":"2026-11-01T00:00:00Z","active_until":"2027-01-01T00:00:00Z"}}`
		mixed, ok := ctl_actions_request({"update", "act_1"}, {"--trigger", "every:60", "--trigger-json", raw, "--trigger", "event:chain.state"})
		testing.expect(t, ok)
		ctl_actions_test_json(t, mixed, strings.concatenate({`{"triggers":[{"kind":"schedule","config":{"mode":"interval","interval_s":60}},`, raw, `,{"kind":"event","config":{"event_type":"chain.state","data":{}}}]}`}, context.temp_allocator))
		for bad in ([]string{"", "bad", "unknown:value", "cron:", "cron:x@", "every:no", "every:0", "event:", "event:chain.state,bad", "event:chain.state,=value", "event:chain.state,state="}) {
			output := ctl_actions_response({}, {"update", "act_1"}, {"--trigger", bad})
			testing.expect_value(t, output, CTL_ACTIONS_USAGE)
		}
		for bad in ([]string{"{bad", "[]", "null", `{"kind":"event"} trailing`}) {
			testing.expect_value(t, ctl_actions_response({}, {"update", "act_1"}, {"--trigger-json", bad}), CTL_ACTIONS_USAGE)
		}
		testing.expect_value(t, ctl_actions_response({}, {"update", "act_1"}, {"--trigger"}), CTL_ACTIONS_USAGE)
	})
}

@(test)
test_ctl_actions_update_partial :: proc(t: ^testing.T) {
	ctl_actions_test_tracked(t, proc(t: ^testing.T) {
		req, ok := ctl_actions_request({"update", "act 1/x"}, {"--name", ""})
		testing.expect(t, ok)
		testing.expect_value(t, req.method, httpc.Method.PATCH)
		testing.expect_value(t, ctl_test_target(t, req), "/api/v1/actions/act%201%2Fx")
		ctl_actions_test_json(t, req, `{"name":""}`)
		prompt, pok := ctl_actions_request({"update", "act_1"}, {"--prompt", "New"})
		testing.expect(t, pok)
		ctl_actions_test_json(t, prompt, `{"prompt_text":"New"}`)
		target, tok := ctl_actions_request({"update", "act_1"}, {"--agent-id", "agt_2", "--rule", "*:*:*"})
		testing.expect(t, tok)
		ctl_actions_test_json(t, target, `{"target":{"kind":"agent","agent_id":"agt_2","rules":[{"bridge_id":"*","provider":"*","model":"*"}]}}`)
		instance, iok := ctl_actions_request({"update", "act_1"}, {"--instance", "inst_2", "--min-interval", "5"})
		testing.expect(t, iok)
		ctl_actions_test_json(t, instance, `{"target":{"kind":"instance","instance_id":"inst_2"},"min_interval_s":5}`)
		triggers, trok := ctl_actions_request({"update", "act_1"}, {"--trigger-json", `{"id":"trg_1","kind":"event","config":{"event_type":"chain.state"}}`})
		testing.expect(t, trok)
		ctl_actions_test_json(t, triggers, `{"triggers":[{"id":"trg_1","kind":"event","config":{"event_type":"chain.state"}}]}`)
		_, incomplete := ctl_actions_request({"update", "act_1"}, {"--project", "prj_1"})
		testing.expect(t, !incomplete, "replacement target needs its kind/id")
		testing.expect(t, strings.contains(CTL_ACTIONS_HELP, "replaces the whole trigger list"))
		testing.expect(t, strings.contains(CTL_ACTIONS_HELP, "replaces the whole target"))
	})
}

@(test)
test_ctl_actions_enable_disable_runs_delete :: proc(t: ^testing.T) {
	ctl_actions_test_tracked(t, proc(t: ^testing.T) {
		cases := []struct {verb, target: string, method: httpc.Method}{
			{"list", "/api/v1/actions", .GET},
			{"show", "/api/v1/actions/act_1", .GET},
			{"enable", "/api/v1/actions/act_1/enable", .POST},
			{"disable", "/api/v1/actions/act_1/disable", .POST},
			{"delete", "/api/v1/actions/act_1", .DELETE},
			{"runs", "/api/v1/actions/act_1/runs", .GET},
		}
		for c in cases {
			req, ok := ctl_actions_request({c.verb, "act_1"}, nil)
			testing.expect(t, ok, c.verb)
			testing.expect_value(t, req.method, c.method)
			testing.expect_value(t, ctl_test_target(t, req), c.target)
			if c.method == .POST do ctl_actions_test_json(t, req, "{}")
		}
		req, ok := ctl_actions_request({"runs", "act_1"}, {"--limit", "17", "--before", "2026-12-01T09:00:00+05:30"})
		testing.expect(t, ok)
		testing.expect_value(t, ctl_test_target(t, req), "/api/v1/actions/act_1/runs?limit=17&before=2026-12-01T09%3A00%3A00%2B05%3A30")
		// Capture a real request against the existing loopback fixture, and capture
		// the exact response the command prints, without a running hub.
		reply := `{"data":[{"id":"arun_1","state":"routed","reason":"future_server_reason","delivery_expires_at":"2026-12-02T09:00:00Z"}]}`
		fh := fake_hub_start(t, fmt.tprintf("HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s", len(reply), reply))
		if fh == nil do return
		defer fake_hub_stop(fh)
		hub := ctl_hub_make(fmt.tprintf("http://127.0.0.1:%d", fh.port), "test")
		printed := ctl_actions_response(hub, {"runs", "act_1"}, {"--limit", "17"})
		testing.expect_value(t, printed, reply)
		testing.expect(t, strings.contains(printed, "routed") && strings.contains(printed, "2026-12-02T09:00:00Z"))
		testing.expect(t, strings.has_prefix(string(fh.request[:fh.req_len]), "GET /api/v1/actions/act_1/runs?limit=17 HTTP/1.1"))
		// Server 422s are also printed, without filtering bot targets locally.
		error_reply := `{"error":{"details_json":"target_kind_unavailable"}}`
		efh := fake_hub_start(t, fmt.tprintf("HTTP/1.1 422 Unprocessable Entity\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s", len(error_reply), error_reply))
		if efh == nil do return
		defer fake_hub_stop(efh)
		error_hub := ctl_hub_make(fmt.tprintf("http://127.0.0.1:%d", efh.port), "test")
		testing.expect_value(t, ctl_actions_response(error_hub, {"create"}, {"--prompt", "P", "--bot", "bot_1"}), error_reply)
	})
}

@(test)
test_ctl_actions_no_run_verb :: proc(t: ^testing.T) {
	ctl_actions_test_tracked(t, proc(t: ^testing.T) {
		testing.expect_value(t, ctl_actions_response({}, {"run", "x"}, nil), CTL_ACTIONS_USAGE)
		testing.expect(t, !strings.contains(CTL_ACTIONS_USAGE, "|run>") && !strings.contains(CTL_ACTIONS_USAGE, "|run|"))
		testing.expect(t, !strings.contains(CTL_ACTIONS_HELP, "scheduled-prompt"))
	})
}
