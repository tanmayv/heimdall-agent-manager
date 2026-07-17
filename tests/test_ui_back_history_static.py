#!/usr/bin/env python3
"""Static contract: page Back controls use in-app URL history with Home fallback."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = (ROOT / "src" / "ui" / "components" / "App.tsx").read_text(encoding="utf-8")
URL = (ROOT / "src" / "ui" / "components" / "useUrlParams.ts").read_text(encoding="utf-8")
MEMORY = (ROOT / "src" / "ui" / "components" / "MemoryManagementPage.tsx").read_text(encoding="utf-8")


def require(text: str, snippet: str, label: str) -> None:
    if snippet not in text:
        raise AssertionError(f"missing {label}: {snippet}")


def main() -> None:
    require(URL, "HEIMDALL_ROUTE_DEPTH_STATE_KEY", "route depth marker")
    require(URL, "export function canNavigateBackInApp", "can-go-back helper")
    require(URL, "export function navigateBackOr", "back-or-fallback helper")
    require(URL, "window.history.back();", "history back call")
    require(URL, "window.history.replaceState", "initial route state marker")
    require(URL, "window.history.pushState", "URL navigation state marker")

    require(APP, "import { navigateBackOr, updateUrlParams, useUrlParams }", "App history import")
    require(APP, "const navigateBackOrHome = useCallback", "central back helper")
    require(APP, "navigateBackOr({ view: 'home'", "Home fallback route")
    for snippet in [
        "onBack: navigateBackOrHome",
        "onBack={navigateBackOrHome}",
        "onBackToHome={navigateBackOrHome}",
        "debugId=\"agent-detail-back-btn\"",
        "data-debug-id=\"conversation-thread-back-btn\"",
        "data-debug-id=\"chain-back-btn\"",
    ]:
        require(APP, snippet, "App back wiring")

    if "onBack={() => selectSurfaceWithUrl('home')}" in APP:
        raise AssertionError("page Back controls must not hard-route straight to Home")
    if "← Home" in APP:
        raise AssertionError("Back controls should not be labeled Home")
    if "Back to Home" in MEMORY:
        raise AssertionError("Memory back control should not be labeled Back to Home")
    print("PASS: UI Back controls use URL history with Home fallback")


if __name__ == "__main__":
    main()
