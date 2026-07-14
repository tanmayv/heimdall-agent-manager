#!/usr/bin/env python3
"""Source check: UI memory type dropdowns must match daemon-supported types."""

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "src" / "ui" / "components" / "App.tsx"
MEMORY_PAGE = ROOT / "src" / "ui" / "components" / "MemoryManagementPage.tsx"
MEMORY_SERVICE = ROOT / "src" / "daemon" / "memory_service.odin"
EXPECTED = ["fact", "habit", "episode", "expertise", "skill", "template"]


def fail(message: str) -> None:
    print(f"[-] FAIL: {message}")
    sys.exit(1)


def require(condition: bool, message: str) -> None:
    if not condition:
        fail(message)


def main() -> None:
    app = APP.read_text(encoding="utf-8")
    page = MEMORY_PAGE.read_text(encoding="utf-8")
    service = MEMORY_SERVICE.read_text(encoding="utf-8")

    for value in EXPECTED:
        require(f'case "{value}"' in service or f'case "", "{value}"' in service, f"daemon does not parse {value}")
        require(f'case .{value.capitalize()}' in service, f"daemon does not serialize {value}")

    expected_literal = "['" + "', '".join(EXPECTED) + "']"
    require(expected_literal in page, "MemoryManagementPage type dropdown should list supported types")
    require(expected_literal in app, "Agent detail create-memory popup should list supported types")

    unsupported = ["preference", "instruction"]
    editor_block_match = re.search(r'agent-memory-editor-type-select[\s\S]+?</select>', app)
    require(editor_block_match is not None, "agent memory editor type select not found")
    editor_block = editor_block_match.group(0)
    for value in unsupported:
        require(value not in editor_block, f"unsupported memory type remains in agent popup: {value}")

    print("UI MEMORY TYPE OPTIONS TEST PASSED")


if __name__ == "__main__":
    main()
