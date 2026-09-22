package http

import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import auth_service "odin_test:hub/service/auth"
import platform "odin_test:hub/platform"

Lsp_Server_Config_Rest_Handlers :: struct {
	auth:  ^auth_service.Auth_Service,
	repo:  ^iface.Lsp_Server_Config_Repository,
	clock: ^platform.Clock,
	ids:   ^platform.ID_Generator,
}

write_lsp_server_config_json :: proc(b: ^strings.Builder, c: domain.Lsp_Server_Config) {
	strings.write_string(b, "{\"config_id\":\"")
	write_handler_json_string(b, c.config_id)
	strings.write_string(b, "\",\"bridge_id\":\"")
	write_handler_json_string(b, c.bridge_id)
	strings.write_string(b, "\",\"language\":\"")
	write_handler_json_string(b, c.language)
	strings.write_string(b, "\",\"cmd\":\"")
	write_handler_json_string(b, c.cmd)
	strings.write_string(b, "\",\"args\":\"")
	write_handler_json_string(b, c.args)
	strings.write_string(b, "\",\"file_extensions\":\"")
	write_handler_json_string(b, c.file_extensions)
	strings.write_string(b, "\",\"root_markers\":\"")
	write_handler_json_string(b, c.root_markers)
	strings.write_string(b, "\",\"dir_prefix\":\"")
	write_handler_json_string(b, c.dir_prefix)
	strings.write_string(b, "\",\"created_at\":\"")
	write_handler_json_string(b, c.created_at)
	strings.write_string(b, "\",\"updated_at\":\"")
	write_handler_json_string(b, c.updated_at)
	strings.write_string(b, "\"}")
}

// POST /api/v1/bridges/{bridge_id}/lsp-servers
// Creates or updates (upserts) an LSP server config scoped to the bridge.
// The unique key is (bridge_id, language, dir_prefix); an existing row for that
// triple is replaced in place and the config_id is refreshed to the new one.
lsp_server_config_create_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Lsp_Server_Config_Rest_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp

	bridge_id := path_part(req.path, 4)
	if bridge_id == "" {
		return respond_error(domain.domain_error(.Validation_Failed, "bridge_id is required"), req.request_id)
	}

	language := json_string(req.body, "language")
	defer delete(language)
	if language == "" {
		return respond_error(domain.domain_error(.Validation_Failed, "language is required"), req.request_id)
	}

	cmd := json_string(req.body, "cmd")
	defer delete(cmd)
	if cmd == "" {
		return respond_error(domain.domain_error(.Validation_Failed, "cmd is required"), req.request_id)
	}

	args             := json_string(req.body, "args")
	file_extensions  := json_string(req.body, "file_extensions")
	root_markers     := json_string(req.body, "root_markers")
	dir_prefix_raw   := json_string(req.body, "dir_prefix")
	defer {
		delete(args)
		delete(file_extensions)
		delete(root_markers)
		delete(dir_prefix_raw)
	}
	// Normalize: strip ALL trailing slashes so "/work/project/" or "/work/project//"
	// is stored as "/work/project". The resolver requires no trailing slash
	// (domain/lsp_server_config.odin:12-14).
	// Reject a value that consists entirely of slashes (e.g. "/") — after normalization
	// it would become "" which is the language-default sentinel, silently overwriting
	// the caller's default config rather than creating an override.
	dir_prefix := strings.trim_right(dir_prefix_raw, "/")
	if dir_prefix_raw != "" && dir_prefix == "" {
		return respond_error(domain.domain_error(.Validation_Failed, "dir_prefix must be a valid directory path; use empty string explicitly for a language default"), req.request_id)
	}

	now := platform.clock_now(h.clock)
	cfg := domain.Lsp_Server_Config{
		config_id       = platform.generate_id(h.ids, "lspcfg_"),
		owner_user_id   = auth_ctx.user_id,
		bridge_id       = bridge_id,
		language        = language,
		cmd             = cmd,
		args            = args,
		file_extensions = file_extensions,
		root_markers    = root_markers,
		dir_prefix      = dir_prefix,
		created_at      = now,
		updated_at      = now,
	}
	defer delete(cfg.config_id)

	_, err := iface.lsp_server_config_upsert(h.repo, cfg)
	if err.code != .None do return respond_error(err, req.request_id)

	b := strings.builder_make()
	strings.write_string(&b, "{\"ok\":true,\"config\":")
	write_lsp_server_config_json(&b, cfg)
	strings.write_string(&b, "}")
	body := strings.to_string(b)
	return respond_success(body, req.request_id, auth_ctx_server_time(req))
}

// GET /api/v1/bridges/{bridge_id}/lsp-servers
// Lists all LSP server configs for the authenticated user on the given bridge.
lsp_server_config_list_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Lsp_Server_Config_Rest_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp

	bridge_id := path_part(req.path, 4)
	if bridge_id == "" {
		return respond_error(domain.domain_error(.Validation_Failed, "bridge_id is required"), req.request_id)
	}

	configs, err := iface.lsp_server_config_list_by_bridge(h.repo, auth_ctx.user_id, bridge_id)
	if err.code != .None do return respond_error(err, req.request_id)
	defer domain.lsp_server_configs_destroy(configs)

	b := strings.builder_make()
	strings.write_string(&b, "{\"ok\":true,\"configs\":[")
	for c, i in configs {
		if i > 0 do strings.write_string(&b, ",")
		write_lsp_server_config_json(&b, c)
	}
	strings.write_string(&b, "]}")
	body := strings.to_string(b)
	return respond_success(body, req.request_id, auth_ctx_server_time(req))
}

// GET /api/v1/bridges/{bridge_id}/lsp-servers/resolve?language=go&path=/home/user/project/main.go
// Resolves the best LSP server config for a given (bridge, language, file path).
// Must be registered BEFORE the /lsp-servers/* wildcard route.
lsp_server_config_resolve_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Lsp_Server_Config_Rest_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp

	bridge_id := path_part(req.path, 4)
	if bridge_id == "" {
		return respond_error(domain.domain_error(.Validation_Failed, "bridge_id is required"), req.request_id)
	}

	language  := query_value(req.query, "language")
	file_path := query_value(req.query, "path")
	if language == "" {
		return respond_error(domain.domain_error(.Validation_Failed, "language query parameter is required"), req.request_id)
	}
	if file_path == "" {
		return respond_error(domain.domain_error(.Validation_Failed, "path query parameter is required"), req.request_id)
	}

	all_configs, err := iface.lsp_server_config_list_by_bridge(h.repo, auth_ctx.user_id, bridge_id)
	if err.code != .None do return respond_error(err, req.request_id)
	defer domain.lsp_server_configs_destroy(all_configs)

	// Filter to the requested language before resolving.
	lang_configs := make([dynamic]domain.Lsp_Server_Config, context.temp_allocator)
	for c in all_configs {
		if c.language == language do append(&lang_configs, c)
	}

	cfg, found := domain.lsp_server_config_resolve(lang_configs[:], file_path)
	if !found {
		return respond_error(domain.domain_error(.Not_Found, "no lsp server config found for language and path"), req.request_id)
	}

	b := strings.builder_make()
	strings.write_string(&b, "{\"ok\":true,\"config\":")
	write_lsp_server_config_json(&b, cfg)
	strings.write_string(&b, "}")
	body := strings.to_string(b)
	return respond_success(body, req.request_id, auth_ctx_server_time(req))
}

// GET /api/v1/bridges/{bridge_id}/lsp-servers/{config_id}
lsp_server_config_get_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Lsp_Server_Config_Rest_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp

	bridge_id := path_part(req.path, 4)
	config_id := path_part(req.path, 6)
	if bridge_id == "" || config_id == "" {
		return respond_error(domain.domain_error(.Not_Found, "config not found"), req.request_id)
	}

	cfg, found, err := iface.lsp_server_config_get(h.repo, auth_ctx.user_id, config_id)
	if err.code != .None do return respond_error(err, req.request_id)
	if !found do return respond_error(domain.domain_error(.Not_Found, "config not found"), req.request_id)
	defer domain.lsp_server_config_destroy(cfg)

	// Ownership check: the repo already scopes by owner_user_id, but verify explicitly.
	if cfg.owner_user_id != auth_ctx.user_id {
		return respond_error(domain.domain_error(.Forbidden, "not the config owner"), req.request_id)
	}

	b := strings.builder_make()
	strings.write_string(&b, "{\"ok\":true,\"config\":")
	write_lsp_server_config_json(&b, cfg)
	strings.write_string(&b, "}")
	body := strings.to_string(b)
	return respond_success(body, req.request_id, auth_ctx_server_time(req))
}

// DELETE /api/v1/bridges/{bridge_id}/lsp-servers/{config_id}
lsp_server_config_delete_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Lsp_Server_Config_Rest_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp

	bridge_id := path_part(req.path, 4)
	config_id := path_part(req.path, 6)
	if bridge_id == "" || config_id == "" {
		return respond_error(domain.domain_error(.Not_Found, "config not found"), req.request_id)
	}

	// Verify ownership before deleting.
	cfg, found, get_err := iface.lsp_server_config_get(h.repo, auth_ctx.user_id, config_id)
	if get_err.code != .None do return respond_error(get_err, req.request_id)
	if !found do return respond_error(domain.domain_error(.Not_Found, "config not found"), req.request_id)
	defer domain.lsp_server_config_destroy(cfg)
	if cfg.owner_user_id != auth_ctx.user_id {
		return respond_error(domain.domain_error(.Forbidden, "not the config owner"), req.request_id)
	}

	deleted, del_err := iface.lsp_server_config_delete(h.repo, auth_ctx.user_id, config_id)
	if del_err.code != .None do return respond_error(del_err, req.request_id)
	if !deleted do return respond_error(domain.domain_error(.Not_Found, "config not found"), req.request_id)
	return respond_success("{\"ok\":true}", req.request_id, auth_ctx_server_time(req))
}
