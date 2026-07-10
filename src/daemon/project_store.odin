package main

import "core:fmt"
import "core:os"
import "core:strings"

PROJECT_MAX_PROJECTS :: 512
PROJECT_MAX_EVENTS :: 4096
PROJECT_MAX_ANCHORS :: 32

Project_Anchor :: struct { type: string, value: string, note: string }
Project_Record :: struct { project_id: string, name: string, description: string, anchors: [PROJECT_MAX_ANCHORS]Project_Anchor, anchor_count: int, created_unix_ms: i64, updated_unix_ms: i64, order: int }
Project_Event_Kind :: enum { Project_Created, Project_Updated }
Project_Event :: struct { event_id: string, kind: Project_Event_Kind, project_id: string, name: string, description: string, anchors: [PROJECT_MAX_ANCHORS]Project_Anchor, anchor_count: int, author: string, created_unix_ms: i64, order: int }


project_records: [PROJECT_MAX_PROJECTS]Project_Record
project_record_count: int
project_events: [PROJECT_MAX_EVENTS]Project_Event
project_event_count: int
project_store_dir: string
project_events_path: string

project_store_init :: proc(data_dir: string) {
	project_record_count = 0; project_event_count = 0
	project_store_dir = strings.clone(fmt.tprintf("%s/projects", expand_home(data_dir)))
	project_events_path = strings.clone(fmt.tprintf("%s/events.jsonl", project_store_dir))
	_ = os.make_directory_all(project_store_dir)
	project_store_replay()
	migrate_flag := os.get_env_alloc("HEIMDALL_MIGRATE_V1", context.allocator)
	if migrate_flag == "1" do project_migrate_anchors(expand_home(data_dir))

	// Ensure the default system project exists
	if project_index("heimdall-system") < 0 {
		event := Project_Event{
			kind = .Project_Created,
			project_id = "heimdall-system",
			name = "Heimdall System",
			description = "Internal system project for cognitive optimization, cognitive audits, and automated memory reviews.",
			author = "system",
		}
		project_store_append_event(event)
	}
}

project_store_append_event :: proc(event: Project_Event) -> bool {
	ev := project_event_clone(event)
	if ev.event_id == "" do ev.event_id = strings.clone(fmt.tprintf("project_evt_%d", router_now_unix_ms()))
	if ev.created_unix_ms == 0 do ev.created_unix_ms = router_now_unix_ms()
	file, err := os.open(project_events_path, os.O_CREATE | os.O_APPEND | os.O_WRONLY)
	if err != nil do return false
	defer os.close(file)
	os.write_string(file, project_event_json(ev)); os.write_string(file, "\n")
	return project_apply_event(ev)
}

project_store_replay :: proc() {
	data, err := os.read_entire_file(project_events_path, context.allocator)
	if err != nil do return
	for line in strings.split(string(data), "\n") {
		trimmed := strings.trim_space(line)
		if trimmed == "" do continue
		if ev, ok := project_event_from_json(trimmed); ok do project_apply_event(ev)
	}
}

project_apply_event :: proc(event: Project_Event) -> bool {
	if project_event_count < PROJECT_MAX_EVENTS { project_events[project_event_count] = project_event_clone(event); project_event_count += 1 }
	idx := project_index(event.project_id)
	if idx < 0 {
		if project_record_count >= PROJECT_MAX_PROJECTS do return false
		idx = project_record_count; project_record_count += 1
		project_records[idx].project_id = strings.clone(event.project_id)
		project_records[idx].created_unix_ms = event.created_unix_ms
	}
	rec := &project_records[idx]
	rec.name = strings.clone(event.name); rec.description = strings.clone(event.description); rec.anchor_count = event.anchor_count
	for i in 0..<event.anchor_count do rec.anchors[i] = project_anchor_clone(event.anchors[i])
	rec.updated_unix_ms = event.created_unix_ms
	rec.order = event.order
	return true
}

project_index :: proc(project_id: string) -> int { for i in 0..<project_record_count { if project_records[i].project_id == project_id do return i }; return -1 }
project_event_clone :: proc(e: Project_Event) -> Project_Event { out := e; out.event_id = strings.clone(e.event_id); out.project_id = strings.clone(e.project_id); out.name = strings.clone(e.name); out.description = strings.clone(e.description); out.author = strings.clone(e.author); for i in 0..<e.anchor_count do out.anchors[i] = project_anchor_clone(e.anchors[i]); return out }
project_anchor_clone :: proc(a: Project_Anchor) -> Project_Anchor { return Project_Anchor{type = strings.clone(a.type), value = strings.clone(a.value), note = strings.clone(a.note)} }

project_event_json :: proc(event: Project_Event) -> string {
	b := strings.builder_make(); strings.write_string(&b, `{"event_id":"`); json_write_string(&b, event.event_id); strings.write_string(&b, `","kind":"`); json_write_string(&b, fmt.tprintf("%v", event.kind)); strings.write_string(&b, `","project_id":"`); json_write_string(&b, event.project_id); strings.write_string(&b, `","name":"`); json_write_string(&b, event.name); strings.write_string(&b, `","description":"`); json_write_string(&b, event.description); strings.write_string(&b, `","author":"`); json_write_string(&b, event.author); strings.write_string(&b, `","created_unix_ms":`); strings.write_string(&b, fmt.tprintf("%d", event.created_unix_ms)); strings.write_string(&b, fmt.tprintf(`,"order":%d`, event.order)); strings.write_string(&b, `,"anchors":[`)
	for i in 0..<event.anchor_count { if i > 0 do strings.write_string(&b, `,`); project_write_anchor_json(&b, event.anchors[i]) }
	strings.write_string(&b, `]}`); return strings.to_string(b)
}

project_event_from_json :: proc(line: string) -> (Project_Event, bool) {
	kind := Project_Event_Kind.Project_Created
	if extract_json_string(line, "kind", "") == "Project_Updated" do kind = .Project_Updated
	ev := Project_Event{event_id = extract_json_string(line, "event_id", ""), kind = kind, project_id = extract_json_string(line, "project_id", ""), name = extract_json_string(line, "name", ""), description = extract_json_string(line, "description", ""), author = extract_json_string(line, "author", ""), created_unix_ms = i64(extract_json_int(line, "created_unix_ms", 0)), order = extract_json_int(line, "order", 0)}
	project_parse_anchors_into(line, &ev.anchors, &ev.anchor_count)
	return ev, ev.project_id != ""
}

project_parse_anchors_into :: proc(body: string, anchors: ^[PROJECT_MAX_ANCHORS]Project_Anchor, count: ^int) {
	count^ = 0; idx := 0
	for count^ < PROJECT_MAX_ANCHORS {
		rel := strings.index(body[idx:], `{"type":"`)
		if rel < 0 do break
		start := idx + rel; end := strings.index(body[start:], `}`); if end < 0 do break
		obj := body[start:start + end + 1]
		anchors[count^] = Project_Anchor{type = extract_json_string(obj, "type", ""), value = extract_json_string(obj, "value", ""), note = extract_json_string(obj, "note", "")}
		count^ += 1; idx = start + end + 1
	}
}

project_write_anchor_json :: proc(b: ^strings.Builder, a: Project_Anchor) { strings.write_string(b, `{"type":"`); json_write_string(b, a.type); strings.write_string(b, `","value":"`); json_write_string(b, a.value); strings.write_string(b, `","note":"`); json_write_string(b, a.note); strings.write_string(b, `"}`) }

project_migrate_anchors :: proc(data_dir: string) {
	migrations_dir := fmt.tprintf("%s/migrations", data_dir)
	_ = os.make_directory_all(migrations_dir)
	report_path := fmt.tprintf("%s/teams-v1-anchor-%d.report.md", migrations_dir, router_now_unix_ms())
	report := strings.builder_make()
	strings.write_string(&report, "# Teams v1 anchor migration\n\n")
	changed_any := false
	for i in 0..<project_record_count {
		current := project_records[i]
		event := Project_Event{kind = .Project_Updated, project_id = current.project_id, name = current.name, description = current.description, author = "system-anchor-migration", order = current.order}
		changed := false
		strings.write_string(&report, "## "); strings.write_string(&report, current.project_id); strings.write_string(&report, "\n")
		for j in 0..<current.anchor_count {
			a := current.anchors[j]
			if project_anchor_type_allowed(a.type) {
				event.anchors[event.anchor_count] = project_anchor_clone(a); event.anchor_count += 1
				continue
			}
			changed = true
			changed_any = true
			if a.type == "directory" && project_directory_anchor_maps_to_git_repo(current.project_id, a.value) {
				event.anchors[event.anchor_count] = Project_Anchor{type = "git_repo", value = strings.clone(a.value), note = strings.clone(a.note)}; event.anchor_count += 1
				strings.write_string(&report, "- directory -> git_repo: "); strings.write_string(&report, a.value); strings.write_string(&report, "\n")
			} else {
				event.description = project_append_migrated_anchor_description(event.description, a)
				strings.write_string(&report, "- moved anchor into description: "); strings.write_string(&report, a.type); strings.write_string(&report, " = "); strings.write_string(&report, a.value); strings.write_string(&report, "\n")
			}
		}
		if !changed do strings.write_string(&report, "- no changes\n")
		strings.write_string(&report, "\n")
		if changed do _ = project_store_append_event(event)
	}
	if changed_any { _ = os.write_entire_file(report_path, strings.to_string(report)) }
}

project_directory_anchor_maps_to_git_repo :: proc(project_id, value: string) -> bool {
	// Task 0b approved mapping: only the validated repo anchor is promoted to git_repo.
	if project_id == "heimdall-agent-manager" && value == "/Users/tanmayvijay/heimdall-agent-manager" do return true
	return os.exists(fmt.tprintf("%s/.git", value)) || os.exists(fmt.tprintf("%s/.jj", value))
}

project_append_migrated_anchor_description :: proc(description: string, a: Project_Anchor) -> string {
	if description != "" do return fmt.tprintf("%s\n[migrated anchor]  %s: %s  (note: %s)", description, a.type, a.value, a.note)
	return fmt.tprintf("[migrated anchor]  %s: %s  (note: %s)", a.type, a.value, a.note)
}
