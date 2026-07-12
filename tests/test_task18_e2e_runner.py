#!/usr/bin/env python3
"""Static contract checks for the Task 18 canonical E2E runner."""
from pathlib import Path
import ast

ROOT = Path(__file__).resolve().parents[1]
RUNNER = ROOT / "tests" / "e2e" / "run_task18_canonical.py"
README = ROOT / "tests" / "e2e" / "README.md"

REQUIRED_SCENARIOS = [
    "coding-two-teams-real-pi",
    "solo-user-proxy",
    "research-report-memory-restart",
    "legacy-migration-copy",
    "idle-shutdown-auto-boot",
    "redux-ui-freshness",
    "coordinator-contact-invariants",
]

REQUIRED_SNIPPETS = [
    "Electron's debug UI HTTP endpoints",
    "PREFLIGHT_FAILED",
    "--allow-external-blockers",
    "openai-codex/gpt-5.3-codex-spark",
    "generated-isolated-empty",
    "operator-facing freshness diagnostics should be hidden",
    "chain-coordinator-composer-input",
    "Needs attention",
    "BS-6/UI-5/API-4",
    "user_proxy smart approval button missing",
    "real pi/Codex coding chain did not reach merge-ready/completed UI state",
    "coordinator was not booted by product on chain activation (no prelaunch)",
    "chain was not activated after UI actions (ui vs ham-ctl)",
    "coordinator message did not render exactly once (duplicate-chat regression)",
    "coordinator did not act on the delivered instruction (possible user-chat unread read-race)",
    "coordinator reply to user was never delivered (possible send_to_user NOT NULL/empty-bind regression)",
    "coordinator Plan did not use audited force bypass/unblock Implement",
    "Plan advanced via reviewer LGTM before coordinator force; deterministic force branch not exercised",
    "real coder/reviewer worker agents did not both start (coordinator should not do the work)",
    "coordinator was assigned implementation/review work (should delegate)",
    "Team_Project memory",
    "Task_Nudged",
    "migration on isolated copy did not produce a teams-v1 report",
    "Redux freshness evidence incomplete",
]


def main() -> None:
    src = RUNNER.read_text()
    ast.parse(src)
    for scenario_id in REQUIRED_SCENARIOS:
        if scenario_id not in src:
            raise AssertionError(f"missing scenario id {scenario_id}")
    for snippet in REQUIRED_SNIPPETS:
        if snippet not in src:
            raise AssertionError(f"missing runner snippet {snippet!r}")
    forbidden = ["scenario_manifest_only", "blocked_by_preflight_or_external_flow", "passed_until_real_agent_async_completion", "passed_isolated_copy_guard"]
    for token in forbidden:
        if token in src:
            raise AssertionError(f"runner still contains placeholder/shallow token {token}")
    if '~/.local/share/heimdall/wrapper-credentials.json' in src:
        raise AssertionError("runner must not hard-code global wrapper credentials")
    if "uses_global_wrapper_credentials" not in src or "wrapper_credentials_path" not in src:
        raise AssertionError("runner must expose isolated credentials provenance in preflight/transcripts")
    if "tests/e2e/README.md" and "scaffolding-only" in README.read_text().split("## Status")[-1]:
        raise AssertionError("README still describes current runner as scaffolding-only")
    print("PASS: Task 18 canonical E2E runner contract")


if __name__ == "__main__":
    main()
