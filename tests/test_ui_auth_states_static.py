#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SHELL = ROOT / "src" / "ui" / "components" / "shell" / "AppShell.tsx"
GAP = ROOT / "docs" / "plans" / "ui-backend-gap-analysis.md"
ARCH = ROOT / "docs" / "plans" / "ui-architecture.md"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    shell = SHELL.read_text()
    gap = GAP.read_text()
    arch = ARCH.read_text()

    for marker in [
        "type AuthStatus = 'checking' | 'authenticated' | 'unauthenticated' | 'forbidden' | 'error'",
        "bootstrapAuth",
        "fetch(apiUrl('/me'), { credentials: 'include' })",
        "fetch(apiUrl('/me/logout-url'), { credentials: 'include' })",
        "installApiAuthObserver",
        "heimdall:api-unauthenticated",
        "heimdall:api-forbidden",
        "response.status === 401",
        "response.status === 403",
        "UnauthenticatedLanding",
        "AccessDenied",
        "data-debug-id=\"auth-login-link\"",
        "data-debug-id=\"auth-logout-link\"",
        "window.location.assign(target)",
        "configuredAuthUrl('login')",
        "configuredAuthUrl('logout')",
        "__HEIMDALL_AUTH_CONFIG__",
        "heimdall-${kind}-url",
    ]:
        require(marker in shell, f"missing auth state marker: {marker}")

    for forbidden in [
        "password",
        "username/password form",
        "LocalLogin",
        "login-form",
        "<input",
        "type=\"password\"",
    ]:
        require(forbidden not in shell, f"local login form marker must not appear: {forbidden}")

    require("does **not** trigger the login redirect" in arch, "architecture must distinguish 403")
    require("public UI bootstrap/config" in gap, "gap doc should retain backend auth-config gap")
    require("Login URL is missing from UI auth config" in shell, "missing config state must be explicit, not hardcoded")

    print("PASS: UI auth states static")


if __name__ == "__main__":
    main()
