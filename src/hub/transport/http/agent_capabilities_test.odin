package http

import "core:fmt"
import "core:log"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import agent_service "odin_test:hub/service/agent"
import content_service "odin_test:hub/service/content"
import project_service "odin_test:hub/service/project"

Capabilities_Fixture :: struct {
	wire:         ^wire_fixture,
	serial:       int,
	writes_impl:  sqlite.Agent_Write_Repo_SQLite,
	writes:       iface.Agent_Write_Repository,
	content_impl: sqlite.Content_Repo_SQLite,
	content_repo: iface.Content_Repository,
	project_impl: sqlite.Project_Repo_SQLite,
	project_repo: iface.Project_Repository,
	content:      content_service.Content_Service,
	projects:     project_service.Project_Service,
	ph:           Project_Handlers,
	ch:           Content_Handlers,
	ah:           Agent_Handlers,
	wh:           Agent_Write_Handlers,
}
cap_setup :: proc(t: ^testing.T) -> ^Capabilities_Fixture {
	f := new(Capabilities_Fixture)
	f.wire = wire_setup(t, "capabilities")
	f.writes = sqlite.new_agent_write_repository(&f.writes_impl, &f.wire.conn)
	f.content_repo = sqlite.new_content_repository(&f.content_impl, &f.wire.conn)
	f.project_repo = sqlite.new_project_repository(&f.project_impl, &f.wire.conn)
	f.content = content_service.new_content_service(
		&f.content_repo,
		&f.wire.ag_repo,
		&f.wire.br_repo,
		&f.project_repo,
		&f.wire.tc_repo,
		&f.wire.clock,
		&f.wire.ids,
	)
	f.projects = project_service.new_project_service_with_command_sink(
		&f.project_repo,
		&f.wire.br_repo,
		{},
		&f.wire.clock,
		&f.wire.ids,
	)
	f.ph = {
		auth         = &f.wire.auth_svc,
		projects     = &f.projects,
		agent_writes = &f.writes,
	}
	f.ch = {
		auth         = &f.wire.auth_svc,
		content      = &f.content,
		agent_writes = &f.writes,
	}
	f.ah = {
		auth         = &f.wire.auth_svc,
		agents       = &f.wire.ag_svc,
		agent_writes = &f.writes,
	}
	f.wh = {
		auth   = &f.wire.auth_svc,
		writes = &f.writes,
	}
	return f
}
cap_destroy :: proc(f: ^Capabilities_Fixture) {wire_teardown(f.wire); free(f)}
cap_req :: proc(f: ^Capabilities_Fixture, method, path, body: string, user := false) -> Request {
	req := wire_cookie_request(f.wire, method, path, body)
	if !user do req.headers = f.wire.agent_headers[:]
	return req
}
cap_status :: proc(t: ^testing.T, resp: Response, expected: int) {
	testing.expectf(t, resp.status == expected, "expected %d, got %d: %s", expected, resp.status, resp.body)
}
cap_rows :: proc(t: ^testing.T, f: ^Capabilities_Fixture) -> []domain.Agent_Write {
	rows, err := iface.agent_write_list_by_owner(&f.writes, string(f.wire.owner), 0, 200)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	return rows
}
cap_project :: proc(t: ^testing.T, f: ^Capabilities_Fixture, user := false) -> string {
	resp := create_project_handler(
		&f.ph,
		cap_req(
			f,
			"POST",
			"/api/v1/projects",
			`{"name":"Project","slug":"project","default_path":"/repo","owner_user_id":"forged"}`,
			user,
		),
	)
	cap_status(t, resp, 201)
	return json_string(resp.body, "project_id")
}
cap_memory :: proc(t: ^testing.T, f: ^Capabilities_Fixture, status := "active", user := false) -> string {
	body := strings.concatenate(
		{
			`{"type":"fact","title":"Memory","body":"secret","status":"`,
			status,
			`","proposed_by_instance_id":"forged"}`,
		},
	)
	resp := create_memory_handler(&f.ch, cap_req(f, "POST", "/api/v1/memories", body, user))
	cap_status(t, resp, 201)
	return json_string(resp.body, "memory_id")
}
cap_agent :: proc(t: ^testing.T, f: ^Capabilities_Fixture, template := "tmpl_worker", user := false) -> string {
	f.serial += 1
	resp := create_agent_handler(
		&f.ah,
		cap_req(
			f,
			"POST",
			"/api/v1/agents",
			strings.concatenate(
				{
					`{"name":"Target","slug":"target-`,
					fmt.tprintf("%d", f.serial),
					`","template_id":"`,
					template,
					`","permission_mode":"ask"}`,
				},
			),
			user,
		),
	)
	cap_status(t, resp, 201)
	return json_string(resp.body, "agent_id")
}
cap_auth :: proc(f: ^Capabilities_Fixture) -> contracts.Auth_Context {return{
		kind = .Instance_Token,
		user_id = string(f.wire.owner),
		agent_instance_id = f.wire.instance_id,
	}}

@(test)
test_agent_project_detail_create_update_archive_unarchive :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := cap_setup(t); defer cap_destroy(f)
	id := cap_project(t, f)
	path := fmt.tprintf("/api/v1/projects/%s", id)
	cap_status(t, project_detail_handler(&f.ph, cap_req(f, "GET", path, "")), 200)
	cap_status(
		t,
		update_project_handler(
			&f.ph,
			cap_req(f, "PATCH", path, `{"name":"Changed","description":"","slug":"new-slug"}`),
		),
		200,
	)
	p, found, _ := iface.project_get(&f.project_repo, domain.Project_ID(id))
	testing.expect(t, found); testing.expect_value(t, p.name, "Changed")
	testing.expect_value(t, string(p.owner_user_id), string(f.wire.owner))
	cap_status(t, archive_project_handler(&f.ph, cap_req(f, "POST", fmt.tprintf("%s/archive", path), "")), 200)
	p, _, _ = iface.project_get(
		&f.project_repo,
		domain.Project_ID(id),
	); testing.expect_value(t, p.state, domain.Project_State.Archived)
	cap_status(t, unarchive_project_handler(&f.ph, cap_req(f, "POST", fmt.tprintf("%s/unarchive", path), "")), 200)
	rows := cap_rows(t, f); testing.expect_value(t, len(rows), 4)
	if len(rows) != 4 do return
	for row in rows {testing.expect_value(t, row.resource_kind, "project"); testing.expect_value(
			t,
			row.resource_id,
			id,
		)
		testing.expect_value(t, row.actor_agent_instance_id, f.wire.instance_id)}
	testing.expect_value(t, rows[0].action, "unarchive"); testing.expect_value(t, len(rows[0].fields), 0)
	testing.expect_value(t, rows[1].action, "archive"); testing.expect_value(t, len(rows[1].fields), 0)
	testing.expect_value(
		t,
		rows[2].action,
		"update",
	); testing.expect_value(t, strings.join(rows[2].fields, ","), "name,slug")
	testing.expect_value(
		t,
		rows[3].action,
		"create",
	); testing.expect_value(t, strings.join(rows[3].fields, ","), "name,slug,default_path")
	cap_status(t, update_project_handler(&f.ph, cap_req(f, "PATCH", path, `{"owner_user_id":"another"}`)), 409)
	cap_status(
		t,
		create_project_handler(&f.ph, cap_req(f, "POST", "/api/v1/projects", `{"name":"Missing path"}`)),
		400,
	)
}
@(test)
test_agent_project_routes_refuse_other_owner :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := cap_setup(t); defer cap_destroy(f)
	p, ok, _ := project_service.create(
		&f.projects,
		{kind = .Internal_User, user_id = "foreign"},
		{name = "Foreign", default_path = "/foreign"},
	)
	testing.expect(t, ok)
	path := fmt.tprintf("/api/v1/projects/%s", p.project_id)
	for tc in ([]struct {
			handler:              Handler_Proc,
			method, suffix, body: string,
		} {
			{project_detail_handler, "GET", "", ""},
			{update_project_handler, "PATCH", "", `{"name":"attack"}`},
			{archive_project_handler, "POST", "/archive", ""},
			{unarchive_project_handler, "POST", "/unarchive", ""},
		}) {
		resp := tc.handler(&f.ph, cap_req(f, tc.method, fmt.tprintf("%s%s", path, tc.suffix), tc.body))
		cap_status(t, resp, 404); testing.expect(t, strings.contains(resp.body, "not_found"))
	}
	unchanged, _, _ := iface.project_get(&f.project_repo, p.project_id)
	testing.expect_value(t, unchanged.name, "Foreign"); testing.expect_value(t, unchanged.state, p.state)
	testing.expect_value(t, len(cap_rows(t, f)), 0)
	foreign_writes, _ := iface.agent_write_list_by_owner(
		&f.writes,
		"foreign",
		0,
		200,
	); testing.expect_value(t, len(foreign_writes), 0)
}
@(test)
test_agent_project_bridge_path_routes_stay_user_only :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := cap_setup(t); defer cap_destroy(f)
	for handler in ([]Handler_Proc {
			put_project_bridge_path_handler,
			delete_project_bridge_path_handler,
			validate_project_bridge_path_handler,
		}) {
		cap_status(
			t,
			handler(&f.ph, cap_req(f, "POST", "/api/v1/projects/prj_x/bridge-paths/brg_x", `{"path":"/x"}`)),
			403,
		)
	}
	req := cap_req(f, "POST", "/api/v1/projects", `{"name":"x","default_path":"/x"}`)
	req.headers = f.wire.agent_headers[:1]
	cap_status(t, create_project_handler(&f.ph, req), 403)
}
@(test)
test_agent_creates_active_memory_without_approval :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := cap_setup(t); defer cap_destroy(f)
	id := cap_memory(t, f)
	m, found, _ := iface.content_get_memory(&f.content_repo, id); testing.expect(t, found)
	testing.expect_value(t, m.status, "active"); testing.expect_value(t, m.expires_at, "")
	testing.expect_value(t, m.proposed_by_instance_id, f.wire.instance_id)
	rows := cap_rows(t, f); testing.expect_value(t, len(rows), 1)
	if len(rows) >
	   0 {testing.expect_value(t, rows[0].resource_kind, "memory"); testing.expect_value(t, rows[0].action, "create"); testing.expect_value(t, strings.join(rows[0].fields, ","), "type,title,body,status")}
}
@(test)
test_agent_memory_create_status_validation :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := cap_setup(t); defer cap_destroy(f)
	resp := create_memory_handler(
		&f.ch,
		cap_req(f, "POST", "/api/v1/memories", `{"type":"fact","body":"x","status":"archived"}`),
	)
	cap_status(t, resp, 400); testing.expect(t, strings.contains(resp.body, "memory_status_invalid"))
	testing.expect_value(t, len(cap_rows(t, f)), 0)
	id := cap_memory(t, f, "")
	m, _, _ := iface.content_get_memory(
		&f.content_repo,
		id,
	); testing.expect_value(t, m.status, "pending"); testing.expect(t, m.expires_at != "")
	id = cap_memory(
		t,
		f,
		"pending",
	); m, _, _ = iface.content_get_memory(&f.content_repo, id); testing.expect_value(t, m.status, "pending")
}
@(test)
test_agent_updates_and_archives_active_memory :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := cap_setup(t); defer cap_destroy(f)
	id := cap_memory(t, f)
	path := fmt.tprintf("/api/v1/memories/%s", id)
	cap_status(
		t,
		patch_memory_handler(&f.ch, cap_req(f, "PATCH", path, `{"title":"","body":"changed","project_ids":[]}`)),
		200,
	)
	m, _, _ := iface.content_get_memory(
		&f.content_repo,
		id,
	); testing.expect_value(t, m.body, "changed"); testing.expect_value(t, m.title, "")
	cap_status(t, memory_action_handler(&f.ch, cap_req(f, "POST", fmt.tprintf("%s/archive", path), "")), 200)
	m, _, _ = iface.content_get_memory(&f.content_repo, id); testing.expect_value(t, m.status, "archived")
	rows := cap_rows(t, f); testing.expect_value(t, len(rows), 3)
	if len(rows) ==
	   3 {testing.expect_value(t, rows[0].action, "archive"); testing.expect_value(t, len(rows[0].fields), 0); testing.expect_value(t, rows[1].action, "update"); testing.expect_value(t, strings.join(rows[1].fields, ","), "title,body,project_ids")}
}
@(test)
test_agent_archive_refuses_pending_memory :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := cap_setup(t); defer cap_destroy(f)
	id := cap_memory(t, f, "pending")
	resp := memory_action_handler(&f.ch, cap_req(f, "POST", fmt.tprintf("/api/v1/memories/%s/archive", id), ""))
	cap_status(t, resp, 409); testing.expect(t, strings.contains(resp.body, "memory_not_active"))
	m, _, _ := iface.content_get_memory(&f.content_repo, id); testing.expect_value(t, m.status, "pending")
	testing.expect_value(t, len(cap_rows(t, f)), 1)
}
@(test)
test_agent_cannot_approve_or_reject_memory :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := cap_setup(t); defer cap_destroy(f)
	id := cap_memory(t, f, "pending")
	for action in ([]string{"approve", "reject"}) {
		resp := memory_action_handler(
			&f.ch,
			cap_req(f, "POST", fmt.tprintf("/api/v1/memories/%s/%s", id, action), "{}"),
		)
		cap_status(t, resp, 403); testing.expect(t, strings.contains(resp.body, "user_only"))
	}
	m, _, _ := iface.content_get_memory(&f.content_repo, id); testing.expect_value(t, m.status, "pending")
	testing.expect_value(t, len(cap_rows(t, f)), 1)
}
@(test)
test_agent_memory_routes_refuse_other_owner :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := cap_setup(t); defer cap_destroy(f)
	auth := contracts.Auth_Context {
		kind    = .Internal_User,
		user_id = "foreign",
	}
	m, ok, _ := content_service.create_memory(
		&f.content,
		auth,
		{type = .Fact, body = "private", status = "active"},
	); testing.expect(t, ok)
	path := fmt.tprintf("/api/v1/memories/%s", m.memory_id)
	cap_status(t, patch_memory_handler(&f.ch, cap_req(f, "PATCH", path, `{"body":"attack"}`)), 404)
	cap_status(t, memory_action_handler(&f.ch, cap_req(f, "POST", fmt.tprintf("%s/archive", path), "")), 404)
	p, _, _ := project_service.create(&f.projects, auth, {name = "Foreign", default_path = "/foreign"})
	body := strings.concatenate({`{"type":"fact","body":"attack","project_ids":["`, string(p.project_id), `"]}`})
	resp := create_memory_handler(
		&f.ch,
		cap_req(f, "POST", "/api/v1/memories", body),
	); cap_status(t, resp, 404); testing.expect(t, strings.contains(resp.body, "project not found"))
	unchanged, _, _ := iface.content_get_memory(&f.content_repo, m.memory_id)
	testing.expect_value(t, unchanged.body, "private"); testing.expect_value(t, unchanged.status, "active")
	testing.expect_value(t, len(cap_rows(t, f)), 0)
	foreign_writes, _ := iface.agent_write_list_by_owner(
		&f.writes,
		"foreign",
		0,
		200,
	); testing.expect_value(t, len(foreign_writes), 0)
}
@(test)
test_agent_updates_agent_including_permission_mode :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := cap_setup(t); defer cap_destroy(f)
	id := cap_agent(t, f)
	path := fmt.tprintf("/api/v1/agents/%s", id)
	cap_status(t, agent_detail_handler(&f.ah, cap_req(f, "GET", path, "")), 200)
	cap_status(
		t,
		update_agent_handler(&f.ah, cap_req(f, "PATCH", path, `{"name":"New","permission_mode":"yolo"}`)),
		200,
	)
	a, _, _ := iface.agent_get(
		&f.wire.ag_repo,
		id,
	); testing.expect_value(t, a.permission_mode, "yolo"); testing.expect_value(t, a.name, "New")
	rows := cap_rows(t, f); testing.expect_value(t, len(rows), 2)
	if len(rows) ==
	   2 {testing.expect_value(t, rows[0].resource_kind, "agent"); testing.expect_value(t, rows[0].action, "update"); testing.expect_value(t, strings.join(rows[0].fields, ","), "name,permission_mode"); testing.expect_value(t, rows[1].action, "create"); testing.expect_value(t, strings.join(rows[1].fields, ","), "name,slug,template_id,permission_mode")}
}
@(test)
test_agent_update_rejects_invalid_permission_mode :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := cap_setup(t); defer cap_destroy(f)
	id := cap_agent(t, f)
	cap_status(
		t,
		update_agent_handler(
			&f.ah,
			cap_req(f, "PATCH", fmt.tprintf("/api/v1/agents/%s", id), `{"permission_mode":"bad"}`),
		),
		400,
	)
	a, _, _ := iface.agent_get(&f.wire.ag_repo, id); testing.expect_value(t, a.permission_mode, "ask")
	testing.expect_value(t, len(cap_rows(t, f)), 1)
}
@(test)
test_agent_update_refuses_bot_template_change :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := cap_setup(t); defer cap_destroy(f)
	id := cap_agent(t, f)
	path := fmt.tprintf("/api/v1/agents/%s", id)
	resp := update_agent_handler(&f.ah, cap_req(f, "PATCH", path, `{"template_id":" tmpl_bot "}`))
	cap_status(t, resp, 403); testing.expect(t, strings.contains(resp.body, "bot_template_locked"))
	a, _, _ := iface.agent_get(&f.wire.ag_repo, id); testing.expect_value(t, a.template_id, "tmpl_worker")
	bot := cap_agent(t, f, domain.TEMPLATE_BOT_ID, true)
	resp = update_agent_handler(
		&f.ah,
		cap_req(f, "PATCH", fmt.tprintf("/api/v1/agents/%s", bot), `{"template_id":"tmpl_worker"}`),
	)
	cap_status(t, resp, 403); testing.expect(t, strings.contains(resp.body, "bot_template_locked"))
	a, _, _ = iface.agent_get(&f.wire.ag_repo, bot); testing.expect_value(t, a.template_id, domain.TEMPLATE_BOT_ID)
	// Non-template bot edits remain allowed, and users retain template changes.
	cap_status(
		t,
		update_agent_handler(
			&f.ah,
			cap_req(f, "PATCH", fmt.tprintf("/api/v1/agents/%s", bot), `{"permission_mode":"yolo"}`),
		),
		200,
	)
	cap_status(t, update_agent_handler(&f.ah, cap_req(f, "PATCH", path, `{"template_id":"tmpl_bot"}`, true)), 200)
}
@(test)
test_agent_update_refuses_other_owner_agent :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := cap_setup(t); defer cap_destroy(f)
	a, ok, _ := agent_service.create_agent(
		&f.wire.ag_svc,
		{kind = .Internal_User, user_id = "foreign"},
		{name = "Foreign", template_id = "tmpl_worker", permission_mode = "ask"},
	); testing.expect(t, ok)
	path := fmt.tprintf("/api/v1/agents/%s", a.agent_id)
	cap_status(t, agent_detail_handler(&f.ah, cap_req(f, "GET", path, "")), 404)
	for body in ([]string{`{"name":"attack"}`, `{"template_id":"tmpl_bot"}`}) do cap_status(t, update_agent_handler(&f.ah, cap_req(f, "PATCH", path, body)), 404)
	unchanged, _, _ := iface.agent_get(
		&f.wire.ag_repo,
		a.agent_id,
	); testing.expect_value(t, unchanged.name, "Foreign"); testing.expect_value(t, unchanged.permission_mode, "ask")
	testing.expect_value(t, len(cap_rows(t, f)), 0)
}
@(test)
test_agent_writes_recorded_for_instance_callers_only :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := cap_setup(t); defer cap_destroy(f)
	for user in ([]bool{true, false}) {
		p := cap_project(t, f, user); path := fmt.tprintf("/api/v1/projects/%s", p)
		cap_status(t, update_project_handler(&f.ph, cap_req(f, "PATCH", path, `{"description":"secret"}`, user)), 200)
		cap_status(
			t,
			archive_project_handler(&f.ph, cap_req(f, "POST", fmt.tprintf("%s/archive", path), "", user)),
			200,
		)
		cap_status(
			t,
			unarchive_project_handler(&f.ph, cap_req(f, "POST", fmt.tprintf("%s/unarchive", path), "", user)),
			200,
		)
		m := cap_memory(t, f, "active", user); path = fmt.tprintf("/api/v1/memories/%s", m)
		cap_status(t, patch_memory_handler(&f.ch, cap_req(f, "PATCH", path, `{"body":"private"}`, user)), 200)
		cap_status(t, memory_action_handler(&f.ch, cap_req(f, "POST", fmt.tprintf("%s/archive", path), "", user)), 200)
		a := cap_agent(t, f, "tmpl_worker", user); path = fmt.tprintf("/api/v1/agents/%s", a)
		cap_status(
			t,
			update_agent_handler(
				&f.ah,
				cap_req(f, "PATCH", path, `{"instructions":"secret","permission_mode":"yolo"}`, user),
			),
			200,
		)
		testing.expect_value(t, len(cap_rows(t, f)), 0 if user else 9)
	}
	for row in cap_rows(t, f) do for field in row.fields {testing.expect(t, field != "secret" && field != "private")}
	// A failing recorder must preserve the completed project mutation.
	context.logger = log.nil_logger() // Expected recorder error must not fail the test logger.
	testing.expect(t, sqlite.exec(&f.wire.conn, "DROP TABLE agent_writes;"))
	cap_project(t, f)
}
@(test)
test_agent_writes_list_is_owner_scoped_and_paginates :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := cap_setup(t); defer cap_destroy(f)
	for _ in 0 ..< 3 do cap_memory(t, f)
	testing.expect_value(
		t,
		iface.agent_write_insert(&f.writes, {owner_user_id = "foreign", actor_agent_instance_id = "foreign_inst", resource_kind = "memory", resource_id = "foreign_mem", action = "create"}).code,
		domain.Error_Code.None,
	)
	req := cap_req(f, "GET", "/api/v1/me/agent-writes", "", true)
	req.query = "limit=2"
	resp := list_agent_writes_handler(&f.wh, req); cap_status(t, resp, 200)
	testing.expect(t, strings.contains(resp.body, `"has_more":true`))
	testing.expect(
		t,
		!strings.contains(resp.body, "foreign_mem"),
	); testing.expect(t, !strings.contains(resp.body, "owner_user_id"))
	cursor := json_string(resp.body, "next_cursor"); testing.expect(t, cursor != "")
	req.query = fmt.tprintf("limit=2&cursor=%s", cursor)
	resp = list_agent_writes_handler(
		&f.wh,
		req,
	); cap_status(t, resp, 200); testing.expect(t, strings.contains(resp.body, `"has_more":false`))
	for query in ([]string {
			"limit=200",
			"limit=999",
			"limit=0",
			"cursor=bad",
			"cursor=1x",
			"cursor=99999999999999999999999999",
			"cursor=0",
		}) {
		req.query = query
		page := list_agent_writes_handler(&f.wh, req)
		cap_status(t, page, 200)
		testing.expect(t, strings.contains(page.body, cap_rows(t, f)[0].write_id))
	}
	foreign_headers := http_test_login(t, &f.wire.auth_svc, "foreign")
	foreign_auth, _, _ := require_auth(
		&f.wire.auth_svc,
		Request{headers = foreign_headers, remote_addr = "127.0.0.1:4444"},
	)
	testing.expect_value(
		t,
		iface.agent_write_insert(&f.writes, {owner_user_id = foreign_auth.user_id, actor_agent_instance_id = "b_inst", resource_kind = "memory", resource_id = "b_only", action = "create"}).code,
		domain.Error_Code.None,
	)
	req.query = ""; req.headers = foreign_headers
	resp = list_agent_writes_handler(
		&f.wh,
		req,
	); cap_status(t, resp, 200); testing.expect(t, strings.contains(resp.body, "b_only")); testing.expect(t, !strings.contains(resp.body, f.wire.instance_id))
	cap_status(t, list_agent_writes_handler(&f.wh, cap_req(f, "GET", "/api/v1/me/agent-writes", "")), 403)
}
@(test)
test_user_memory_and_project_routes_unchanged :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := cap_setup(t); defer cap_destroy(f)
	p := cap_project(t, f, true); path := fmt.tprintf("/api/v1/projects/%s", p)
	cap_status(t, list_projects_handler(&f.ph, cap_req(f, "GET", "/api/v1/projects", "", true)), 200)
	cap_status(t, project_detail_handler(&f.ph, cap_req(f, "GET", path, "", true)), 200)
	cap_status(t, update_project_handler(&f.ph, cap_req(f, "PATCH", path, `{"name":"User edit"}`, true)), 200)
	cap_status(t, archive_project_handler(&f.ph, cap_req(f, "POST", fmt.tprintf("%s/archive", path), "", true)), 200)
	cap_status(
		t,
		unarchive_project_handler(&f.ph, cap_req(f, "POST", fmt.tprintf("%s/unarchive", path), "", true)),
		200,
	)
	bp := fmt.tprintf("%s/bridge-paths/%s", path, f.wire.bridge_pin)
	cap_status(t, put_project_bridge_path_handler(&f.ph, cap_req(f, "PUT", bp, `{"path":"/repo"}`, true)), 200)
	cap_status(
		t,
		validate_project_bridge_path_handler(&f.ph, cap_req(f, "POST", fmt.tprintf("%s/validate", bp), "", true)),
		409,
	)
	cap_status(t, delete_project_bridge_path_handler(&f.ph, cap_req(f, "DELETE", bp, "", true)), 200)
	for action in ([]string{"approve", "reject"}) {
		m := cap_memory(t, f, "pending", true); mp := fmt.tprintf("/api/v1/memories/%s", m)
		cap_status(t, patch_memory_handler(&f.ch, cap_req(f, "PATCH", mp, `{"body":"user edit"}`, true)), 200)
		cap_status(
			t,
			memory_action_handler(&f.ch, cap_req(f, "POST", fmt.tprintf("%s/%s", mp, action), "{}", true)),
			200,
		)
	}
	m := cap_memory(t, f, "pending", true)
	cap_status(
		t,
		memory_action_handler(&f.ch, cap_req(f, "POST", fmt.tprintf("/api/v1/memories/%s/archive", m), "", true)),
		200,
	)
	testing.expect_value(t, len(cap_rows(t, f)), 0)
}
