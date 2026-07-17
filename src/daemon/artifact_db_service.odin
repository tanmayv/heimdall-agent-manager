package main

import "core:fmt"
import "core:os"
import "core:strings"

Artifact_Record :: struct {
	artifact_id:      string,
	name:             string,
	kind:             string,
	mime:             string,
	ext:              string,
	size_bytes:       i64,
	sha256:           string,
	rel_path:         string,
	creator_type:     string,
	creator_id:       string,
	project_id:       string,
	origin_kind:      string,
	origin_ref:       string,
	description:      string,
	created_unix_ms:  i64,
	updated_unix_ms:  i64,
	deleted:          bool,
	deleted_unix_ms:  i64,
}

Artifact_List_Filter :: struct {
	project_id:       string,
	creator_id:       string,
	origin_ref:       string,
	include_deleted:  bool,
	limit:            int,
}

artifact_db_path: string

artifact_db_init :: proc(data_dir: string) -> bool {
	dir := fmt.tprintf("%s/artifacts", data_dir)
	_ = os.make_directory_all(dir)
	artifact_db_path = strings.clone(fmt.tprintf("%s/artifacts.db", dir))
	return artifact_db_exec(`CREATE TABLE IF NOT EXISTS artifacts (
		artifact_id TEXT PRIMARY KEY,
		name TEXT NOT NULL,
		kind TEXT NOT NULL,
		mime TEXT NOT NULL,
		ext TEXT NOT NULL,
		size_bytes INTEGER NOT NULL,
		sha256 TEXT NOT NULL,
		rel_path TEXT NOT NULL,
		creator_type TEXT NOT NULL,
		creator_id TEXT NOT NULL,
		project_id TEXT NOT NULL,
		origin_kind TEXT NOT NULL,
		origin_ref TEXT NOT NULL,
		description TEXT NOT NULL,
		created_unix_ms INTEGER NOT NULL,
		updated_unix_ms INTEGER NOT NULL,
		deleted INTEGER NOT NULL DEFAULT 0,
		deleted_unix_ms INTEGER NOT NULL DEFAULT 0
	);
	CREATE INDEX IF NOT EXISTS idx_artifacts_project_id ON artifacts(project_id, deleted, created_unix_ms DESC);
	CREATE INDEX IF NOT EXISTS idx_artifacts_creator_id ON artifacts(creator_id, deleted, created_unix_ms DESC);
	CREATE INDEX IF NOT EXISTS idx_artifacts_origin_ref ON artifacts(origin_ref, deleted, created_unix_ms DESC);
	CREATE INDEX IF NOT EXISTS idx_artifacts_kind ON artifacts(kind, deleted, created_unix_ms DESC);
	CREATE INDEX IF NOT EXISTS idx_artifacts_deleted ON artifacts(deleted, created_unix_ms DESC);`)
}

artifact_db_exec :: proc(sql: string) -> bool {
	_, ok := artifact_db_query(sql)
	return ok
}

artifact_db_query :: proc(sql: string) -> (string, bool) {
	cmd := []string{"sqlite3", artifact_db_path, sql}
	state, stdout, _, err := os.process_exec(os.Process_Desc{command = cmd}, context.allocator)
	if err != nil || !state.success do return "", false
	return string(stdout), true
}

artifact_db_insert :: proc(rec: Artifact_Record) -> bool {
	q := fmt.tprintf(`INSERT OR REPLACE INTO artifacts (
		artifact_id, name, kind, mime, ext, size_bytes, sha256, rel_path,
		creator_type, creator_id, project_id, origin_kind, origin_ref,
		description, created_unix_ms, updated_unix_ms, deleted, deleted_unix_ms
	) VALUES (%s,%s,%s,%s,%s,%d,%s,%s,%s,%s,%s,%s,%s,%s,%d,%d,%d,%d);`,
		sql_text(rec.artifact_id),
		sql_text(rec.name),
		sql_text(rec.kind),
		sql_text(rec.mime),
		sql_text(rec.ext),
		rec.size_bytes,
		sql_text(rec.sha256),
		sql_text(rec.rel_path),
		sql_text(rec.creator_type),
		sql_text(rec.creator_id),
		sql_text(rec.project_id),
		sql_text(rec.origin_kind),
		sql_text(rec.origin_ref),
		sql_text(rec.description),
		rec.created_unix_ms,
		rec.updated_unix_ms,
		1 if rec.deleted else 0,
		rec.deleted_unix_ms,
	)
	return artifact_db_exec(q)
}

artifact_db_update :: proc(rec: Artifact_Record) -> bool {
	q := fmt.tprintf(`UPDATE artifacts SET
		name=%s,
		kind=%s,
		mime=%s,
		ext=%s,
		size_bytes=%d,
		sha256=%s,
		rel_path=%s,
		creator_type=%s,
		creator_id=%s,
		project_id=%s,
		origin_kind=%s,
		origin_ref=%s,
		description=%s,
		updated_unix_ms=%d,
		deleted=%d,
		deleted_unix_ms=%d
		WHERE artifact_id=%s;`,
		sql_text(rec.name),
		sql_text(rec.kind),
		sql_text(rec.mime),
		sql_text(rec.ext),
		rec.size_bytes,
		sql_text(rec.sha256),
		sql_text(rec.rel_path),
		sql_text(rec.creator_type),
		sql_text(rec.creator_id),
		sql_text(rec.project_id),
		sql_text(rec.origin_kind),
		sql_text(rec.origin_ref),
		sql_text(rec.description),
		rec.updated_unix_ms,
		1 if rec.deleted else 0,
		rec.deleted_unix_ms,
		sql_text(rec.artifact_id),
	)
	return artifact_db_exec(q)
}

artifact_db_mark_deleted :: proc(artifact_id: string, deleted_unix_ms: i64) -> bool {
	q := fmt.tprintf(`UPDATE artifacts SET deleted=1, deleted_unix_ms=%d, updated_unix_ms=%d WHERE artifact_id=%s;`, deleted_unix_ms, deleted_unix_ms, sql_text(artifact_id))
	return artifact_db_exec(q)
}

artifact_db_get :: proc(artifact_id: string) -> (Artifact_Record, bool) {
	out, ok := artifact_db_query(fmt.tprintf(`SELECT json_object(
		'artifact_id', artifact_id,
		'name', name,
		'kind', kind,
		'mime', mime,
		'ext', ext,
		'size_bytes', size_bytes,
		'sha256', sha256,
		'rel_path', rel_path,
		'creator_type', creator_type,
		'creator_id', creator_id,
		'project_id', project_id,
		'origin_kind', origin_kind,
		'origin_ref', origin_ref,
		'description', description,
		'created_unix_ms', created_unix_ms,
		'updated_unix_ms', updated_unix_ms,
		'deleted', deleted,
		'deleted_unix_ms', deleted_unix_ms
	) FROM artifacts WHERE artifact_id=%s LIMIT 1;`, sql_text(artifact_id)))
	if !ok || strings.trim_space(out) == "" do return Artifact_Record{}, false
	return artifact_record_from_json(strings.trim_space(out))
}

artifact_db_find_origin :: proc(origin_kind, origin_ref: string) -> (Artifact_Record, bool) {
	if origin_kind == "" || origin_ref == "" do return Artifact_Record{}, false
	out, ok := artifact_db_query(fmt.tprintf(`SELECT json_object(
		'artifact_id', artifact_id,
		'name', name,
		'kind', kind,
		'mime', mime,
		'ext', ext,
		'size_bytes', size_bytes,
		'sha256', sha256,
		'rel_path', rel_path,
		'creator_type', creator_type,
		'creator_id', creator_id,
		'project_id', project_id,
		'origin_kind', origin_kind,
		'origin_ref', origin_ref,
		'description', description,
		'created_unix_ms', created_unix_ms,
		'updated_unix_ms', updated_unix_ms,
		'deleted', deleted,
		'deleted_unix_ms', deleted_unix_ms
	) FROM artifacts WHERE origin_kind=%s AND origin_ref=%s LIMIT 1;`, sql_text(origin_kind), sql_text(origin_ref)))
	if !ok || strings.trim_space(out) == "" do return Artifact_Record{}, false
	return artifact_record_from_json(strings.trim_space(out))
}

artifact_db_list :: proc(filter: Artifact_List_Filter) -> []Artifact_Record {
	clauses := strings.builder_make()
	strings.write_string(&clauses, " WHERE 1=1")
	if filter.project_id != "" do strings.write_string(&clauses, fmt.tprintf(" AND project_id=%s", sql_text(filter.project_id)))
	if filter.creator_id != "" do strings.write_string(&clauses, fmt.tprintf(" AND creator_id=%s", sql_text(filter.creator_id)))
	if filter.origin_ref != "" do strings.write_string(&clauses, fmt.tprintf(" AND origin_ref=%s", sql_text(filter.origin_ref)))
	if !filter.include_deleted do strings.write_string(&clauses, " AND deleted=0")
	limit := filter.limit
	if limit <= 0 do limit = 100
	query := fmt.tprintf(`SELECT json_object(
		'artifact_id', artifact_id,
		'name', name,
		'kind', kind,
		'mime', mime,
		'ext', ext,
		'size_bytes', size_bytes,
		'sha256', sha256,
		'rel_path', rel_path,
		'creator_type', creator_type,
		'creator_id', creator_id,
		'project_id', project_id,
		'origin_kind', origin_kind,
		'origin_ref', origin_ref,
		'description', description,
		'created_unix_ms', created_unix_ms,
		'updated_unix_ms', updated_unix_ms,
		'deleted', deleted,
		'deleted_unix_ms', deleted_unix_ms
	) FROM artifacts%s ORDER BY created_unix_ms DESC LIMIT %d;`, strings.to_string(clauses), limit)
	out, ok := artifact_db_query(query)
	if !ok do return nil
	recs := make([dynamic]Artifact_Record)
	for line in strings.split(strings.trim_space(out), "\n") {
		trimmed := strings.trim_space(line)
		if trimmed == "" do continue
		rec, rec_ok := artifact_record_from_json(trimmed)
		if !rec_ok do continue
		append(&recs, rec)
	}
	return recs[:]
}

artifact_record_from_json :: proc(line: string) -> (Artifact_Record, bool) {
	if strings.trim_space(line) == "" do return Artifact_Record{}, false
	return Artifact_Record{
		artifact_id = extract_json_string(line, "artifact_id", ""),
		name = extract_json_string(line, "name", ""),
		kind = extract_json_string(line, "kind", ""),
		mime = extract_json_string(line, "mime", ""),
		ext = extract_json_string(line, "ext", ""),
		size_bytes = extract_json_i64(line, "size_bytes", 0),
		sha256 = extract_json_string(line, "sha256", ""),
		rel_path = extract_json_string(line, "rel_path", ""),
		creator_type = extract_json_string(line, "creator_type", ""),
		creator_id = extract_json_string(line, "creator_id", ""),
		project_id = extract_json_string(line, "project_id", ""),
		origin_kind = extract_json_string(line, "origin_kind", ""),
		origin_ref = extract_json_string(line, "origin_ref", ""),
		description = extract_json_string(line, "description", ""),
		created_unix_ms = extract_json_i64(line, "created_unix_ms", 0),
		updated_unix_ms = extract_json_i64(line, "updated_unix_ms", 0),
		deleted = extract_json_int(line, "deleted", 0) != 0,
		deleted_unix_ms = extract_json_i64(line, "deleted_unix_ms", 0),
	}, true
}
