package main

import "core:fmt"
import "core:strings"

Project_Service_Result :: struct { ok: bool, status_code: int, message: string }

project_create :: proc(body, author: string) -> Project_Service_Result {
	project_id := extract_json_string(body, "project_id", "")
	name := extract_json_string(body, "name", "")
	description := extract_json_string(body, "description", "")
	if project_id == "" do project_id = strings.clone(fmt.tprintf("project_%d", router_now_unix_ms()))
	if name == "" do return project_error(400, "project name required")
	if project_index(project_id) >= 0 do return project_error(400, "project already exists")
	event := Project_Event{kind = .Project_Created, project_id = project_id, name = name, description = description, author = author}
	project_parse_anchors_into(body, &event.anchors, &event.anchor_count)
	if !project_store_append_event(event) do return project_error(500, "append project failed")
	return Project_Service_Result{ok = true, status_code = 200, message = project_response_json("created", project_id)}
}

project_update :: proc(body, author: string) -> Project_Service_Result {
	project_id := extract_json_string(body, "project_id", "")
	if project_id == "" do return project_error(400, "project_id required")
	idx := project_index(project_id)
	if idx < 0 do return project_error(404, "project not found")
	current := project_records[idx]
	name := extract_json_string(body, "name", current.name)
	description := extract_json_string(body, "description", current.description)
	event := Project_Event{kind = .Project_Updated, project_id = project_id, name = name, description = description, author = author}
	project_parse_anchors_into(body, &event.anchors, &event.anchor_count)
	if json_value_start(body, "anchors") < 0 && event.anchor_count == 0 { event.anchor_count = current.anchor_count; for i in 0..<current.anchor_count do event.anchors[i] = project_anchor_clone(current.anchors[i]) }
	if !project_store_append_event(event) do return project_error(500, "append project failed")
	return Project_Service_Result{ok = true, status_code = 200, message = project_response_json("updated", project_id)}
}

project_list_json :: proc() -> string {
	b := strings.builder_make(); strings.write_string(&b, `{"ok":true,"projects":[`)
	for i in 0..<project_record_count { if i > 0 do strings.write_string(&b, `,`); project_write_record_json(&b, project_records[i]) }
	strings.write_string(&b, `]}`); return strings.to_string(b)
}

project_show_json :: proc(project_id: string) -> (string, int) {
	idx := project_index(project_id)
	if idx < 0 do return `{"ok":false,"message":"project not found"}`, 404
	b := strings.builder_make(); strings.write_string(&b, `{"ok":true,"project":`); project_write_record_json(&b, project_records[idx]); strings.write_string(&b, `}`); return strings.to_string(b), 200
}

project_write_record_json :: proc(b: ^strings.Builder, p: Project_Record) {
	strings.write_string(b, `{"project_id":"`); json_write_string(b, p.project_id); strings.write_string(b, `","name":"`); json_write_string(b, p.name); strings.write_string(b, `","description":"`); json_write_string(b, p.description); strings.write_string(b, `","created_unix_ms":`); strings.write_string(b, fmt.tprintf("%d", p.created_unix_ms)); strings.write_string(b, `,"updated_unix_ms":`); strings.write_string(b, fmt.tprintf("%d", p.updated_unix_ms)); strings.write_string(b, `,"order":`); strings.write_string(b, fmt.tprintf("%d", p.order)); strings.write_string(b, `,"anchors":[`)
	for i in 0..<p.anchor_count { if i > 0 do strings.write_string(b, `,`); project_write_anchor_json(b, p.anchors[i]) }
	strings.write_string(b, `]}`)
}

project_error :: proc(status: int, message: string) -> Project_Service_Result { b := strings.builder_make(); strings.write_string(&b, `{"ok":false,"message":"`); json_write_string(&b, message); strings.write_string(&b, `"}`); return Project_Service_Result{ok = false, status_code = status, message = strings.to_string(b)} }
project_response_json :: proc(message, project_id: string) -> string { b := strings.builder_make(); strings.write_string(&b, `{"ok":true,"message":"`); json_write_string(&b, message); strings.write_string(&b, `","project_id":"`); json_write_string(&b, project_id); strings.write_string(&b, `"}`); return strings.to_string(b) }

project_reorder :: proc(body, author: string) -> Project_Service_Result {
	project_ids := extract_json_string_array(body, "project_ids")
	defer {
		for s in project_ids do delete(s)
		delete(project_ids)
	}
	for id, order in project_ids {
		idx := project_index(id)
		if idx < 0 do continue
		current := project_records[idx]
		event := Project_Event{
			kind = .Project_Updated,
			project_id = id,
			name = current.name,
			description = current.description,
			author = author,
			order = order,
			anchor_count = current.anchor_count,
		}
		for i in 0..<current.anchor_count {
			event.anchors[i] = project_anchor_clone(current.anchors[i])
		}
		if !project_store_append_event(event) {
			return project_error(500, "failed to append project reorder event")
		}
	}
	return Project_Service_Result{ok = true, status_code = 200, message = `{"ok":true,"message":"projects reordered"}`}
}
