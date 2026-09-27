package http

// REQ-LEGAL-1/2/3/6: Google's OAuth consent screen requires an anonymously
// reachable privacy-policy and terms URL, and the router_dispatch gate that
// admits them must not open any other non-/api/v1 path. These tests drive
// router_dispatch through a real Router with the legal routes registered the
// same way wiring.odin registers them (ctx = nil), so the PUBLIC_PAGE_PATHS
// prefix-gate relaxation itself is under test — not just the handlers in
// isolation. A nil ctx also structurally proves the handlers cannot reach any
// auth service: they would crash on the nil deref if they tried.

import "core:strings"
import "core:testing"
import "odin_test:contracts"

@(private = "file")
legal_test_router :: proc() -> Router {
	router := new_router()
	router_add(&router, "GET", "/policy", nil, policy_page_handler)
	router_add(&router, "GET", "/toc", nil, toc_page_handler)
	return router
}

@(private = "file")
expect_404_route_not_found :: proc(t: ^testing.T, router: ^Router, req: Request) {
	resp := router_dispatch(router, req)
	defer delete(resp.body) // respond_error bodies are heap-allocated (strings.to_string)
	testing.expect_value(t, resp.status, 404)
	testing.expect(t, strings.contains(resp.body, "route not found"), "expected the hub's generic 404 body")
}

@(private = "file")
expect_public_html_page :: proc(t: ^testing.T, router: ^Router, req: Request, heading: string) {
	resp := router_dispatch(router, req)
	// Body is the POLICY/TOC_PAGE_HTML compile-time constant — nothing to free.
	testing.expect_value(t, resp.status, 200)
	testing.expect_value(t, resp.content_type, "text/html; charset=utf-8")
	testing.expect(t, strings.contains(resp.body, heading), "page must carry its heading")
	// T2 replaced T1's placeholder bodies with the real legal text: no placeholder
	// marker of any kind may survive on a page Google's verifier reads.
	testing.expect(t, !strings.contains(resp.body, "PLACEHOLDER"), "page must carry real text, not a placeholder marker")
	testing.expect(t, strings.contains(resp.body, "Broccoli Labs"), "page must name the operating entity")
	testing.expect(t, strings.contains(resp.body, "https://heimdall.mundus.in"), "page must name the public host")
	testing.expect(t, strings.contains(resp.body, "Last updated:"), "page must carry a Last updated line")
}

@(test)
test_public_page_allowlist_is_exact_match_only :: proc(t: ^testing.T) {
	testing.expect(t, is_public_page_path("/policy"), "/policy must be allowlisted")
	testing.expect(t, is_public_page_path("/toc"), "/toc must be allowlisted")
	near_misses := []string{
		"/policyx", "/policy/", "/policy/extra", "/POLICY", "/Policy", "policy", "/policy?",
		"/tocx", "/toc/", "/toc/extra", "/TOC", "//policy", "/api/v1/policy", "", "/",
	}
	for path in near_misses {
		testing.expect(t, !is_public_page_path(path), "allowlist must be exact-match only (failed for a near-miss path)")
	}
}

@(test)
test_policy_page_served_anonymously :: proc(t: ^testing.T) {
	router := legal_test_router()
	defer router_free(&router)
	// No Authorization header, no cookie, no trusted-proxy identity headers:
	// headers is nil, which is precisely the anonymous Google-verifier request.
	expect_public_html_page(t, &router, Request{method = "GET", path = "/policy"}, "Privacy Policy")
}

@(test)
test_toc_page_served_anonymously :: proc(t: ^testing.T) {
	router := legal_test_router()
	defer router_free(&router)
	expect_public_html_page(t, &router, Request{method = "GET", path = "/toc"}, "Terms of Service")
}

@(test)
test_public_pages_do_not_depend_on_proxy_identity_headers :: proc(t: ^testing.T) {
	router := legal_test_router()
	defer router_free(&router)
	// The Authentik forward-auth outpost injects X-authentik-* headers on
	// authenticated requests. The pages must render identically whether such
	// headers are present or absent; here they are present and must be ignored.
	headers := make([]contracts.HTTP_Header, 4)
	defer delete(headers)
	headers[0] = contracts.HTTP_Header{name = "Authorization", value = "Bearer must-be-ignored"}
	headers[1] = contracts.HTTP_Header{name = "Cookie", value = "session=must-be-ignored"}
	headers[2] = contracts.HTTP_Header{name = "X-Forwarded-For", value = "203.0.113.9"}
	headers[3] = contracts.HTTP_Header{name = "X-authentik-email", value = "ignored@example.com"}
	expect_public_html_page(t, &router, Request{method = "GET", path = "/policy", headers = headers[:]}, "Privacy Policy")
}

@(test)
test_neighbouring_root_paths_still_404 :: proc(t: ^testing.T) {
	router := legal_test_router()
	defer router_free(&router)
	near_misses := []string{"/policyx", "/toc/extra", "/notapage", "/POLICY", "/policy/", "//policy"}
	for path in near_misses {
		expect_404_route_not_found(t, &router, Request{method = "GET", path = path})
	}
}

@(test)
test_public_pages_serve_get_only :: proc(t: ^testing.T) {
	router := legal_test_router()
	defer router_free(&router)
	// HEAD is deliberately not registered (see legal_page_handlers.odin): the
	// response writer always sends a body, which would be wrong for HEAD, and
	// Google's verifier fetches with GET. Every non-GET method must 404.
	methods := []string{"HEAD", "POST", "PUT", "DELETE"}
	for method in methods {
		expect_404_route_not_found(t, &router, Request{method = method, path = "/policy"})
		expect_404_route_not_found(t, &router, Request{method = method, path = "/toc"})
	}
}

@(private = "file")
stub_api_route_handler :: proc(ctx: rawptr, req: Request) -> Response {
	_ = ctx
	_ = req
	return Response{status = 200, content_type = "application/json", body = "{\"ok\":true}"}
}

@(test)
test_api_v1_routing_unchanged_by_public_page_gate :: proc(t: ^testing.T) {
	router := legal_test_router()
	defer router_free(&router)
	router_add(&router, "GET", "/api/v1/health", nil, stub_api_route_handler)
	// A registered /api/v1 route still dispatches through the untouched prefix
	// branch.
	resp := router_dispatch(&router, Request{method = "GET", path = "/api/v1/health"})
	testing.expect_value(t, resp.status, 200)
	testing.expect_value(t, resp.body, "{\"ok\":true}")
	// An unknown /api/v1 path still 404s with the same generic message as
	// before the gate relaxation.
	expect_404_route_not_found(t, &router, Request{method = "GET", path = "/api/v1/not-a-route"})
}
