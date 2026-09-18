#!/usr/bin/env python3
"""Static regression tests for WebSocket task auto-loading and in-flight deduplication.

Requirements:
- REQ-WS-TASK-AUTOLOAD-1: autoLoadTaskFromWs and patchTaskInChainCaches exported in wsInvalidation.ts.
- REQ-WS-TASK-AUTOLOAD-2: in-flight request deduplication map (inFlightTasks) with pending coalescing logic.
- REQ-WS-TASK-AUTOLOAD-3: Direct cache patching for fetchTaskChainDetail ({ chainId }) and fetchChainTasks ({ chainId }).
- REQ-WS-TASK-AUTOLOAD-4: On routine task events (handleResourceChanged case 'task' and handleTaskEvent),
  autoLoadTaskFromWs is called and full-chain invalidations ({ type: 'Chain', id: chainId }) are omitted.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
WS = (ROOT / "src/ui/api/wsInvalidation.ts").read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"[-] FAIL: {message}")
        sys.exit(1)


# REQ-WS-TASK-AUTOLOAD-1: Exported helper functions
require(
    "export function autoLoadTaskFromWs(" in WS,
    "autoLoadTaskFromWs must be exported in wsInvalidation.ts",
)
require(
    "export function patchTaskInChainCaches(" in WS,
    "patchTaskInChainCaches must be exported in wsInvalidation.ts",
)
require(
    "export function getInFlightTaskCount(" in WS,
    "getInFlightTaskCount must be exported in wsInvalidation.ts",
)
require(
    "export function resetInFlightTasksForTest(" in WS,
    "resetInFlightTasksForTest must be exported in wsInvalidation.ts",
)

# REQ-WS-TASK-AUTOLOAD-2: In-flight deduplication & coalescing
require(
    "const inFlightTasks = new Map<string, InFlightTaskEntry>();" in WS,
    "inFlightTasks Map must be defined for tracking in-flight task requests",
)
require(
    "existing.pending = true;" in WS,
    "inFlightTasks must set pending = true when a request is already in-flight",
)
require(
    "if (entry?.pending) {" in WS and "executeFetch();" in WS,
    "inFlightTasks must execute follow-up fetch when pending is true on completion",
)

# REQ-WS-TASK-AUTOLOAD-3: Cache patching for fetchTaskChainDetail and fetchChainTasks
require(
    "updateQueryData('fetchTaskChainDetail', { chainId }" in WS,
    "patchTaskInChainCaches must update fetchTaskChainDetail cache for the chain",
)
require(
    "updateQueryData('fetchChainTasks', { chainId }" in WS,
    "patchTaskInChainCaches must update fetchChainTasks cache for the chain",
)
require(
    "upsertQueryData('fetchChainTaskDetail', { chainId, taskId }" in WS,
    "patchTaskInChainCaches must update fetchChainTaskDetail cache",
)

# REQ-WS-TASK-AUTOLOAD-4: Task events auto-load and omit full chain invalidation
task_case_match = re.search(r"case\s+'task':\s*\{(.*?)\n\s*case\s+'task_chain':", WS, re.DOTALL)
require(task_case_match is not None, "case 'task': block must be present before case 'task_chain':")
task_case_content = task_case_match.group(1)

require(
    "autoLoadTaskFromWs(dispatch, chainId, taskId);" in task_case_content,
    "case 'task': must invoke autoLoadTaskFromWs(dispatch, chainId, taskId)",
)
require(
    "{ type: 'Chain', id: chainId }" not in task_case_content,
    "case 'task': must NOT invalidate { type: 'Chain', id: chainId } to prevent full-chain reload",
)
require(
    "{ type: 'ChainTasks', id: chainId }" not in task_case_content,
    "case 'task': must NOT invalidate { type: 'ChainTasks', id: chainId } to prevent full-chain reload",
)

print("ALL WEBSOCKET TASK AUTO-LOAD & DEDUPLICATION STATIC TESTS PASSED")
