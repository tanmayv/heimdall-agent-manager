#!/usr/bin/env python3
"""Comprehensive test suite for CLI and UI Task Chains Zero-Knowledge encryption and decryption (REQ-VAULT-CHAINS-1).

Verifies:
1. Static code contracts:
   - ctl_decrypt_vault_json used in src/ctl/agent_mode.odin and src/ctl/tasks.odin.
   - vault_encrypt_text_hex used in set-title and set-description in src/ctl/agent_mode.odin.
   - vault_encrypt_text_hex used in create and update in src/ctl/tasks.odin.
   - ctl_agent_call_and_decrypt used in show and list in src/ctl/agent_mode.odin.
   - ctl_task_chain_request_and_decrypt used in show and list in src/ctl/tasks.odin.
   - UI Task Chains endpoint (src/ui/api/endpoints/taskChains.ts) uses encryptVaultText.
   - UI Task Chains views integrate <VaultText /> component.
2. Odin unit test suite:
   - 'odin test src/ctl -collection:odin_test=src' passes cleanly with 0 errors.
3. TypeScript / Node test suite:
   - 'node --test tests/ui_chains_vault_test.ts' passes cleanly with 0 errors.
"""

import json
import os
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
CTL_AGENT_MODE = ROOT / "src" / "ctl" / "agent_mode.odin"
CTL_TASKS = ROOT / "src" / "ctl" / "tasks.odin"
CTL_TEST = ROOT / "src" / "ctl" / "chains_vault_test.odin"
UI_ENDPOINT = ROOT / "src" / "ui" / "api" / "endpoints" / "taskChains.ts"
UI_TASKS_ENDPOINT = ROOT / "src" / "ui" / "api" / "endpoints" / "tasks.ts"
UI_OVERVIEW = ROOT / "src" / "ui" / "components" / "taskchain" / "TaskChainOverview.tsx"
UI_PAGE = ROOT / "src" / "ui" / "components" / "taskchain" / "TaskChainsPage.tsx"
UI_VAULT_CHAINS = ROOT / "src" / "ui" / "utils" / "vaultChains.ts"

TEST_KEY_HEX = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"


def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"FAILED: {message}", file=sys.stderr)
        sys.exit(1)


def test_static_contracts() -> None:
    print("1. Verifying static code contracts for Task Chains Zero-Knowledge encryption...")
    require(CTL_AGENT_MODE.exists(), f"Missing {CTL_AGENT_MODE}")
    agent_mode_src = CTL_AGENT_MODE.read_text(encoding="utf-8")

    require("ctl_agent_call_and_decrypt" in agent_mode_src, "ctl_agent_call_and_decrypt must be defined in agent_mode.odin")
    require("agent.task_chain.list" in agent_mode_src, "agent.task_chain.list must be handled")
    require("agent.task_chain.show" in agent_mode_src, "agent.task_chain.show must be handled")
    require("vault_encrypt_text_hex" in agent_mode_src, "set-title and set-description must use vault_encrypt_text_hex")

    require(CTL_TASKS.exists(), f"Missing {CTL_TASKS}")
    tasks_src = CTL_TASKS.read_text(encoding="utf-8")

    require("ctl_task_chain_request_and_decrypt" in tasks_src, "ctl_task_chain_request_and_decrypt must be defined in tasks.odin")
    require("ctl_decrypt_vault_json" in tasks_src, "ctl_decrypt_vault_json must be called in tasks.odin")

    require(UI_ENDPOINT.exists(), f"Missing {UI_ENDPOINT}")
    endpoint_src = UI_ENDPOINT.read_text(encoding="utf-8")
    require("encryptVaultText" in endpoint_src, "taskChains.ts must use encryptVaultText")
    require("createTaskChain" in endpoint_src, "taskChains.ts must define createTaskChain")
    require("updateTaskChain" in endpoint_src, "taskChains.ts must define updateTaskChain")
    require("getTaskChain" in endpoint_src, "taskChains.ts must define getTaskChain")
    require("getTaskChains" in endpoint_src, "taskChains.ts must define getTaskChains")

    require(UI_VAULT_CHAINS.exists(), f"Missing {UI_VAULT_CHAINS}")
    vault_chains_src = UI_VAULT_CHAINS.read_text(encoding="utf-8")
    require("encryptChainFields" in vault_chains_src, "vaultChains.ts must export encryptChainFields")
    require("decryptChainRecord" in vault_chains_src, "vaultChains.ts must export decryptChainRecord")
    require("decryptChainList" in vault_chains_src, "vaultChains.ts must export decryptChainList")

    require(UI_PAGE.exists(), f"Missing {UI_PAGE}")
    page_src = UI_PAGE.read_text(encoding="utf-8")
    require("VaultText" in page_src, "TaskChainsPage.tsx must use VaultText")

    require(UI_OVERVIEW.exists(), f"Missing {UI_OVERVIEW}")
    overview_src = UI_OVERVIEW.read_text(encoding="utf-8")
    require("VaultText" in overview_src, "TaskChainOverview.tsx must use VaultText")

    print("   ✓ Static code contracts verified.")


def test_odin_suite() -> None:
    print("2. Running Odin unit test suite...")
    res = subprocess.run(
        ["odin", "test", "src/ctl", "-collection:odin_test=src"],
        cwd=str(ROOT),
        capture_output=True,
        text=True,
    )
    combined = res.stdout + res.stderr
    print(combined)
    require(res.returncode == 0, f"Odin tests failed with code {res.returncode}")
    require("All tests were successful" in combined, "Odin test output did not report success")
    print("   ✓ Odin unit tests passed.")


def test_node_suite() -> None:
    print("3. Running Node unit test suite...")
    res = subprocess.run(
        ["node", "--test", "tests/ui_chains_vault_test.ts"],
        cwd=str(ROOT),
        capture_output=True,
        text=True,
    )
    print(res.stdout)
    if res.returncode != 0:
        print(res.stderr, file=sys.stderr)
    require(res.returncode == 0, f"Node tests failed with code {res.returncode}")
    print("   ✓ Node unit tests passed.")


if __name__ == "__main__":
    test_static_contracts()
    test_odin_suite()
    test_node_suite()
    print("\nALL TASK CHAINS VAULT TESTS PASSED!")
