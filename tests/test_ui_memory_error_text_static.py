#!/usr/bin/env python3
"""Static regression checks for memory-mutation error rendering.

Regression: the memory RTK mutations use a custom queryFn that rejects (.unwrap())
with an "CUSTOM_ERROR" object { status: "CUSTOM_ERROR", error: "<message>" }. Every
memory catch site used String(err?.data?.error || err?.message || err), which reads
neither err.error nor a real message, so it fell through to String(err) and rendered
the useless "[object Object]" popup (masking real server validation errors such as
"memory type is invalid"). Fix: a shared memoryErrorText(err) helper that reads the
CUSTOM_ERROR shape (err.error) plus FetchBaseQueryError/Error/string, used at ALL
memory catch sites. This test asserts the helper exists, reads err.error, is used
everywhere, and that the buggy String(err?.data?.error ...) pattern is gone.
"""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
MEMORY_API = ROOT / "src" / "ui" / "api" / "endpoints" / "memory.ts"
MEMORY_PAGE = ROOT / "src" / "ui" / "components" / "memory" / "MemoryPage.tsx"
MEMORY_DETAIL = ROOT / "src" / "ui" / "components" / "memory" / "MemoryDetailPage.tsx"
MEMORY_PANEL = ROOT / "src" / "ui" / "components" / "settings" / "MemoryPanel.tsx"


def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"[-] FAIL: {message}")
        sys.exit(1)


def main() -> None:
    api = MEMORY_API.read_text(encoding="utf-8")
    # The helper is defined, exported, and reads the CUSTOM_ERROR payload key (err.error).
    require("export function memoryErrorText(" in api, "memory.ts must export memoryErrorText()")
    require("e.error" in api, "memoryErrorText must read the CUSTOM_ERROR shape (err.error)")
    require('"CUSTOM_ERROR"' in api, "memory mutations must reject with the CUSTOM_ERROR shape memoryErrorText handles")

    components = {
        "MemoryPage.tsx": MEMORY_PAGE.read_text(encoding="utf-8"),
        "MemoryDetailPage.tsx": MEMORY_DETAIL.read_text(encoding="utf-8"),
        "MemoryPanel.tsx": MEMORY_PANEL.read_text(encoding="utf-8"),
    }
    for name, src in components.items():
        require("memoryErrorText" in src, f"{name} must render memory errors via memoryErrorText()")
        # The old, buggy extraction chain (which produced "[object Object]") must be gone.
        require("err?.data?.error || err?.message" not in src,
                f"{name} still uses the buggy err?.data?.error||err?.message chain (masks the real error as [object Object])")
        require("String(err?.data?.error" not in src,
                f"{name} still String()-wraps the raw error object (renders [object Object])")

    print("UI MEMORY ERROR-TEXT STATIC TEST PASSED")


if __name__ == "__main__":
    main()
