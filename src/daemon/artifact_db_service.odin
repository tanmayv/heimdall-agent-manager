package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import contracts "odin_test:contracts"

Artifact_Record :: struct {
	artifact_id:         string,
	name:                string,
	kind:                string,
	mime:                string,
	ext:                 string,
	size_bytes:          i64,
	sha256:              string,
	rel_path:            string,
	creator_type:        string,
	creator_id:          string,
	project_id:          string,
	origin_kind:         string,
	origin_ref:          string,
	description:         string,
	current_version_no:  i64,
	created_unix_ms:     i64,
	updated_unix_ms:     i64,
	deleted:             bool,
	deleted_unix_ms:     i64,
}

Artifact_Version_Record :: struct {
	artifact_id:      string,
	version_no:       i64,
	name:             string,
	kind:             string,
	mime:             string,
	ext:              string,
	size_bytes:       i64,
	sha256:           string,
	rel_path:         string,
	description:      string,
	project_id:       string,
	origin_kind:      string,
	origin_ref:       string,
	author_type:      string,
	author_id:        string,
	change_reason:    string,
	created_unix_ms:  i64,
}
Artifact_Annotation_Record :: struct {
	annotation_id:    string,
	artifact_id:      string,
	version_no:       i64,
	author_type:      string,
	author_id:        string,
	context_type:     string,
	context_json:     string,
	comment:          string,
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

Artifact_Annotation_List_Filter :: struct {
	artifact_id:      string,
	version_no:       i64,
	has_version_no:   bool,
}

artifact_db_path: string

artifact_db_init :: proc(data_dir: string) -> bool {
	dir := fmt.tprintf("%s/artifacts", data_dir)
	_ = os.make_directory_all(dir)
	artifact_db_path = strings.clone(fmt.tprintf("%s/artifacts.db", dir))
	ok := artifact_db_exec(`CREATE TABLE IF NOT EXISTS artifacts (
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
	CREATE TABLE IF NOT EXISTS artifact_versions (
		artifact_id TEXT NOT NULL,
		version_no INTEGER NOT NULL,
		name TEXT NOT NULL,
		kind TEXT NOT NULL,
		mime TEXT NOT NULL,
		ext TEXT NOT NULL,
		size_bytes INTEGER NOT NULL,
		sha256 TEXT NOT NULL,
		rel_path TEXT NOT NULL,
		description TEXT NOT NULL,
		project_id TEXT NOT NULL DEFAULT '',
		origin_kind TEXT NOT NULL DEFAULT '',
		origin_ref TEXT NOT NULL DEFAULT '',
		author_type TEXT NOT NULL,
		author_id TEXT NOT NULL,
		change_reason TEXT NOT NULL DEFAULT '',
		created_unix_ms INTEGER NOT NULL,
		PRIMARY KEY (artifact_id, version_no)
	);
	CREATE TABLE IF NOT EXISTS artifact_annotations (
		annotation_id TEXT PRIMARY KEY,
		artifact_id TEXT NOT NULL,
		version_no INTEGER NOT NULL,
		author_type TEXT NOT NULL,
		author_id TEXT NOT NULL,
		context_type TEXT NOT NULL,
		context_json TEXT NOT NULL,
		comment TEXT NOT NULL,
		created_unix_ms INTEGER NOT NULL,
		updated_unix_ms INTEGER NOT NULL,
		deleted INTEGER NOT NULL DEFAULT 0,
		deleted_unix_ms INTEGER NOT NULL DEFAULT 0
	);
	CREATE INDEX IF NOT EXISTS idx_artifacts_project_id ON artifacts(project_id, deleted, created_unix_ms DESC);
	CREATE INDEX IF NOT EXISTS idx_artifacts_creator_id ON artifacts(creator_id, deleted, created_unix_ms DESC);
	CREATE INDEX IF NOT EXISTS idx_artifacts_origin_ref ON artifacts(origin_ref, deleted, created_unix_ms DESC);
	CREATE INDEX IF NOT EXISTS idx_artifacts_kind ON artifacts(kind, deleted, created_unix_ms DESC);
	CREATE INDEX IF NOT EXISTS idx_artifacts_deleted ON artifacts(deleted, created_unix_ms DESC);
	CREATE INDEX IF NOT EXISTS idx_artifact_versions_aid ON artifact_versions(artifact_id, version_no DESC);
	CREATE INDEX IF NOT EXISTS idx_artifact_annotations_aid ON artifact_annotations(artifact_id, deleted, created_unix_ms);
	CREATE INDEX IF NOT EXISTS idx_artifact_annotations_version ON artifact_annotations(artifact_id, version_no, deleted, created_unix_ms);
	`)
	if !ok do return false
	if !artifact_db_migrate_current_version_no() do return false
	if !artifact_db_migrate_version_metadata_columns() do return false
	return true
}

artifact_db_migrate_current_version_no :: proc() -> bool {
	if artifact_db_has_column("artifacts", "current_version_no") do return true
	if !artifact_db_exec(`ALTER TABLE artifacts ADD COLUMN current_version_no INTEGER NOT NULL DEFAULT 1;`) do return false
	return artifact_db_exec(`UPDATE artifacts SET current_version_no=1 WHERE current_version_no IS NULL OR current_version_no <= 0;`)
}

artifact_db_migrate_version_metadata_columns :: proc() -> bool {
	if !artifact_db_has_column("artifact_versions", "project_id") {
		if !artifact_db_exec(`ALTER TABLE artifact_versions ADD COLUMN project_id TEXT NOT NULL DEFAULT '';`) do return false
		if !artifact_db_exec(`UPDATE artifact_versions SET project_id = COALESCE((SELECT project_id FROM artifacts WHERE artifacts.artifact_id = artifact_versions.artifact_id), '') WHERE project_id = '';`) do return false
	}
	if !artifact_db_has_column("artifact_versions", "origin_kind") {
		if !artifact_db_exec(`ALTER TABLE artifact_versions ADD COLUMN origin_kind TEXT NOT NULL DEFAULT '';`) do return false
		if !artifact_db_exec(`UPDATE artifact_versions SET origin_kind = COALESCE((SELECT origin_kind FROM artifacts WHERE artifacts.artifact_id = artifact_versions.artifact_id), '') WHERE origin_kind = '';`) do return false
	}
	if !artifact_db_has_column("artifact_versions", "origin_ref") {
		if !artifact_db_exec(`ALTER TABLE artifact_versions ADD COLUMN origin_ref TEXT NOT NULL DEFAULT '';`) do return false
		if !artifact_db_exec(`UPDATE artifact_versions SET origin_ref = COALESCE((SELECT origin_ref FROM artifacts WHERE artifacts.artifact_id = artifact_versions.artifact_id), '') WHERE origin_ref = '';`) do return false
	}
	return true
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

artifact_db_has_column :: proc(table_name, column_name: string) -> bool {
	out, ok := artifact_db_query(fmt.tprintf(`SELECT 1 FROM pragma_table_info(%s) WHERE name=%s LIMIT 1;`, sql_text(table_name), sql_text(column_name)))
	return ok && strings.trim_space(out) == "1"
}

artifact_db_insert :: proc(rec: Artifact_Record) -> bool {
	current_version_no := rec.current_version_no
	if current_version_no <= 0 do current_version_no = 1
	q := fmt.tprintf(`INSERT OR REPLACE INTO artifacts (
		artifact_id, name, kind, mime, ext, size_bytes, sha256, rel_path,
		creator_type, creator_id, project_id, origin_kind, origin_ref,
		description, current_version_no, created_unix_ms, updated_unix_ms, deleted, deleted_unix_ms
	) VALUES (%s,%s,%s,%s,%s,%d,%s,%s,%s,%s,%s,%s,%s,%s,%d,%d,%d,%d,%d);`,
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
		current_version_no,
		rec.created_unix_ms,
		rec.updated_unix_ms,
		1 if rec.deleted else 0,
		rec.deleted_unix_ms,
	)
	return artifact_db_exec(q)
}

artifact_db_update :: proc(rec: Artifact_Record) -> bool {
	current_version_no := rec.current_version_no
	if current_version_no <= 0 do current_version_no = 1
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
		current_version_no=%d,
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
		current_version_no,
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
		'current_version_no', COALESCE(current_version_no, 1),
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
		'current_version_no', COALESCE(current_version_no, 1),
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
		'current_version_no', COALESCE(current_version_no, 1),
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

artifact_db_insert_version :: proc(rec: Artifact_Version_Record) -> bool {
	q := fmt.tprintf(`INSERT OR REPLACE INTO artifact_versions (
		artifact_id, version_no, name, kind, mime, ext, size_bytes, sha256, rel_path,
		description, project_id, origin_kind, origin_ref, author_type, author_id, change_reason, created_unix_ms
	) VALUES (%s,%d,%s,%s,%s,%s,%d,%s,%s,%s,%s,%s,%s,%s,%s,%s,%d);`,
		sql_text(rec.artifact_id),
		rec.version_no,
		sql_text(rec.name),
		sql_text(rec.kind),
		sql_text(rec.mime),
		sql_text(rec.ext),
		rec.size_bytes,
		sql_text(rec.sha256),
		sql_text(rec.rel_path),
		sql_text(rec.description),
		sql_text(rec.project_id),
		sql_text(rec.origin_kind),
		sql_text(rec.origin_ref),
		sql_text(rec.author_type),
		sql_text(rec.author_id),
		sql_text(rec.change_reason),
		rec.created_unix_ms,
	)
	return artifact_db_exec(q)
}

artifact_db_version_exists :: proc(artifact_id: string, version_no: i64) -> bool {
	out, ok := artifact_db_query(fmt.tprintf(`SELECT 1 FROM artifact_versions WHERE artifact_id=%s AND version_no=%d LIMIT 1;`, sql_text(artifact_id), version_no))
	return ok && strings.trim_space(out) == "1"
}

artifact_db_get_version :: proc(artifact_id: string, version_no: i64) -> (Artifact_Version_Record, bool) {
	out, ok := artifact_db_query(fmt.tprintf(`SELECT json_object(
		'artifact_id', artifact_id,
		'version_no', version_no,
		'name', name,
		'kind', kind,
		'mime', mime,
		'ext', ext,
		'size_bytes', size_bytes,
		'sha256', sha256,
		'rel_path', rel_path,
		'description', description,
		'project_id', project_id,
		'origin_kind', origin_kind,
		'origin_ref', origin_ref,
		'author_type', author_type,
		'author_id', author_id,
		'change_reason', change_reason,
		'created_unix_ms', created_unix_ms
	) FROM artifact_versions WHERE artifact_id=%s AND version_no=%d LIMIT 1;`, sql_text(artifact_id), version_no))
	if !ok || strings.trim_space(out) == "" do return Artifact_Version_Record{}, false
	return artifact_version_record_from_json(strings.trim_space(out))
}

artifact_db_list_versions :: proc(artifact_id: string, limit: int) -> []Artifact_Version_Record {
	resolved_limit := limit
	if resolved_limit <= 0 do resolved_limit = contracts.ARTIFACT_MAX_VERSIONS
	out, ok := artifact_db_query(fmt.tprintf(`SELECT json_object(
		'artifact_id', artifact_id,
		'version_no', version_no,
		'name', name,
		'kind', kind,
		'mime', mime,
		'ext', ext,
		'size_bytes', size_bytes,
		'sha256', sha256,
		'rel_path', rel_path,
		'description', description,
		'project_id', project_id,
		'origin_kind', origin_kind,
		'origin_ref', origin_ref,
		'author_type', author_type,
		'author_id', author_id,
		'change_reason', change_reason,
		'created_unix_ms', created_unix_ms
	) FROM artifact_versions WHERE artifact_id=%s ORDER BY version_no DESC LIMIT %d;`, sql_text(artifact_id), resolved_limit))
	if !ok do return nil
	recs := make([dynamic]Artifact_Version_Record)
	for line in strings.split(strings.trim_space(out), "\n") {
		trimmed := strings.trim_space(line)
		if trimmed == "" do continue
		rec, rec_ok := artifact_version_record_from_json(trimmed)
		if !rec_ok do continue
		append(&recs, rec)
	}
	return recs[:]
}

artifact_db_delete_version :: proc(artifact_id: string, version_no: i64) -> bool {
	return artifact_db_exec(fmt.tprintf(`DELETE FROM artifact_versions WHERE artifact_id=%s AND version_no=%d;`, sql_text(artifact_id), version_no))
}

artifact_db_ensure_head_version :: proc(rec: Artifact_Record) -> (Artifact_Record, bool) {
	updated := rec
	if updated.current_version_no <= 0 {
		updated.current_version_no = 1
		if !artifact_db_update(updated) do return rec, false
	}
	if artifact_db_version_exists(updated.artifact_id, updated.current_version_no) do return updated, true
	version_no := updated.current_version_no
	if version_no <= 0 do version_no = 1
	version := Artifact_Version_Record{
		artifact_id = updated.artifact_id,
		version_no = version_no,
		name = updated.name,
		kind = updated.kind,
		mime = updated.mime,
		ext = updated.ext,
		size_bytes = updated.size_bytes,
		sha256 = updated.sha256,
		rel_path = updated.rel_path,
		description = updated.description,
		project_id = updated.project_id,
		origin_kind = updated.origin_kind,
		origin_ref = updated.origin_ref,
		author_type = updated.creator_type,
		author_id = updated.creator_id,
		change_reason = "",
		created_unix_ms = updated.created_unix_ms,
	}
	if !artifact_db_insert_version(version) do return rec, false
	return updated, true
}

artifact_db_prune_versions :: proc(artifact_id: string, retain: int) -> []Artifact_Version_Record {
	keep := retain
	if keep <= 0 do keep = contracts.ARTIFACT_MAX_VERSIONS
	versions := artifact_db_list_versions(artifact_id, keep + 64)
	if len(versions) <= keep do return nil
	pruned := make([dynamic]Artifact_Version_Record)
	for _, idx in versions {
		if idx < keep do continue
		append(&pruned, versions[idx])
	}
	return pruned[:]
}

artifact_db_insert_annotation :: proc(rec: Artifact_Annotation_Record) -> bool {
	q := fmt.tprintf(`INSERT OR REPLACE INTO artifact_annotations (
		annotation_id, artifact_id, version_no, author_type, author_id, context_type, context_json,
		comment, created_unix_ms, updated_unix_ms, deleted, deleted_unix_ms
	) VALUES (%s,%s,%d,%s,%s,%s,%s,%s,%d,%d,%d,%d);`,
		sql_text(rec.annotation_id),
		sql_text(rec.artifact_id),
		rec.version_no,
		sql_text(rec.author_type),
		sql_text(rec.author_id),
		sql_text(rec.context_type),
		sql_text(rec.context_json),
		sql_text(rec.comment),
		rec.created_unix_ms,
		rec.updated_unix_ms,
		1 if rec.deleted else 0,
		rec.deleted_unix_ms,
	)
	return artifact_db_exec(q)
}

artifact_db_get_annotation :: proc(annotation_id: string) -> (Artifact_Annotation_Record, bool) {
	out, ok := artifact_db_query(fmt.tprintf(`SELECT json_object(
		'annotation_id', annotation_id,
		'artifact_id', artifact_id,
		'version_no', version_no,
		'author_type', author_type,
		'author_id', author_id,
		'context_type', context_type,
		'context_json', context_json,
		'comment', comment,
		'created_unix_ms', created_unix_ms,
		'updated_unix_ms', updated_unix_ms,
		'deleted', deleted,
		'deleted_unix_ms', deleted_unix_ms
	) FROM artifact_annotations WHERE annotation_id=%s LIMIT 1;`, sql_text(annotation_id)))
	if !ok || strings.trim_space(out) == "" do return Artifact_Annotation_Record{}, false
	return artifact_annotation_record_from_json(strings.trim_space(out))
}

artifact_db_list_annotations :: proc(filter: Artifact_Annotation_List_Filter) -> []Artifact_Annotation_Record {
	clauses := strings.builder_make()
	strings.write_string(&clauses, fmt.tprintf(" WHERE artifact_id=%s AND deleted=0", sql_text(filter.artifact_id)))
	if filter.has_version_no do strings.write_string(&clauses, fmt.tprintf(" AND version_no=%d", filter.version_no))
	out, ok := artifact_db_query(fmt.tprintf(`SELECT json_object(
		'annotation_id', annotation_id,
		'artifact_id', artifact_id,
		'version_no', version_no,
		'author_type', author_type,
		'author_id', author_id,
		'context_type', context_type,
		'context_json', context_json,
		'comment', comment,
		'created_unix_ms', created_unix_ms,
		'updated_unix_ms', updated_unix_ms,
		'deleted', deleted,
		'deleted_unix_ms', deleted_unix_ms
	) FROM artifact_annotations%s ORDER BY created_unix_ms ASC;`, strings.to_string(clauses)))
	if !ok do return nil
	recs := make([dynamic]Artifact_Annotation_Record)
	for line in strings.split(strings.trim_space(out), "\n") {
		trimmed := strings.trim_space(line)
		if trimmed == "" do continue
		rec, rec_ok := artifact_annotation_record_from_json(trimmed)
		if !rec_ok do continue
		append(&recs, rec)
	}
	return recs[:]
}

artifact_db_update_annotation_comment :: proc(annotation_id, comment: string, updated_unix_ms: i64) -> bool {
	return artifact_db_exec(fmt.tprintf(`UPDATE artifact_annotations SET comment=%s, updated_unix_ms=%d WHERE annotation_id=%s AND deleted=0;`, sql_text(comment), updated_unix_ms, sql_text(annotation_id)))
}

artifact_db_mark_annotation_deleted :: proc(annotation_id: string, deleted_unix_ms: i64) -> bool {
	return artifact_db_exec(fmt.tprintf(`UPDATE artifact_annotations SET deleted=1, deleted_unix_ms=%d, updated_unix_ms=%d WHERE annotation_id=%s;`, deleted_unix_ms, deleted_unix_ms, sql_text(annotation_id)))
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
		current_version_no = extract_json_i64(line, "current_version_no", 1),
		created_unix_ms = extract_json_i64(line, "created_unix_ms", 0),
		updated_unix_ms = extract_json_i64(line, "updated_unix_ms", 0),
		deleted = extract_json_int(line, "deleted", 0) != 0,
		deleted_unix_ms = extract_json_i64(line, "deleted_unix_ms", 0),
	}, true
}

artifact_version_record_from_json :: proc(line: string) -> (Artifact_Version_Record, bool) {
	if strings.trim_space(line) == "" do return Artifact_Version_Record{}, false
	return Artifact_Version_Record{
		artifact_id = extract_json_string(line, "artifact_id", ""),
		version_no = extract_json_i64(line, "version_no", 0),
		name = extract_json_string(line, "name", ""),
		kind = extract_json_string(line, "kind", ""),
		mime = extract_json_string(line, "mime", ""),
		ext = extract_json_string(line, "ext", ""),
		size_bytes = extract_json_i64(line, "size_bytes", 0),
		sha256 = extract_json_string(line, "sha256", ""),
		rel_path = extract_json_string(line, "rel_path", ""),
		description = extract_json_string(line, "description", ""),
		project_id = extract_json_string(line, "project_id", ""),
		origin_kind = extract_json_string(line, "origin_kind", ""),
		origin_ref = extract_json_string(line, "origin_ref", ""),
		author_type = extract_json_string(line, "author_type", ""),
		author_id = extract_json_string(line, "author_id", ""),
		change_reason = extract_json_string(line, "change_reason", ""),
		created_unix_ms = extract_json_i64(line, "created_unix_ms", 0),
	}, true
}

artifact_annotation_record_from_json :: proc(line: string) -> (Artifact_Annotation_Record, bool) {
	if strings.trim_space(line) == "" do return Artifact_Annotation_Record{}, false
	return Artifact_Annotation_Record{
		annotation_id = extract_json_string(line, "annotation_id", ""),
		artifact_id = extract_json_string(line, "artifact_id", ""),
		version_no = extract_json_i64(line, "version_no", 0),
		author_type = extract_json_string(line, "author_type", ""),
		author_id = extract_json_string(line, "author_id", ""),
		context_type = extract_json_string(line, "context_type", ""),
		context_json = extract_json_string(line, "context_json", ""),
		comment = extract_json_string(line, "comment", ""),
		created_unix_ms = extract_json_i64(line, "created_unix_ms", 0),
		updated_unix_ms = extract_json_i64(line, "updated_unix_ms", 0),
		deleted = extract_json_int(line, "deleted", 0) != 0,
		deleted_unix_ms = extract_json_i64(line, "deleted_unix_ms", 0),
	}, true
}
