package http

import "core:net"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"

Handler_Proc :: proc(ctx: rawptr, req: Request) -> Response
Upgrade_Handler_Proc :: proc(ctx: rawptr, req: Request, client: net.TCP_Socket)

Request :: struct {
	method:     string,
	path:       string,
	query:      string,
	body:       string,
	request_id: string,
	remote_addr: string,
	headers:    []contracts.HTTP_Header,
}

Route :: struct {
	method:  string,
	path:    string,
	ctx:     rawptr,
	handler: Handler_Proc,
}

Upgrade_Route :: struct {
	method: string,
	path: string,
	ctx: rawptr,
	handler: Upgrade_Handler_Proc,
}

Router :: struct {
	routes: [dynamic]Route,
	upgrade_routes: [dynamic]Upgrade_Route,
}

new_router :: proc() -> Router {
	return Router{routes = make([dynamic]Route), upgrade_routes = make([dynamic]Upgrade_Route)}
}

router_free :: proc(router: ^Router) {
	for route in router.routes {
		delete(route.method)
		delete(route.path)
	}
	delete(router.routes)
	for route in router.upgrade_routes { delete(route.method); delete(route.path) }
	delete(router.upgrade_routes)
}

router_add :: proc(router: ^Router, method, path: string, ctx: rawptr, handler: Handler_Proc) {
	append(&router.routes, Route{method = strings.clone(method), path = strings.clone(path), ctx = ctx, handler = handler})
}

router_add_upgrade :: proc(router: ^Router, method, path: string, ctx: rawptr, handler: Upgrade_Handler_Proc) {
	append(&router.upgrade_routes, Upgrade_Route{method = strings.clone(method), path = strings.clone(path), ctx = ctx, handler = handler})
}

route_matches :: proc(pattern, path: string) -> bool {
	if pattern == path do return true
	pattern_parts := strings.split(pattern, "/")
	defer delete(pattern_parts)
	path_parts := strings.split(path, "/")
	defer delete(path_parts)
	if len(pattern_parts) != len(path_parts) do return false
	for part, i in pattern_parts {
		if part == "*" do continue
		if part != path_parts[i] do return false
	}
	return true
}

router_dispatch_upgrade :: proc(router: ^Router, req: Request, client: net.TCP_Socket) -> bool {
	if router == nil || !strings.has_prefix(req.path, contracts.API_V1_BASE_PATH) do return false
	for route in router.upgrade_routes {
		if route.method == req.method && route.handler != nil && route_matches(route.path, req.path) { route.handler(route.ctx, req, client); return true }
	}
	return false
}

router_dispatch :: proc(router: ^Router, req: Request) -> Response {
	if router == nil {
		return respond_error(domain.domain_error(.Internal_Error, "router is not configured"), req.request_id)
	}
	if !strings.has_prefix(req.path, contracts.API_V1_BASE_PATH) {
		return respond_error(domain.domain_error(.Not_Found, "route not found"), req.request_id)
	}
	for route in router.routes {
		if route.method == req.method && route.handler != nil && route_matches(route.path, req.path) {
			return route.handler(route.ctx, req)
		}
	}
	return respond_error(domain.domain_error(.Not_Found, "route not found"), req.request_id)
}
