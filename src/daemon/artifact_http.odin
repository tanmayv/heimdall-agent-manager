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
	include_deleted := false
	if include_deleted_str := query_param_value(ctx.query, "include_deleted"); include_deleted_str == "true" || include_deleted_str == "1" do include_deleted = true

	recs := artifact_db_list(Artifact_List_Filter{
		project_id = query_param_value(ctx.query, "project_id"),
		creator_id = query_param_value(ctx.query, "creator_id"),
		origin_ref = query_param_value(ctx.query, "origin_ref"),
		include_deleted = include_deleted,
		limit = limit,
	})

	builder := strings.builder_make()
	strings.write_string(&builder, `{"ok":true,"artifacts":[`)
	for rec, idx in recs {
		if idx > 0 do strings.write_string(&builder, `,`)
		artifact_write_public_json(&builder, rec)
	}
	strings.write_string(&builder, `]}`)
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

	data, read_ok := artifact_read_blob(rec.rel_path)
	if !read_ok {
		artifact_write_error(client, 500, "Internal Server Error", "blob_read_failed", "artifact blob missing or unreadable")
		return
	}

	validated := artifact_validate_payload(rec.kind, rec.mime, rec.ext, data, artifact_max_bytes_limit())
	if !validated.ok {
		artifact_write_validation_error(client, validated.message)
		return
	}

	headers := make([]Response_Header, 1)
	headers[0] = Response_Header{name = "Content-Disposition", value = fmt.tprintf("inline; filename=\"%s\"", artifact_header_filename(rec.name))}
	write_binary_response(client, 200, "OK", rec.mime, data, headers)
}

handle_post_artifact_update :: proc(client: net.TCP_Socket, body: string, ctx: ^Route_Context) {
	_, _, ok := artifact_authorize_identity(client, ctx)
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

	kind_hint := rec.kind
	if json_has_key(body, "kind") do kind_hint = extract_json_string(body, "kind", "")
	mime_hint := rec.mime
	if json_has_key(body, "mime") do mime_hint = extract_json_string(body, "mime", "")

	kind, mime, ext, type_ok := artifact_resolve_type(name, kind_hint, mime_hint)
	if !type_ok {
		artifact_write_error(client, 415, "Unsupported Media Type", "unsupported_type", "artifact kind/mime/ext failed allowlist validation")
		return
	}

	replace_content := json_has_key(body, "content_base64")
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
		rel_path, sha256, size_bytes, write_ok := artifact_write_blob(rec.artifact_id, data)
		if !write_ok {
			artifact_write_error(client, 500, "Internal Server Error", "blob_write_failed", "failed to overwrite artifact blob")
			return
		}
		rec.kind = validated.kind
		rec.mime = validated.mime
		rec.ext = validated.ext
		rec.rel_path = rel_path
		rec.sha256 = sha256
		rec.size_bytes = size_bytes
	} else {
		if kind != rec.kind || mime != rec.mime {
			artifact_write_error(client, 400, "Bad Request", "invalid_request", "artifact type changes require replacement content")
			return
		}
		rec.ext = ext
	}

	rec.name = name
	rec.description = description
	rec.project_id = project_id
	rec.origin_kind = origin_kind
	rec.origin_ref = origin_ref
	rec.updated_unix_ms = router_now_unix_ms()
	if !artifact_db_update(rec) {
		artifact_write_error(client, 500, "Internal Server Error", "db_write_failed", "failed to update artifact metadata")
		return
	}

	artifact_write_single_response(client, rec)
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
	rel_path, sha256, size_bytes, write_ok := artifact_write_blob(artifact_id, data)
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
		created_unix_ms = now,
		updated_unix_ms = now,
		deleted = false,
		deleted_unix_ms = 0,
	}
	if !artifact_db_insert(rec) {
		_ = artifact_delete_blob(rel_path)
		return Artifact_Create_Result{status = 500, status_text = "Internal Server Error", error_kind = "db_write_failed", message = "failed to persist artifact metadata"}
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
	artifact_write_single_response(client, rec)
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
