"""Guardrail: no native <select> in the UI outside the @ui component library.

Team direction: the UI does not use native form selectors — use the custom
`@ui` Select (a select-only combobox). This static check fails if a raw
`<select>` appears in src/ui/components outside `components/ui/` (the library
itself). New code must use `@ui` Select.

ALLOWLIST holds pre-existing native selects still pending migration, each with a
tracked reason. Do NOT add to it — migrate to @ui Select instead.
"""
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[1]
UI = ROOT / "src" / "ui" / "components"

# Pre-existing, tracked for migration (do not extend):
ALLOWLIST = {
    # 18 native selects that use custom option-components (MemberInstanceOption /
    # AgentInstanceOption); needs @ui Select option-parsing work — tracked follow-up.
    "taskchain/TaskChainOverview.tsx",
    # In-flight search-v2 file; migrates to @ui Select once search-v2 lands.
    "taskchain/TaskChainsPage.tsx",
}

_SELECT = re.compile(r"<select[\s>]")


def test_no_native_select_outside_ui_library():
    offenders = []
    for path in UI.rglob("*.tsx"):
        rel = path.relative_to(UI).as_posix()
        if rel.startswith("ui/"):
            continue  # the @ui library (Select's own implementation / docs)
        if rel in ALLOWLIST:
            continue
        if _SELECT.search(path.read_text(encoding="utf-8")):
            offenders.append(rel)
    assert not offenders, (
        "Native <select> is banned outside @ui — use the @ui Select component. "
        f"Offending files: {sorted(offenders)}"
    )
