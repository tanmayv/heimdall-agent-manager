package main

import base64 "core:encoding/base64"
import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"
import contracts "odin_test:contracts"

Artifact_Create_Result :: struct {
	rec:         Artifact_Record,
	ok:          bool,
	status:      int,
	status_text: string,
	error_kind:  string,
	message:     string,
}

ARTIFACT_FEDERATION_FETCH_TIMEOUT_MS :: 60000

artifact_annotation_generate_id :: proc() -> string {
	artifact_id := artifact_generate_id()
	if strings.has_prefix(artifact_id, contracts.ARTIFACT_ID_PREFIX) {
		return fmt.tprintf("ann_%s", artifact_id[len(contracts.ARTIFACT_ID_PREFIX):])
	}
	return fmt.tprintf("ann_%d", router_now_unix_ms())
}

artifact_identity_type :: proc(is_user: bool) -> string {
	return "user" if is_user else "agent"
}

artifact_version_from_record :: proc(rec: Artifact_Record, author_type, author_id, change_reason: string, created_unix_ms: i64) -> Artifact_Version_Record {
	return Artifact_Version_Record{
		artifact_id = rec.artifact_id,
		version_no = rec.current_version_no,
		name = rec.name,
		kind = rec.kind,
		mime = rec.mime,
		ext = rec.ext,
		size_bytes = rec.size_bytes,
		sha256 = rec.sha256,
		rel_path = rec.rel_path,
		description = rec.description,
		project_id = rec.project_id,
		origin_kind = rec.origin_kind,
		origin_ref = rec.origin_ref,
		author_type = author_type,
		author_id = author_id,
		change_reason = change_reason,
		created_unix_ms = created_unix_ms,
	}
}

artifact_apply_version_to_head :: proc(head: Artifact_Record, version: Artifact_Version_Record, updated_unix_ms: i64) -> Artifact_Record {
	updated := head
	updated.name = version.name
	updated.kind = version.kind
	updated.mime = version.mime
	updated.ext = version.ext
	updated.size_bytes = version.size_bytes
	updated.sha256 = version.sha256
	updated.rel_path = version.rel_path
	updated.description = version.description
	updated.project_id = version.project_id
	updated.origin_kind = version.origin_kind
	updated.origin_ref = version.origin_ref
	updated.current_version_no = version.version_no
	updated.updated_unix_ms = updated_unix_ms
	return updated
}

artifact_prune_versions :: proc(artifact_id: string) {
	for version in artifact_db_prune_versions(artifact_id, contracts.ARTIFACT_MAX_VERSIONS) {
		_ = artifact_db_delete_version(version.artifact_id, version.version_no)
		if version.rel_path != "" do _ = artifact_delete_blob(version.rel_path)
	}
}

artifact_ensure_head_version_for_record :: proc(rec: Artifact_Record) -> (Artifact_Record, bool) {
	return artifact_db_ensure_head_version(rec)
}

ARTIFACT_ORIGIN_FEDERATION_REMOTE :: "federation_remote"
ARTIFACT_FEDERATION_REMOTE_REF_SEPARATOR :: "|"

artifact_is_federation_remote :: proc(rec: Artifact_Record) -> bool {
	return strings.trim_space(rec.origin_kind) == ARTIFACT_ORIGIN_FEDERATION_REMOTE
}

artifact_federation_remote_origin_ref :: proc(origin_daemon_id, remote_artifact_id: string) -> string {
	return fmt.tprintf("%s%s%s", strings.trim_space(origin_daemon_id), ARTIFACT_FEDERATION_REMOTE_REF_SEPARATOR, strings.trim_space(remote_artifact_id))
}

artifact_federation_remote_origin_ref_parse :: proc(origin_ref: string) -> (origin_daemon_id, remote_artifact_id: string, ok: bool) {
	trimmed := strings.trim_space(origin_ref)
	sep := strings.index(trimmed, ARTIFACT_FEDERATION_REMOTE_REF_SEPARATOR)
	if sep < 0 do return "", "", false
	origin_daemon_id = strings.trim_space(trimmed[:sep])
	remote_artifact_id = strings.trim_space(trimmed[sep + len(ARTIFACT_FEDERATION_REMOTE_REF_SEPARATOR):])
	if origin_daemon_id == "" || remote_artifact_id == "" do return "", "", false
	return origin_daemon_id, remote_artifact_id, true
}

artifact_federation_self_contained_eligible :: proc(rec: Artifact_Record) -> (bool, string) {
	if rec.deleted do return false, "artifact deleted"
	if strings.trim_space(rec.rel_path) == "" do return false, "artifact blob rel_path missing"
	if strings.trim_space(rec.sha256) == "" do return false, "artifact sha256 missing"
	if rec.size_bytes <= 0 do return false, "artifact size_bytes missing"
	switch strings.trim_space(rec.origin_kind) {
	case "", "direct", "chat", "comment", "test", ARTIFACT_ORIGIN_FEDERATION_REMOTE:
		return true, ""
	case:
		return false, "artifact origin is not self-contained for federation sharing"
	}
}

artifact_write_binary_content_response :: proc(client: net.TCP_Socket, rec: Artifact_Record, data: []byte) {
	validated := artifact_validate_payload(rec.kind, rec.mime, rec.ext, data, artifact_max_bytes_limit())
	if !validated.ok {
		artifact_write_validation_error(client, validated.message)
		return
	}
	headers := make([]Response_Header, 1)
	headers[0] = Response_Header{name = "Content-Disposition", value = fmt.tprintf("inline; filename=\"%s\"", artifact_header_filename(rec.name))}
	write_binary_response(client, 200, "OK", rec.mime, data, headers)
}

federation_artifact_fetch_through :: proc(origin_daemon_id, route_peer_id, artifact_id: string) -> ([]byte, bool) {
	resolved_origin_daemon_id := strings.trim_space(origin_daemon_id)
	resolved_route_peer_id := strings.trim_space(route_peer_id)
	resolved_artifact_id := strings.trim_space(artifact_id)
	if resolved_origin_daemon_id == "" || resolved_artifact_id == "" do return nil, false
	_, dest_daemon_id, peer_status, found := federation_direct_peer_lookup(resolved_route_peer_id, resolved_origin_daemon_id)
	if !found || peer_status != PEER_STATUS_LINKED || dest_daemon_id == "" do return nil, false
	path := fmt.tprintf("%s/%s", contracts.ROUTE_FEDERATION_ARTIFACTS_PREFIX, resolved_artifact_id)
	resp, fetch_ok := bridge_request(dest_daemon_id, contracts.BRIDGE_HTTP_METHOD_GET, path, "", federation_idempotency_key("artifact_fetch", server_daemon_id, resolved_artifact_id), ARTIFACT_FEDERATION_FETCH_TIMEOUT_MS)
	if !fetch_ok || resp.status != 200 {
		fmt.println("artifact_fetch_through: bridge request failed", "origin_daemon_id", resolved_origin_daemon_id, "artifact_id", resolved_artifact_id, "status", resp.status, "fetch_ok", fetch_ok)
		return nil, false
	}
	return transmute([]byte)strings.clone(resp.body), true
}

artifact_resolve_content :: proc(rec: Artifact_Record) -> (Artifact_Record, []byte, bool) {
	if data, read_ok := artifact_read_blob(rec.rel_path); read_ok {
		return rec, data, true
	}
	if !artifact_is_federation_remote(rec) do return rec, nil, false
	origin_daemon_id, remote_artifact_id, parsed := artifact_federation_remote_origin_ref_parse(rec.origin_ref)
	if !parsed do return rec, nil, false
	data, fetch_ok := federation_artifact_fetch_through(origin_daemon_id, "", remote_artifact_id)
	if !fetch_ok do return rec, nil, false
	actual_sha256 := artifact_sha256_hex(data)
	if rec.sha256 != "" && actual_sha256 != rec.sha256 {
		fmt.println("artifact_resolve_content: remote artifact sha mismatch", "artifact_id", rec.artifact_id, "remote_artifact_id", remote_artifact_id, "bytes", len(data), "expected_sha", rec.sha256, "actual_sha", actual_sha256)
		return rec, nil, false
	}
	if rec.size_bytes > 0 && i64(len(data)) != rec.size_bytes {
		fmt.println("artifact_resolve_content: remote artifact size mismatch", "artifact_id", rec.artifact_id, "remote_artifact_id", remote_artifact_id, "expected_bytes", rec.size_bytes, "actual_bytes", len(data))
		return rec, nil, false
	}
	rel_path, sha256, size_bytes, write_ok := artifact_write_blob(rec.artifact_id, rec.current_version_no, data)
	if !write_ok {
		fmt.println("artifact_resolve_content: remote artifact cache write failed", "artifact_id", rec.artifact_id, "remote_artifact_id", remote_artifact_id, "bytes", len(data))
		return rec, nil, false
	}
	updated := rec
	updated.rel_path = rel_path
	if updated.sha256 == "" do updated.sha256 = sha256
	if updated.size_bytes == 0 do updated.size_bytes = size_bytes
	updated.updated_unix_ms = router_now_unix_ms()
	if !artifact_db_update(updated) do return rec, nil, false
	return updated, data, true
}

artifact_federation_reference_upsert :: proc(route_peer_id, origin_daemon_id, remote_artifact_id, name, kind, mime, ext, description, project_id, creator_id: string, size_bytes: i64, sha256: string) -> (string, bool) {
	origin_ref := artifact_federation_remote_origin_ref(origin_daemon_id, remote_artifact_id)
	if existing, ok := artifact_db_find_origin(ARTIFACT_ORIGIN_FEDERATION_REMOTE, origin_ref); ok {
		return existing.artifact_id, true
	}
	local_artifact_id := strings.trim_space(remote_artifact_id)
	if local_artifact_id == "" do local_artifact_id = artifact_generate_id()
	if existing, ok := artifact_db_get(local_artifact_id); ok {
		if existing.origin_kind == ARTIFACT_ORIGIN_FEDERATION_REMOTE && existing.origin_ref == origin_ref {
			return existing.artifact_id, true
		}
		local_artifact_id = artifact_generate_id()
	}
	creator := strings.trim_space(creator_id)
	if creator == "" do creator = route_peer_id
	clean_name := artifact_sanitize_name(name)
	if clean_name == "" do clean_name = local_artifact_id
	rec := Artifact_Record{
		artifact_id = local_artifact_id,
		name = clean_name,
		kind = kind,
		mime = mime,
		ext = ext,
		size_bytes = size_bytes,
		sha256 = sha256,
		rel_path = "",
		creator_type = "agent",
		creator_id = creator,
		project_id = project_id,
		origin_kind = ARTIFACT_ORIGIN_FEDERATION_REMOTE,
		origin_ref = origin_ref,
		description = description,
		current_version_no = 1,
		created_unix_ms = router_now_unix_ms(),
		updated_unix_ms = router_now_unix_ms(),
		deleted = false,
		deleted_unix_ms = 0,
	}
	if !artifact_db_insert(rec) do return "", false
	return rec.artifact_id, true
}

handle_post_artifact_create :: proc(client: net.TCP_Socket, body: string, ctx: ^Route_Context) {
	author, is_user, ok := artifact_authorize_identity(client, ctx)
	if !ok do return

	result := artifact_create_record(
		author,
		is_user,
		extract_json_string(body, "name", ""),
		extract_json_string(body, "kind", ""),
		extract_json_string(body, "mime", ""),
		extract_json_string(body, "project_id", ""),
		extract_json_string(body, "origin_kind", "direct"),
		extract_json_string(body, "origin_ref", ""),
		extract_json_string(body, "description", ""),
		extract_json_string(body, "content_base64", ""),
	)
	if !result.ok {
		artifact_write_error(client, result.status, result.status_text, result.error_kind, result.message)
		return
	}

	artifact_write_create_response(client, result.rec)
}

handle_get_artifact :: proc(client: net.TCP_Socket, artifact_id: string, ctx: ^Route_Context) {
	_, _, ok := artifact_authorize_identity(client, ctx)
	if !ok do return
	artifact_write_metadata_response(client, artifact_id)
}

handle_get_artifacts :: proc(client: net.TCP_Socket, ctx: ^Route_Context) {
	_, _, ok := artifact_authorize_identity(client, ctx)
	if !ok do return

	limit := 100
	if limit_str := query_param_value(ctx.query, "limit"); limit_str != "" {
		if parsed, parse_ok := strconv.parse_int(limit_str); parse_ok do limit = int(parsed)
	}
	offset := 0
	if offset_str := query_param_value(ctx.query, "offset"); offset_str != "" {
		if parsed, parse_ok := strconv.parse_int(offset_str); parse_ok do offset = int(parsed)
	}
	include_deleted := false
	if include_deleted_str := query_param_value(ctx.query, "include_deleted"); include_deleted_str == "true" || include_deleted_str == "1" do include_deleted = true

	recs, total := artifact_db_list(Artifact_List_Filter{
		project_id = query_param_value(ctx.query, "project_id"),
		creator_id = query_param_value(ctx.query, "creator_id"),
		origin_ref = query_param_value(ctx.query, "origin_ref"),
		include_deleted = include_deleted,
		limit = limit,
		offset = offset,
	})

	has_more := limit > 0 && total > offset + len(recs)
	next_offset := offset + len(recs)

	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":true,"artifacts":[`)
	for rec, idx in recs {
		if idx > 0 do strings.write_string(&builder, `,`)
		artifact_write_public_json(&builder, rec)
	}
	strings.write_string(&builder, `],"total":`)
	strings.write_string(&builder, fmt.tprintf("%d", total))
	strings.write_string(&builder, `,"limit":`)
	strings.write_string(&builder, fmt.tprintf("%d", limit))
	strings.write_string(&builder, `,"offset":`)
	strings.write_string(&builder, fmt.tprintf("%d", offset))
	strings.write_string(&builder, `,"next_offset":`)
	strings.write_string(&builder, fmt.tprintf("%d", next_offset))
	strings.write_string(&builder, `,"has_more":`)
	strings.write_string(&builder, "true" if has_more else "false")
	strings.write_string(&builder, `}`)
	write_response(client, 200, "OK", strings.to_string(builder))
}

handle_get_artifact_content :: proc(client: net.TCP_Socket, artifact_id: string, ctx: ^Route_Context) {
	_, _, ok := artifact_authorize_identity(client, ctx)
	if !ok do return

	rec, found := artifact_db_get(artifact_id)
	if !found {
		artifact_write_error(client, 404, "Not Found", "not_found", "artifact not found")
		return
	}
	if rec.deleted {
		artifact_write_error(client, 410, "Gone", "gone", "artifact deleted")
		return
	}
	ensured, ensure_ok := artifact_ensure_head_version_for_record(rec)
	if !ensure_ok {
		artifact_write_error(client, 500, "Internal Server Error", "db_write_failed", "failed to backfill artifact version metadata")
		return
	}
	if version_str := strings.trim_space(query_param_value(ctx.query, "version")); version_str != "" {
		version_no, parse_ok := strconv.parse_i64(version_str)
		if !parse_ok || version_no <= 0 {
			artifact_write_error(client, 400, "Bad Request", "invalid_request", "version query param must be a positive integer")
			return
		}
		version, version_found := artifact_db_get_version(artifact_id, version_no)
		if !version_found {
			artifact_write_error(client, 404, "Not Found", "not_found", "artifact version not found")
			return
		}
		data, read_ok := artifact_read_blob(version.rel_path)
		if !read_ok {
			artifact_write_error(client, 500, "Internal Server Error", "blob_read_failed", "artifact version blob missing or unreadable")
			return
		}
		artifact_write_binary_content_response(client, Artifact_Record{
			artifact_id = ensured.artifact_id,
			name = version.name,
			kind = version.kind,
			mime = version.mime,
			ext = version.ext,
			size_bytes = version.size_bytes,
			sha256 = version.sha256,
			rel_path = version.rel_path,
			creator_type = ensured.creator_type,
			creator_id = ensured.creator_id,
			project_id = ensured.project_id,
			origin_kind = ensured.origin_kind,
			origin_ref = ensured.origin_ref,
			description = version.description,
			current_version_no = version.version_no,
			created_unix_ms = ensured.created_unix_ms,
			updated_unix_ms = ensured.updated_unix_ms,
			deleted = ensured.deleted,
			deleted_unix_ms = ensured.deleted_unix_ms,
		}, data)
		return
	}

	resolved_rec, data, read_ok := artifact_resolve_content(ensured)
	if !read_ok {
		artifact_write_error(client, 500, "Internal Server Error", "blob_read_failed", "artifact blob missing or unreadable")
		return
	}
	artifact_write_binary_content_response(client, resolved_rec, data)
}

handle_get_federation_artifact_content :: proc(client: net.TCP_Socket, artifact_id: string, ctx: ^Route_Context) {
	_, _, ok := federation_peer_id_for_context(ctx)
	if !ok {
		write_response(client, 401, "Unauthorized", `{"ok":false,"message":"peer not configured or token mismatch"}`)
		return
	}
	rec, found := artifact_db_get(artifact_id)
	if !found {
		artifact_write_error(client, 404, "Not Found", "not_found", "artifact not found")
		return
	}
	if ok, reason := artifact_federation_self_contained_eligible(rec); !ok {
		artifact_write_error(client, 403, "Forbidden", "not_shareable", reason)
		return
	}
	data, read_ok := artifact_read_blob(rec.rel_path)
	if !read_ok {
		artifact_write_error(client, 500, "Internal Server Error", "blob_read_failed", "artifact blob missing or unreadable")
		return
	}
	artifact_write_binary_content_response(client, rec, data)
}

handle_post_artifact_update :: proc(client: net.TCP_Socket, body: string, ctx: ^Route_Context) {
	author, is_user, ok := artifact_authorize_identity(client, ctx)
	if !ok do return

	artifact_id := extract_json_string(body, "artifact_id", "")
	if !contracts.artifact_id_valid(artifact_id) {
		artifact_write_error(client, 400, "Bad Request", "invalid_request", "artifact update requires a valid artifact_id")
		return
	}

	rec, found := artifact_db_get(artifact_id)
	if !found {
		artifact_write_error(client, 404, "Not Found", "not_found", "artifact not found")
		return
	}
	if rec.deleted {
		artifact_write_error(client, 410, "Gone", "gone", "artifact deleted")
		return
	}
	ensured, ensure_ok := artifact_ensure_head_version_for_record(rec)
	if !ensure_ok {
		artifact_write_error(client, 500, "Internal Server Error", "db_write_failed", "failed to backfill artifact version metadata")
		return
	}
	rec = ensured

	name := rec.name
	if json_has_key(body, "name") do name = artifact_sanitize_name(extract_json_string(body, "name", ""))
	if name == "" {
		artifact_write_error(client, 400, "Bad Request", "invalid_request", "artifact name cannot be empty")
		return
	}

	description := rec.description
	if json_has_key(body, "description") do description = extract_json_string(body, "description", "")
	project_id := rec.project_id
	if json_has_key(body, "project_id") do project_id = extract_json_string(body, "project_id", "")
	origin_kind := rec.origin_kind
	if json_has_key(body, "origin_kind") do origin_kind = extract_json_string(body, "origin_kind", "")
	origin_ref := rec.origin_ref
	if json_has_key(body, "origin_ref") do origin_ref = extract_json_string(body, "origin_ref", "")
	change_reason := extract_json_string(body, "change_reason", "")

	kind_hint := rec.kind
	if json_has_key(body, "kind") do kind_hint = extract_json_string(body, "kind", "")
	mime_hint := rec.mime
	if json_has_key(body, "mime") do mime_hint = extract_json_string(body, "mime", "")

	kind, mime, ext, type_ok := artifact_resolve_type(name, kind_hint, mime_hint)
	if !type_ok {
		artifact_write_error(client, 415, "Unsupported Media Type", "unsupported_type", "artifact kind/mime/ext failed allowlist validation")
		return
	}

	now := router_now_unix_ms()
	next_version_no := rec.current_version_no + 1
	updated := rec
	updated.name = name
	updated.description = description
	updated.project_id = project_id
	updated.origin_kind = origin_kind
	updated.origin_ref = origin_ref
	updated.current_version_no = next_version_no
	updated.updated_unix_ms = now

	replace_content := json_has_key(body, "content_base64")
	wrote_new_blob := false
	if replace_content {
		data, decode_ok := artifact_decode_base64_payload(extract_json_string(body, "content_base64", ""), artifact_max_bytes_limit())
		if !decode_ok {
			artifact_write_error(client, 400, "Bad Request", "invalid_request", "artifact update requires valid content_base64 when provided")
			return
		}
		validated := artifact_validate_payload(kind, mime, ext, data, artifact_max_bytes_limit())
		if !validated.ok {
			artifact_write_validation_error(client, validated.message)
			return
		}
		rel_path, sha256, size_bytes, write_ok := artifact_write_blob(rec.artifact_id, next_version_no, data)
		if !write_ok {
			artifact_write_error(client, 500, "Internal Server Error", "blob_write_failed", "failed to write artifact version blob")
			return
		}
		wrote_new_blob = true
		updated.kind = validated.kind
		updated.mime = validated.mime
		updated.ext = validated.ext
		updated.rel_path = rel_path
		updated.sha256 = sha256
		updated.size_bytes = size_bytes
	} else {
		if kind != rec.kind || mime != rec.mime {
			artifact_write_error(client, 400, "Bad Request", "invalid_request", "artifact type changes require replacement content")
			return
		}
		data, read_ok := artifact_read_blob(rec.rel_path)
		if !read_ok {
			_, resolved_data, resolve_ok := artifact_resolve_content(rec)
			if !resolve_ok {
				artifact_write_error(client, 500, "Internal Server Error", "blob_read_failed", "failed to read current artifact bytes for metadata-only versioning")
				return
			}
			data = resolved_data
		}
		rel_path, sha256, size_bytes, write_ok := artifact_write_blob(rec.artifact_id, next_version_no, data)
		if !write_ok {
			artifact_write_error(client, 500, "Internal Server Error", "blob_write_failed", "failed to write artifact version blob")
			return
		}
		wrote_new_blob = true
		updated.kind = rec.kind
		updated.mime = rec.mime
		updated.ext = ext
		updated.rel_path = rel_path
		updated.sha256 = sha256
		updated.size_bytes = size_bytes
	}

	version := artifact_version_from_record(updated, artifact_identity_type(is_user), author, change_reason, now)
	if !artifact_db_insert_version(version) {
		if wrote_new_blob do _ = artifact_delete_blob(updated.rel_path)
		artifact_write_error(client, 500, "Internal Server Error", "db_write_failed", "failed to persist artifact version metadata")
		return
	}
	if !artifact_db_update(updated) {
		_ = artifact_db_delete_version(updated.artifact_id, updated.current_version_no)
		if wrote_new_blob do _ = artifact_delete_blob(updated.rel_path)
		artifact_write_error(client, 500, "Internal Server Error", "db_write_failed", "failed to update artifact metadata")
		return
	}
	artifact_prune_versions(updated.artifact_id)
	artifact_write_single_response(client, updated)
}

handle_post_artifact_delete :: proc(client: net.TCP_Socket, body: string, ctx: ^Route_Context) {
	_, _, ok := artifact_authorize_identity(client, ctx)
	if !ok do return

	artifact_id := extract_json_string(body, "artifact_id", "")
	if !contracts.artifact_id_valid(artifact_id) {
		artifact_write_error(client, 400, "Bad Request", "invalid_request", "artifact delete requires a valid artifact_id")
		return
	}

	rec, found := artifact_db_get(artifact_id)
	if !found {
		artifact_write_error(client, 404, "Not Found", "not_found", "artifact not found")
		return
	}
	if !rec.deleted {
		_ = artifact_delete_blob(rec.rel_path)
		if !artifact_db_mark_deleted(artifact_id, router_now_unix_ms()) {
			artifact_write_error(client, 500, "Internal Server Error", "db_write_failed", "failed to mark artifact deleted")
			return
		}
	}

	b := strings.builder_make()
	strings.write_string(&b, `{"ok":true,"artifact_id":"`); json_write_string(&b, artifact_id)
	strings.write_string(&b, `","deleted":true}`)
	write_response(client, 200, "OK", strings.to_string(b))
}

artifact_create_record :: proc(author: string, is_user: bool, name, kind_hint, mime_hint, project_id, origin_kind, origin_ref, description, content_base64: string) -> Artifact_Create_Result {
	sanitized_name := artifact_sanitize_name(name)
	if sanitized_name == "" {
		return Artifact_Create_Result{status = 400, status_text = "Bad Request", error_kind = "invalid_request", message = "artifact create requires name"}
	}

	data, decode_ok := artifact_decode_base64_payload(content_base64, artifact_max_bytes_limit())
	if !decode_ok {
		return Artifact_Create_Result{status = 400, status_text = "Bad Request", error_kind = "invalid_request", message = "artifact create requires valid content_base64"}
	}

	kind, mime, ext, resolve_ok := artifact_resolve_type(sanitized_name, kind_hint, mime_hint)
	if !resolve_ok {
		return Artifact_Create_Result{status = 415, status_text = "Unsupported Media Type", error_kind = "unsupported_type", message = "artifact kind/mime/ext failed allowlist validation"}
	}

	validated := artifact_validate_payload(kind, mime, ext, data, artifact_max_bytes_limit())
	if !validated.ok {
		status := 415
		status_text := "Unsupported Media Type"
		error_kind := "unsupported_type"
		if strings.contains(validated.message, "size cap") {
			status = 413
			status_text = "Payload Too Large"
			error_kind = "payload_too_large"
		}
		return Artifact_Create_Result{status = status, status_text = status_text, error_kind = error_kind, message = validated.message}
	}

	artifact_id := artifact_generate_id()
	rel_path, sha256, size_bytes, write_ok := artifact_write_blob(artifact_id, 1, data)
	if !write_ok {
		return Artifact_Create_Result{status = 500, status_text = "Internal Server Error", error_kind = "blob_write_failed", message = "failed to write artifact blob"}
	}

	now := router_now_unix_ms()
	rec := Artifact_Record{
		artifact_id = artifact_id,
		name = sanitized_name,
		kind = validated.kind,
		mime = validated.mime,
		ext = validated.ext,
		size_bytes = size_bytes,
		sha256 = sha256,
		rel_path = rel_path,
		creator_type = "user" if is_user else "agent",
		creator_id = author,
		project_id = project_id,
		origin_kind = origin_kind,
		origin_ref = origin_ref,
		description = description,
		current_version_no = 1,
		created_unix_ms = now,
		updated_unix_ms = now,
		deleted = false,
		deleted_unix_ms = 0,
	}
	if !artifact_db_insert(rec) {
		_ = artifact_delete_blob(rel_path)
		return Artifact_Create_Result{status = 500, status_text = "Internal Server Error", error_kind = "db_write_failed", message = "failed to persist artifact metadata"}
	}
	if !artifact_db_insert_version(artifact_version_from_record(rec, rec.creator_type, rec.creator_id, "", now)) {
		_ = artifact_db_mark_deleted(rec.artifact_id, router_now_unix_ms())
		_ = artifact_delete_blob(rel_path)
		return Artifact_Create_Result{status = 500, status_text = "Internal Server Error", error_kind = "db_write_failed", message = "failed to persist artifact version metadata"}
	}

	return Artifact_Create_Result{rec = rec, ok = true, status = 200, status_text = "OK"}
}

artifact_cleanup_failed_inline_attach :: proc(rec: Artifact_Record) {
	if rec.rel_path != "" do _ = artifact_delete_blob(rec.rel_path)
	if rec.artifact_id != "" do _ = artifact_db_mark_deleted(rec.artifact_id, router_now_unix_ms())
}

artifact_append_link_body :: proc(body, artifact_id: string) -> string {
	link := contracts.artifact_make_link(artifact_id)
	trimmed := strings.trim_space(body)
	if trimmed == "" do return link
	return strings.concatenate({body, "\n\n", link})
}

artifact_authorize_identity :: proc(client: net.TCP_Socket, ctx: ^Route_Context) -> (id: string, is_user: bool, ok: bool) {
	if ctx.token == "" {
		write_response(client, 401, "Unauthorized", `{"error":"unauthorized","message":"missing authorization token"}`)
		return "", false, false
	}
	itype, iid := auth_db_get_identity(ctx.token)
	if itype == "" || iid == "" {
		write_response(client, 401, "Unauthorized", `{"error":"unauthorized","message":"invalid authorization token"}`)
		return "", false, false
	}
	return iid, itype == "user", true
}

artifact_write_metadata_response :: proc(client: net.TCP_Socket, artifact_id: string) {
	rec, found := artifact_db_get(artifact_id)
	if !found {
		artifact_write_error(client, 404, "Not Found", "not_found", "artifact not found")
		return
	}
	if rec.deleted {
		artifact_write_error(client, 410, "Gone", "gone", "artifact deleted")
		return
	}
	ensured, ok := artifact_ensure_head_version_for_record(rec)
	if !ok {
		artifact_write_error(client, 500, "Internal Server Error", "db_write_failed", "failed to backfill artifact version metadata")
		return
	}
	artifact_write_single_response(client, ensured)
}

artifact_write_single_response :: proc(client: net.TCP_Socket, rec: Artifact_Record) {
	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":true,"artifact":`)
	artifact_write_public_json(&builder, rec)
	strings.write_string(&builder, `}`)
	write_response(client, 200, "OK", strings.to_string(builder))
}

artifact_write_create_response :: proc(client: net.TCP_Socket, rec: Artifact_Record) {
	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":true,"artifact":`)
	artifact_write_public_json(&builder, rec)
	strings.write_string(&builder, `,"link":"`)
	json_write_string(&builder, contracts.artifact_make_link(rec.artifact_id))
	strings.write_string(&builder, `"}`)
	write_response(client, 200, "OK", strings.to_string(builder))
}

artifact_write_public_json :: proc(builder: ^strings.Builder, rec: Artifact_Record) {
	strings.write_string(builder, `{"artifact_id":"`); json_write_string(builder, rec.artifact_id)
	strings.write_string(builder, `","name":"`); json_write_string(builder, rec.name)
	strings.write_string(builder, `","kind":"`); json_write_string(builder, rec.kind)
	strings.write_string(builder, `","mime":"`); json_write_string(builder, rec.mime)
	strings.write_string(builder, `","ext":"`); json_write_string(builder, rec.ext)
	strings.write_string(builder, `","renderer":"`); json_write_string(builder, contracts.artifact_kind_renderer(rec.kind))
	strings.write_string(builder, `","sha256":"`); json_write_string(builder, rec.sha256)
	strings.write_string(builder, `","description":"`); json_write_string(builder, rec.description)
	strings.write_string(builder, `","project_id":"`); json_write_string(builder, rec.project_id)
	strings.write_string(builder, `","creator_type":"`); json_write_string(builder, rec.creator_type)
	strings.write_string(builder, `","creator_id":"`); json_write_string(builder, rec.creator_id)
	strings.write_string(builder, `","origin_kind":"`); json_write_string(builder, rec.origin_kind)
	strings.write_string(builder, `","origin_ref":"`); json_write_string(builder, rec.origin_ref)
	strings.write_string(builder, `","link":"`); json_write_string(builder, contracts.artifact_make_link(rec.artifact_id))
	strings.write_string(builder, `","size_bytes":`); strings.write_string(builder, fmt.tprintf("%d", rec.size_bytes))
	strings.write_string(builder, `,"current_version_no":`); strings.write_string(builder, fmt.tprintf("%d", rec.current_version_no))
	strings.write_string(builder, `,"created_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", rec.created_unix_ms))
	strings.write_string(builder, `,"updated_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", rec.updated_unix_ms))
	strings.write_string(builder, `,"deleted":`); strings.write_string(builder, "true" if rec.deleted else "false")
	strings.write_string(builder, `}`)
}

artifact_write_error :: proc(client: net.TCP_Socket, status: int, status_text, error_kind, message: string) {
	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":false,"error":"`); json_write_string(&builder, error_kind)
	strings.write_string(&builder, `","message":"`); json_write_string(&builder, message)
	strings.write_string(&builder, `"}`)
	write_response(client, status, status_text, strings.to_string(builder))
}

artifact_write_validation_error :: proc(client: net.TCP_Socket, message: string) {
	if strings.contains(message, "size cap") {
		artifact_write_error(client, 413, "Payload Too Large", "payload_too_large", message)
		return
	}
	artifact_write_error(client, 415, "Unsupported Media Type", "unsupported_type", message)
}

artifact_decode_base64_payload :: proc(content_base64: string, max_bytes: int) -> ([]byte, bool) {
	compact := artifact_compact_base64(content_base64)
	if compact == "" do return nil, false
	if !artifact_valid_base64(compact) do return nil, false
	limit := max_bytes
	if limit <= 0 do limit = artifact_max_bytes_limit()
	if base64.decoded_len(compact) > limit do return nil, false
	decoded, err := base64.decode(compact)
	if err != nil do return nil, false
	if len(decoded) > limit do return nil, false
	return decoded, true
}

artifact_valid_base64 :: proc(value: string) -> bool {
	if value == "" || len(value) % 4 != 0 do return false
	for ch, idx in value {
		switch ch {
		case 'A'..='Z', 'a'..='z', '0'..='9', '+', '/':
			if idx >= len(value) - 2 && (value[len(value) - 1] == '=' || value[len(value) - 2] == '=') {
				if ch == '+' || ch == '/' {}
			}
		case '=':
			if idx < len(value) - 2 do return false
			if idx == len(value) - 2 && value[len(value) - 1] != '=' && value[len(value) - 1] != '=' { }
		case:
			return false
		}
	}
	padding_start := strings.index_byte(value, '=')
	if padding_start >= 0 {
		for i := padding_start; i < len(value); i += 1 {
			if value[i] != '=' do return false
		}
		if len(value) - padding_start > 2 do return false
	}
	return true
}

artifact_compact_base64 :: proc(value: string) -> string {
	builder := strings.builder_make()
	for ch in value {
		switch ch {
		case ' ', '\t', '\n', '\r':
		case:
			strings.write_rune(&builder, ch)
		}
	}
	return strings.to_string(builder)
}

artifact_resolve_type :: proc(name, kind_hint, mime_hint: string) -> (kind, mime, ext: string, ok: bool) {
	sanitized_name := artifact_sanitize_name(name)
	ext = artifact_name_ext(sanitized_name)
	kind = contracts.artifact_normalize_kind(kind_hint)
	mime = contracts.artifact_normalize_mime(mime_hint)
	if kind == "" && mime != "" do kind = artifact_kind_from_mime(mime)
	if kind == "" && ext != "" do kind = artifact_kind_from_ext(ext)
	if mime == "" && kind != "" do mime = contracts.artifact_kind_mime(kind)
	if ext == "" && kind != "" do ext = contracts.artifact_kind_primary_ext(kind)
	_, validate_ok := contracts.artifact_validate_kind_mime_ext(kind, mime, ext)
	if !validate_ok do return "", "", "", false
	return kind, mime, ext, true
}

artifact_kind_from_mime :: proc(mime: string) -> string {
	switch contracts.artifact_normalize_mime(mime) {
	case contracts.ARTIFACT_MIME_MARKDOWN:
		return contracts.ARTIFACT_KIND_MARKDOWN
	case contracts.ARTIFACT_MIME_PNG:
		return contracts.ARTIFACT_KIND_PNG
	case contracts.ARTIFACT_MIME_JPEG:
		return contracts.ARTIFACT_KIND_JPEG
	case contracts.ARTIFACT_MIME_CSV:
		return contracts.ARTIFACT_KIND_CSV
	case contracts.ARTIFACT_MIME_HTML:
		return contracts.ARTIFACT_KIND_HTML
	case:
		return ""
	}
}

artifact_kind_from_ext :: proc(ext: string) -> string {
	switch contracts.artifact_normalize_ext(ext) {
	case ".md":
		return contracts.ARTIFACT_KIND_MARKDOWN
	case ".png":
		return contracts.ARTIFACT_KIND_PNG
	case ".jpg", ".jpeg":
		return contracts.ARTIFACT_KIND_JPEG
	case ".csv":
		return contracts.ARTIFACT_KIND_CSV
	case ".html", ".htm":
		return contracts.ARTIFACT_KIND_HTML
	case:
		return ""
	}
}

artifact_sanitize_name :: proc(name: string) -> string {
	trimmed := strings.trim_space(name)
	if trimmed == "" do return ""
	slash := strings.last_index_byte(trimmed, '/')
	backslash := strings.last_index_byte(trimmed, '\\')
	idx := slash
	if backslash > idx do idx = backslash
	if idx >= 0 && idx + 1 < len(trimmed) do return strings.clone(trimmed[idx + 1:])
	return strings.clone(trimmed)
}

artifact_name_ext :: proc(name: string) -> string {
	trimmed := artifact_sanitize_name(name)
	dot := strings.last_index_byte(trimmed, '.')
	if dot < 0 do return ""
	return contracts.artifact_normalize_ext(trimmed[dot:])
}

artifact_header_filename :: proc(name: string) -> string {
	builder := strings.builder_make()
	for ch in artifact_sanitize_name(name) {
		switch ch {
		case '"', '\\', '\r', '\n':
			strings.write_byte(&builder, '_')
		case:
			strings.write_rune(&builder, ch)
		}
	}
	result := strings.to_string(builder)
	if strings.trim_space(result) == "" do return "artifact"
	return result
}

artifact_write_version_json :: proc(builder: ^strings.Builder, rec: Artifact_Version_Record) {
	strings.write_string(builder, `{"artifact_id":"`); json_write_string(builder, rec.artifact_id)
	strings.write_string(builder, `","version_no":`); strings.write_string(builder, fmt.tprintf("%d", rec.version_no))
	strings.write_string(builder, `,"name":"`); json_write_string(builder, rec.name)
	strings.write_string(builder, `","kind":"`); json_write_string(builder, rec.kind)
	strings.write_string(builder, `","mime":"`); json_write_string(builder, rec.mime)
	strings.write_string(builder, `","ext":"`); json_write_string(builder, rec.ext)
	strings.write_string(builder, `","sha256":"`); json_write_string(builder, rec.sha256)
	strings.write_string(builder, `","description":"`); json_write_string(builder, rec.description)
	strings.write_string(builder, `","project_id":"`); json_write_string(builder, rec.project_id)
	strings.write_string(builder, `","origin_kind":"`); json_write_string(builder, rec.origin_kind)
	strings.write_string(builder, `","origin_ref":"`); json_write_string(builder, rec.origin_ref)
	strings.write_string(builder, `","author_type":"`); json_write_string(builder, rec.author_type)
	strings.write_string(builder, `","author_id":"`); json_write_string(builder, rec.author_id)
	strings.write_string(builder, `","change_reason":"`); json_write_string(builder, rec.change_reason)
	strings.write_string(builder, `","size_bytes":`); strings.write_string(builder, fmt.tprintf("%d", rec.size_bytes))
	strings.write_string(builder, `,"created_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", rec.created_unix_ms))
	strings.write_string(builder, `}`)
}

artifact_write_annotation_json :: proc(builder: ^strings.Builder, rec: Artifact_Annotation_Record) {
	strings.write_string(builder, `{"annotation_id":"`); json_write_string(builder, rec.annotation_id)
	strings.write_string(builder, `","artifact_id":"`); json_write_string(builder, rec.artifact_id)
	strings.write_string(builder, `","version_no":`); strings.write_string(builder, fmt.tprintf("%d", rec.version_no))
	strings.write_string(builder, `,"author_type":"`); json_write_string(builder, rec.author_type)
	strings.write_string(builder, `","author_id":"`); json_write_string(builder, rec.author_id)
	strings.write_string(builder, `","context_type":"`); json_write_string(builder, rec.context_type)
	strings.write_string(builder, `","context_json":`); strings.write_string(builder, rec.context_json)
	strings.write_string(builder, `,"comment":"`); json_write_string(builder, rec.comment)
	strings.write_string(builder, `","created_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", rec.created_unix_ms))
	strings.write_string(builder, `,"updated_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", rec.updated_unix_ms))
	strings.write_string(builder, `,"deleted":`); strings.write_string(builder, "true" if rec.deleted else "false")
	strings.write_string(builder, `,"deleted_unix_ms":`); strings.write_string(builder, fmt.tprintf("%d", rec.deleted_unix_ms))
	strings.write_string(builder, `}`)
}

handle_get_artifact_versions :: proc(client: net.TCP_Socket, artifact_id: string, ctx: ^Route_Context) {
	_, _, ok := artifact_authorize_identity(client, ctx)
	if !ok do return
	rec, found := artifact_db_get(artifact_id)
	if !found {
		artifact_write_error(client, 404, "Not Found", "not_found", "artifact not found")
		return
	}
	if rec.deleted {
		artifact_write_error(client, 410, "Gone", "gone", "artifact deleted")
		return
	}
	if _, ensure_ok := artifact_ensure_head_version_for_record(rec); !ensure_ok {
		artifact_write_error(client, 500, "Internal Server Error", "db_write_failed", "failed to backfill artifact version metadata")
		return
	}
	versions := artifact_db_list_versions(artifact_id, contracts.ARTIFACT_MAX_VERSIONS)
	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":true,"versions":[`)
	for version, idx in versions {
		if idx > 0 do strings.write_string(&builder, `,`)
		artifact_write_version_json(&builder, version)
	}
	strings.write_string(&builder, `]}`)
	write_response(client, 200, "OK", strings.to_string(builder))
}

handle_post_artifact_rollback :: proc(client: net.TCP_Socket, body: string, ctx: ^Route_Context) {
	author, is_user, ok := artifact_authorize_identity(client, ctx)
	if !ok do return
	artifact_id := extract_json_string(body, "artifact_id", "")
	version_no := extract_json_i64(body, "version_no", 0)
	if !contracts.artifact_id_valid(artifact_id) || version_no <= 0 {
		artifact_write_error(client, 400, "Bad Request", "invalid_request", "artifact rollback requires artifact_id and positive version_no")
		return
	}
	rec, found := artifact_db_get(artifact_id)
	if !found {
		artifact_write_error(client, 404, "Not Found", "not_found", "artifact not found")
		return
	}
	if rec.deleted {
		artifact_write_error(client, 410, "Gone", "gone", "artifact deleted")
		return
	}
	ensured, ensure_ok := artifact_ensure_head_version_for_record(rec)
	if !ensure_ok {
		artifact_write_error(client, 500, "Internal Server Error", "db_write_failed", "failed to backfill artifact version metadata")
		return
	}
	target, version_found := artifact_db_get_version(artifact_id, version_no)
	if !version_found {
		artifact_write_error(client, 404, "Not Found", "not_found", "artifact version not found")
		return
	}
	data, read_ok := artifact_read_blob(target.rel_path)
	if !read_ok {
		artifact_write_error(client, 500, "Internal Server Error", "blob_read_failed", "artifact version blob missing or unreadable")
		return
	}
	now := router_now_unix_ms()
	next_version_no := ensured.current_version_no + 1
	rel_path, sha256, size_bytes, write_ok := artifact_write_blob(artifact_id, next_version_no, data)
	if !write_ok {
		artifact_write_error(client, 500, "Internal Server Error", "blob_write_failed", "failed to write rollback artifact blob")
		return
	}
	rollback_version := target
	rollback_version.version_no = next_version_no
	rollback_version.rel_path = rel_path
	rollback_version.sha256 = sha256
	rollback_version.size_bytes = size_bytes
	rollback_version.change_reason = extract_json_string(body, "change_reason", "")
	rollback_version.created_unix_ms = now
	rollback_version.author_type = artifact_identity_type(is_user)
	rollback_version.author_id = author
	updated := artifact_apply_version_to_head(ensured, rollback_version, now)
	if !artifact_db_insert_version(rollback_version) {
		_ = artifact_delete_blob(rel_path)
		artifact_write_error(client, 500, "Internal Server Error", "db_write_failed", "failed to persist rollback artifact version")
		return
	}
	if !artifact_db_update(updated) {
		_ = artifact_db_delete_version(updated.artifact_id, updated.current_version_no)
		_ = artifact_delete_blob(rel_path)
		artifact_write_error(client, 500, "Internal Server Error", "db_write_failed", "failed to update artifact head during rollback")
		return
	}
	artifact_prune_versions(updated.artifact_id)
	artifact_write_single_response(client, updated)
}

handle_get_artifact_annotations :: proc(client: net.TCP_Socket, artifact_id: string, ctx: ^Route_Context) {
	_, _, ok := artifact_authorize_identity(client, ctx)
	if !ok do return
	rec, found := artifact_db_get(artifact_id)
	if !found {
		artifact_write_error(client, 404, "Not Found", "not_found", "artifact not found")
		return
	}
	if rec.deleted {
		artifact_write_error(client, 410, "Gone", "gone", "artifact deleted")
		return
	}
	filter := Artifact_Annotation_List_Filter{artifact_id = artifact_id}
	if version_str := strings.trim_space(query_param_value(ctx.query, "version")); version_str != "" {
		version_no, parse_ok := strconv.parse_i64(version_str)
		if !parse_ok || version_no <= 0 {
			artifact_write_error(client, 400, "Bad Request", "invalid_request", "version query param must be a positive integer")
			return
		}
		filter.version_no = version_no
		filter.has_version_no = true
	}
	annotations := artifact_db_list_annotations(filter)
	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":true,"annotations":[`)
	for annotation, idx in annotations {
		if idx > 0 do strings.write_string(&builder, `,`)
		artifact_write_annotation_json(&builder, annotation)
	}
	strings.write_string(&builder, `]}`)
	write_response(client, 200, "OK", strings.to_string(builder))
}

handle_post_artifact_annotation_create :: proc(client: net.TCP_Socket, body: string, ctx: ^Route_Context) {
	author, is_user, ok := artifact_authorize_identity(client, ctx)
	if !ok do return
	artifact_id := extract_json_string(body, "artifact_id", "")
	if !contracts.artifact_id_valid(artifact_id) {
		artifact_write_error(client, 400, "Bad Request", "invalid_request", "artifact annotation create requires a valid artifact_id")
		return
	}
	rec, found := artifact_db_get(artifact_id)
	if !found {
		artifact_write_error(client, 404, "Not Found", "not_found", "artifact not found")
		return
	}
	if rec.deleted {
		artifact_write_error(client, 410, "Gone", "gone", "artifact deleted")
		return
	}
	ensured, ensure_ok := artifact_ensure_head_version_for_record(rec)
	if !ensure_ok {
		artifact_write_error(client, 500, "Internal Server Error", "db_write_failed", "failed to backfill artifact version metadata")
		return
	}
	version_no := extract_json_i64(body, "version_no", ensured.current_version_no)
	if version_no <= 0 || !artifact_db_version_exists(artifact_id, version_no) {
		artifact_write_error(client, 400, "Bad Request", "invalid_request", "artifact annotation requires a retained target version")
		return
	}
	context_type := extract_json_string(body, "context_type", "")
	context_json := strings.trim_space(extract_json_string(body, "context_json", ""))
	if context_json == "" && json_has_key(body, "context_json") {
		start := json_value_start(body, "context_json")
		if start >= 0 {
			context_json = strings.trim_space(body[start:])
			if end := strings.index(context_json, ",\"comment\""); end > 0 do context_json = strings.trim_space(context_json[:end])
		}
	}
	if context_type == "" || context_json == "" {
		artifact_write_error(client, 400, "Bad Request", "invalid_request", "artifact annotation create requires context_type and context_json")
		return
	}
	now := router_now_unix_ms()
	annotation := Artifact_Annotation_Record{
		annotation_id = artifact_annotation_generate_id(),
		artifact_id = artifact_id,
		version_no = version_no,
		author_type = artifact_identity_type(is_user),
		author_id = author,
		context_type = context_type,
		context_json = context_json,
		comment = extract_json_string(body, "comment", ""),
		created_unix_ms = now,
		updated_unix_ms = now,
		deleted = false,
		deleted_unix_ms = 0,
	}
	if !artifact_db_insert_annotation(annotation) {
		artifact_write_error(client, 500, "Internal Server Error", "db_write_failed", "failed to persist artifact annotation")
		return
	}
	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":true,"annotation":`)
	artifact_write_annotation_json(&builder, annotation)
	strings.write_string(&builder, `}`)
	write_response(client, 200, "OK", strings.to_string(builder))
}

handle_post_artifact_annotation_update :: proc(client: net.TCP_Socket, body: string, ctx: ^Route_Context) {
	_, _, ok := artifact_authorize_identity(client, ctx)
	if !ok do return
	annotation_id := extract_json_string(body, "annotation_id", "")
	annotation, found := artifact_db_get_annotation(annotation_id)
	if !found || annotation.deleted {
		artifact_write_error(client, 404, "Not Found", "not_found", "artifact annotation not found")
		return
	}
	updated_comment := extract_json_string(body, "comment", annotation.comment)
	now := router_now_unix_ms()
	if !artifact_db_update_annotation_comment(annotation_id, updated_comment, now) {
		artifact_write_error(client, 500, "Internal Server Error", "db_write_failed", "failed to update artifact annotation")
		return
	}
	annotation.comment = updated_comment
	annotation.updated_unix_ms = now
	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":true,"annotation":`)
	artifact_write_annotation_json(&builder, annotation)
	strings.write_string(&builder, `}`)
	write_response(client, 200, "OK", strings.to_string(builder))
}

handle_post_artifact_annotation_delete :: proc(client: net.TCP_Socket, body: string, ctx: ^Route_Context) {
	_, _, ok := artifact_authorize_identity(client, ctx)
	if !ok do return
	annotation_id := extract_json_string(body, "annotation_id", "")
	annotation, found := artifact_db_get_annotation(annotation_id)
	if !found || annotation.deleted {
		artifact_write_error(client, 404, "Not Found", "not_found", "artifact annotation not found")
		return
	}
	now := router_now_unix_ms()
	if !artifact_db_mark_annotation_deleted(annotation_id, now) {
		artifact_write_error(client, 500, "Internal Server Error", "db_write_failed", "failed to delete artifact annotation")
		return
	}
	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":true,"annotation_id":"`); json_write_string(&builder, annotation_id)
	strings.write_string(&builder, `","deleted":true}`)
	write_response(client, 200, "OK", strings.to_string(builder))
}
