#!/usr/bin/env python3
"""Source regression for Fig Google3 detection."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
TASK_SERVICE = ROOT / "src/daemon/task_service.odin"
APP = ROOT / "src/ui/components/App.tsx"
SETTINGS = ROOT / "src/ui/components/SettingsPage.tsx"

def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"[-] FAIL: {message}")
        sys.exit(1)

def main() -> None:
    task_service = TASK_SERVICE.read_text(encoding="utf-8")
    app = APP.read_text(encoding="utf-8")
    settings = SETTINGS.read_text(encoding="utf-8")

    require("is_google3_path :: proc(path: string) -> bool {" in task_service, "is_google3_path helper missing")
    require("if p == \"google3\" do return true" in task_service, "google3 path check logic missing")
    require("if is_google3_path(repo) {" in task_service, "google3 path overrides auto detection missing")
    require("backend_kind = .Fig" in task_service, "should assign .Fig backend")
    require("|| kind == \"fig\" || is_google3_path(repo)" in task_service, "should exclude fig and google3 from git diff check")

    require("\"fig\"" in app, "App should explicitly support fig option")
    require("\"fig\"" in settings, "Settings should explicitly support fig option")

    print("[+] All source regression checks for Fig google3 passed.")

if __name__ == "__main__":
    main()
