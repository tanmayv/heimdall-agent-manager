#!/usr/bin/env python3
"""Static guard for H14: adding a member to a task chain via the UI actually works.

RCA: the old flow only LAUNCHED a new instance via createInstanceInChain, which
resolves { ok:false } (no throw) when the cookie-authenticated shell lacks a
session token — so newInstance was undefined, addMember was skipped, and the modal
closed with no error (silent no-op). Fix: (F1) surface any failure; (F2) add an
existing-instance path that calls addChainMember directly (cookieMutation); (F3)
rely on the Chain-tag invalidation + refetch so the member appears.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OVERVIEW = ROOT / "src" / "ui" / "components" / "taskchain" / "TaskChainOverview.tsx"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    src = OVERVIEW.read_text(encoding="utf-8")

    # --- F2: existing-instance path via addChainMember directly ---
    require("useListAgentInstancesQuery" in src,
            "must list existing instances of the chosen agent (F2)")
    require("handleAddExistingMember" in src,
            "must have an existing-instance add handler (F2)")
    require("addMember({ chainId, agentInstanceId: addExistingInstanceId, role: newMemberRole })" in src,
            "existing path must call addChainMember directly with the instance id (F2)")
    require('data-debug-id="taskchain-add-member-existing-instance-select"' in src,
            "must render the existing-instance picker (F2/F4)")
    require('data-debug-id="taskchain-add-member-mode-existing"' in src and
            'data-debug-id="taskchain-add-member-mode-launch"' in src,
            "must offer an existing vs launch mode toggle (F2/F4)")
    # Existing mode is the default (user's mental model of 'add a member').
    require("useState<'existing' | 'launch'>('existing')" in src,
            "existing-instance mode must be the default")

    # --- F1: no silent no-op — surface failures ---
    require("result?.ok === false || !newInstanceId" in src,
            "launch path must detect the resolved { ok:false } / missing instance (F1)")
    require("setAddAgentError(String(result?.message" in src,
            "launch failure must surface a visible error, not a silent no-op (F1)")
    # addMember errors are surfaced (not swallowed into console.error only).
    require("memberRes?.error" in src and "res?.error" in src,
            "addMember errors must be surfaced to the user (F1)")
    require("Instance launched but adding as chain member failed" not in src,
            "the old console.error-only swallow must be removed (F1)")

    # --- F3: list refresh relies on Chain-tag invalidation + refetch ---
    require("refetch();" in src, "must refetch after a successful add (F3)")

    # --- F4: preserve existing add-agent data-debug-ids ---
    for did in [
        "taskchain-add-agent-agentid-select",
        "taskchain-add-agent-role-select",
        "taskchain-add-agent-submit",
        "taskchain-add-agent-error",
    ]:
        require(did in src, f"existing add-agent data-debug-id {did} must be preserved (F4)")

    print("PASS: H14 taskchain add-member static guard")


if __name__ == "__main__":
    main()
