#!/usr/bin/env python3
"""Static regression: the sidebar bridge legend hides revoked Bridges."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SHELL = ROOT / "src" / "ui" / "components" / "shell" / "AppShell.tsx"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    shell = SHELL.read_text(encoding="utf-8")
    require("function bridgeIsRevoked" in shell, "AppShell must define revoked-bridge detection")
    require("status === 'revoked'" in shell, "revoked status must be hidden from sidebar legend")
    require("bridge?.revoked_at" in shell and "bridge?.revokedAt" in shell, "revoked timestamp aliases must be hidden")
    require(".filter((bridge: any) => !bridgeIsRevoked(bridge))" in shell, "sidebar bridge legend must filter revoked Bridges")
    require("data-debug-id=\"sidebar-bridge-legend\"" in shell, "sidebar bridge legend should still exist for active Bridges")
    print("PASS: sidebar bridge legend hides revoked Bridges")


if __name__ == "__main__":
    main()
