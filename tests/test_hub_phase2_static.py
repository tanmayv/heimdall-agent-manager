#!/usr/bin/env python3
"""Static checks for Phase 2 auth/dev-proxy requirements (HBR-5..HBR-7)."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def require(ok: bool, message: str) -> None:
    if not ok:
        raise AssertionError(message)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def test_auth_service_shape() -> None:
    auth = read(ROOT / "src/hub/service/auth/auth_service.odin") + read(ROOT / "src/hub/service/user/user_service.odin")
    for snippet in [
        "trusted_proxy_cidrs",
        "remote_addr_trusted",
        "trusted proxy username header is missing",
        "ensure_user_from_auth",
        "user is disabled",
        "token_in_query_or_body",
        "bearer tokens must use the Authorization header",
    ]:
        require(snippet in auth, f"auth service missing {snippet}")
    require("query_param_present(req.query" not in auth, "auth checks should be centralized through token_in_query_or_body")


def test_real_listener_uses_tcp_peer_for_auth() -> None:
    server = read(ROOT / "src/hub/transport/http/server.odin")
    require("client, source, accept_err := net.accept_tcp(listener)" in server, "HTTP listener must retain accepted TCP peer endpoint")
    require("remote_addr = net.address_to_string_allocator(source.address)" in server, "Request.remote_addr must come from accepted peer address")
    require('remote_addr = "127.0.0.1"' not in server, "HTTP listener must not hardcode trusted remote_addr")


def test_me_routes_wired() -> None:
    wiring = read(ROOT / "src/hub/app/wiring.odin")
    handlers = read(ROOT / "src/hub/transport/http/user_handlers.odin")
    for route in ['"/api/v1/me"', '"/api/v1/me/logout-url"']:
        require(route in wiring, f"missing route {route}")
    require("require_auth" in handlers, "/me handlers must require auth")
    require("logout_url" in handlers, "logout handler must return configured logout URL")


def test_dev_proxy_is_standalone_and_strips_headers() -> None:
    dev_files = list((ROOT / "src/dev_proxy").glob("*.odin"))
    require(dev_files, "src/dev_proxy standalone binary missing")
    joined = "\n".join(read(p) for p in dev_files)
    require('import app "odin_test:hub/app"' not in joined and 'odin_test:hub/' not in joined, "dev_proxy must not import Hub packages")
    for snippet in [
        "rewrite_headers_for_hub",
        "is_client_control_header",
        "X-authentik-username",
        "X-authentik-name",
        "X-authentik-email",
        "Authorization",
        "X-Dev-User",
        "ham_dev_user",
        "login_response_cookie",
        "logout_response_cookie",
    ]:
        require(snippet in joined, f"dev_proxy missing behavior marker {snippet}")
    require("ham-dev-proxy" in read(ROOT / "flake.nix"), "flake must package ham-dev-proxy")


if __name__ == "__main__":
    test_auth_service_shape()
    test_real_listener_uses_tcp_peer_for_auth()
    test_me_routes_wired()
    test_dev_proxy_is_standalone_and_strips_headers()
    print("PASS: hub phase2 static")
