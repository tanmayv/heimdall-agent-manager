#!/usr/bin/env python3
"""Static regression for Memory Management edit/archive verifiability (task-19f68af6e27).

Memory edit uses a supersede model: approving an edit proposal creates a NEW
active record (result.memory_id) and archives the original. The Memory
Management UI must surface/select the resulting record so the durable change is
verifiable, and the pending-approval controls must exist so edit/archive
proposals can be approved into durable state.
"""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
MEM = (ROOT / "src/ui/components/MemoryManagementPage.tsx").read_text(encoding="utf-8")


def require(cond: bool, msg: str) -> None:
    if not cond:
        print(f"[-] FAIL: {msg}")
        sys.exit(1)


# Edit submit must follow the resulting (superseding) record id, not just re-show the old one.
require("const editedId = result?.memory_id || selectedRecord.memoryId;" in MEM, "edit must read resulting memory_id from proposal result")
require("if (editedId && editedId !== selectedRecord.memoryId) onSelectMemory(editedId);" in MEM, "edit must select the resulting superseding record")
require("supersedes into ${editedId} (original archived)" in MEM, "edit success message must explain the supersede + archive outcome")
require("On approval the record becomes status=archived." in MEM, "archive success message must explain the durable outcome")

# Pending-approval controls must exist so edit/archive proposals become durable.
require('data-debug-id="memory-pending-list"' in MEM, "pending proposal list must exist")
require('data-debug-id={`memory-pending-approve-${record.memoryId}`}' in MEM, "pending approve control must exist per proposal")
require("proposalAction: 'edit'" in MEM and "proposalAction: 'archive'" in MEM, "edit and archive proposal actions must be wired")
require("expectedVersion: selectedRecord.version" in MEM, "edit/archive must send expected_version for optimistic concurrency")

print("PASS: memory edit/archive supersede UI static checks")
