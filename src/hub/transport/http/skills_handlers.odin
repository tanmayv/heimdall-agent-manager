package http

import "core:strings"
import agent "odin_test:hub/service/agent"
import auth_service "odin_test:hub/service/auth"
import domain "odin_test:hub/domain"

// Skills_Handlers serves the compiled-in skill documents (STATIC_SKILLS). Skills
// are GLOBAL / owner-independent, but a valid token is still required (any
// authenticated caller may read them). Used by the SEARCH-5 /skills/<slug> viewer.
Skills_Handlers :: struct {
	auth: ^auth_service.Auth_Service,
}

// GET /api/v1/skills/<slug> -> {"slug","content"} for the compiled-in skill.
skill_detail_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Skills_Handlers)(ctx)
	_, ok, auth_resp := require_auth(h.auth, req)
	if !ok do return auth_resp
	slug := path_part(req.path, 4)
	content, found := skill_content_by_slug(slug)
	if !found do return respond_error(domain.domain_error(.Not_Found, "skill not found"), req.request_id)
	b := strings.builder_make()
	strings.write_string(&b, "{\"slug\":\"")
	write_handler_json_string(&b, slug)
	strings.write_string(&b, "\",\"content\":\"")
	write_handler_json_string(&b, content)
	strings.write_string(&b, "\"}")
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

// skill_content_by_slug is the pure lookup over the compiled-in skill set.
skill_content_by_slug :: proc(slug: string) -> (string, bool) {
	for skill in agent.STATIC_SKILLS {
		if skill.slug == slug do return skill.content, true
	}
	return "", false
}
