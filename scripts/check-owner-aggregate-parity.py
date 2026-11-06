#!/usr/bin/env python3
"""Check that the C1 ledger accounts for every field of the original aggregate."""
from pathlib import Path
import re

SOURCES = (
    "src/hub/domain/taskchain.odin",
    "src/hub/domain/taskv2.odin",
    "src/hub/domain/workflow_run.odin",
    "src/hub/domain/mixed_work.odin",
)
# Read-only projections are documented as such in the ledger introduction.
PROJECTIONS = {
    "Task_Chain_Search_Change", "Task_Comment_Page_Item", "Task_Comment_Summary",
}
expected = {}
for source in SOURCES:
    current = None
    for line_no, line in enumerate(Path(source).read_text().splitlines(), 1):
        declaration = re.match(r"(\w+) :: struct \{\s*$", line)
        if declaration:
            current = declaration[1]
            continue
        if line.strip() == "}":
            current = None
        if not current or current in PROJECTIONS or line.lstrip().startswith("//"):
            continue
        member = re.match(r"\s*([\w,]+)\s*:", line)
        if member:
            for field in member[1].split(","):
                expected[(current, field)] = f"{source}:{line_no}"

actual = {}
current = None
for line in Path("docs/owner-local-aggregate-parity.md").read_text().splitlines():
    if line.startswith("### "):
        current = line[4:]
    row = re.match(r"\| `(\w+)` \| `([^\x60]+)` \|", line)
    if row:
        key = (current, row[1])
        if key in actual:
            raise SystemExit(f"Duplicate ledger field: {key}")
        actual[key] = row[2]
missing = expected.keys() - actual.keys()
extra = actual.keys() - expected.keys()
stale = {k for k in expected.keys() & actual.keys() if expected[k] != actual[k]}
if missing or extra or stale:
    raise SystemExit(f"Aggregate ledger mismatch: missing={sorted(missing)}, extra={sorted(extra)}, stale citations={sorted(stale)}")
print(f"PASS: {len(expected)} fields across {len({t for t, _ in expected})} native aggregate structs accounted for; original field citations current.")
