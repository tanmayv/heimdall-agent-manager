#!/usr/bin/env python3
"""Regression: compact task WS fetches must update legacy tasksById projection."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
WS = (ROOT / "src/ui/api/wsInvalidation.ts").read_text(encoding="utf-8")


def require(cond: bool, msg: str) -> None:
    if not cond:
        raise SystemExit(f"FAIL: {msg}")

match = re.search(r"else if \(payload\.fetch_required && taskId\) \{(?P<body>.*?)\n\s*\}\)\.catch\(\(\) => undefined\);", WS, re.S)
require(match is not None, "compact fetch_required task branch missing")
body = match.group("body")
require("forceRefetch: true" in body, "compact branch must force authoritative task refetch")
require("dispatch(updateTaskStateDirectly(normalizedTask));" in body, "compact branch must update legacy tasksById projection")
require("updateQueryData('fetchChainTasks'" in body, "compact branch must update RTK chain task cache")
require("TODO(rtkq-task-state): collapse the legacy tasksById projection" in body, "cleanup TODO for split task caches missing")

print("task_compact_ws_legacy_projection_static: ok")
