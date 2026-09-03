#!/usr/bin/env python3
"""Source check: UI memory type dropdowns must match daemon-supported types."""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
MEMORY_PAGE = ROOT / "src" / "ui" / "components" / "MemoryManagementPage.tsx"
MEMORY_SERVICE = ROOT / "src" / "daemon" / "memory_service.odin"
EXPECTED = ["fact", "habit", "episode", "expertise", "skill"]


def fail(message: str) -> None:
    print(f"[-] FAIL: {message}")
    sys.exit(1)


def require(condition: bool, message: str) -> None:
    if not condition:
        fail(message)


def main() -> None:
    page = MEMORY_PAGE.read_text(encoding="utf-8")
    service = MEMORY_SERVICE.read_text(encoding="utf-8")

    for value in EXPECTED:
        require(f'case "{value}"' in service or f'case "", "{value}"' in service, f"daemon does not parse {value}")
        require(f'case .{value.capitalize()}' in service, f"daemon does not serialize {value}")

    expected_literal = "['" + "', '".join(EXPECTED) + "']"
    require(expected_literal in page, "MemoryManagementPage type dropdown should list supported types")

    # NOTE: the agent-detail create-memory popup assertions previously scanned
    # src/ui/components/App.tsx; they were dropped when that legacy component was
    # removed (dead code; the app mounts AppShell). The daemon parse/serialize
    # contract and the live MemoryManagementPage dropdown above remain guarded.

    print("UI MEMORY TYPE OPTIONS TEST PASSED")


if __name__ == "__main__":
    main()
