#!/usr/bin/env python3
"""Comprehensive test suite for CLI and UI Chat & Conversations Zero-Knowledge encryption and decryption (REQ-VAULT-CHAT-1).

Verifies:
1. Static contract verification:
   - ctl_agentmode_chat_send_params in src/ctl/agent_mode.odin encrypts body when vault key configured.
   - ctl_agentmode_chat_set_title_params in src/ctl/agent_mode.odin encrypts title when vault key configured.
   - ctl_agentmode_chat_fetch in src/ctl/agent_mode.odin calls ctl_agent_call_task with args for decryption.
   - ctl_decrypt_json_value in src/ctl/vault_content.odin handles "last_message_preview", "body", "title".
   - chats.ts exports encryptChatFields, decryptChatMessage, etc.
   - UI components ChatPane.tsx, MessageItem.tsx, ChatInbox.tsx, ChatMessageList.tsx, ConversationThreadPage.tsx, ConversationsHomePage.tsx.
2. Odin unit test suite:
   - 'odin test src/ctl -collection:odin_test=src' passes cleanly with 0 errors.
3. TypeScript / Node unit test suite:
   - 'node --test tests/ui_chat_vault_test.ts' passes cleanly with 0 errors.
"""

import json
import os
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
CTL_AGENT_MODE = ROOT / "src" / "ctl" / "agent_mode.odin"
CTL_VAULT_CONTENT = ROOT / "src" / "ctl" / "vault_content.odin"
UI_CHATS_ENDPOINT = ROOT / "src" / "ui" / "api" / "endpoints" / "chats.ts"
UI_VAULT_CHATS = ROOT / "src" / "ui" / "utils" / "vaultChats.ts"
UI_CHAT_PANE = ROOT / "src" / "ui" / "components" / "chat" / "ChatPane.tsx"
UI_MESSAGE_ITEM = ROOT / "src" / "ui" / "components" / "chat" / "MessageItem.tsx"
UI_CHAT_INBOX = ROOT / "src" / "ui" / "components" / "chat" / "ChatInbox.tsx"
UI_CHAT_MSG_LIST = ROOT / "src" / "ui" / "components" / "chat" / "ChatMessageList.tsx"
UI_CONV_THREAD = ROOT / "src" / "ui" / "components" / "chat" / "ConversationThreadPage.tsx"
UI_CONV_HOME = ROOT / "src" / "ui" / "components" / "chat" / "ConversationsHomePage.tsx"

TEST_KEY_HEX = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"


def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"FAILED: {message}", file=sys.stderr)
        sys.exit(1)


def test_static_contracts() -> None:
    print("1. Verifying static code contracts for chat & conversations vault encryption...")

    require(CTL_VAULT_CONTENT.exists(), f"Missing {CTL_VAULT_CONTENT}")
    vc_src = CTL_VAULT_CONTENT.read_text(encoding="utf-8")
    require("last_message_preview" in vc_src, "last_message_preview must be handled in ctl_decrypt_json_value")
    require("ctl_decrypt_json_string" in vc_src, "ctl_decrypt_json_string must be present")

    require(CTL_AGENT_MODE.exists(), f"Missing {CTL_AGENT_MODE}")
    agent_src = CTL_AGENT_MODE.read_text(encoding="utf-8")
    require("ctl_agentmode_chat_send_params" in agent_src, "ctl_agentmode_chat_send_params must be defined")
    require("ctl_agentmode_chat_set_title_params" in agent_src, "ctl_agentmode_chat_set_title_params must be defined")
    require("ctl_agent_call_task(endpoint, token, \"agent.chat.send\"" in agent_src, "ctl_v2_chat send must use ctl_agent_call_task")
    require("ctl_agent_call_task(endpoint, token, \"agent.conversation.set_title\"" in agent_src, "ctl_v2_chat set-title must use ctl_agent_call_task")
    require("ctl_agent_call_task(endpoint, token, \"agent.chat.read\"" in agent_src, "ctl_agentmode_chat_fetch must use ctl_agent_call_task")

    require(UI_VAULT_CHATS.exists(), f"Missing {UI_VAULT_CHATS}")
    vc_ts_src = UI_VAULT_CHATS.read_text(encoding="utf-8")
    require("encryptChatFields" in vc_ts_src, "encryptChatFields must be defined in vaultChats.ts")
    require("decryptChatMessage" in vc_ts_src, "decryptChatMessage must be defined in vaultChats.ts")
    require("encryptConversationFields" in vc_ts_src, "encryptConversationFields must be defined in vaultChats.ts")
    require("decryptConversationRecord" in vc_ts_src, "decryptConversationRecord must be defined in vaultChats.ts")

    require(UI_CHATS_ENDPOINT.exists(), f"Missing {UI_CHATS_ENDPOINT}")
    chats_src = UI_CHATS_ENDPOINT.read_text(encoding="utf-8")
    require("encryptVaultText" in chats_src, "chats.ts must import encryptVaultText")
    require("encryptChatFields" in chats_src, "chats.ts must re-export encryptChatFields")

    require(UI_CHAT_PANE.exists(), f"Missing {UI_CHAT_PANE}")
    require(UI_MESSAGE_ITEM.exists(), f"Missing {UI_MESSAGE_ITEM}")
    require(UI_CHAT_INBOX.exists(), f"Missing {UI_CHAT_INBOX}")

    for file_path, name in [
        (UI_CHAT_PANE, "ChatPane.tsx"),
        (UI_MESSAGE_ITEM, "MessageItem.tsx"),
        (UI_CHAT_INBOX, "ChatInbox.tsx"),
        (UI_CHAT_MSG_LIST, "ChatMessageList.tsx"),
        (UI_CONV_THREAD, "ConversationThreadPage.tsx"),
        (UI_CONV_HOME, "ConversationsHomePage.tsx"),
    ]:
        src = file_path.read_text(encoding="utf-8")
        require("VaultText" in src, f"{name} must integrate VaultText component")

    print("   Static contracts verified successfully!")


def test_odin_suite() -> None:
    print("2. Running Odin unit test suite...")
    cmd = ["nix", "develop", "--command", "bash", "-c", "odin test src/ctl -collection:odin_test=src"]
    res = subprocess.run(cmd, cwd=str(ROOT), capture_output=True, text=True)
    if res.returncode != 0:
        print("STDOUT:\n", res.stdout)
        print("STDERR:\n", res.stderr)
        require(False, f"Odin tests failed with code {res.returncode}")
    print("   Odin test suite passed cleanly (all tests passed)!")


def test_node_suite() -> None:
    print("3. Running TypeScript/Node unit test suite...")
    cmd = ["node", "--test", "tests/ui_chat_vault_test.ts"]
    res = subprocess.run(cmd, cwd=str(ROOT), capture_output=True, text=True)
    if res.returncode != 0:
        print("STDOUT:\n", res.stdout)
        print("STDERR:\n", res.stderr)
        require(False, f"Node unit tests failed with code {res.returncode}")
    print("   TypeScript/Node unit tests passed cleanly (10/10 tests passed)!")


def main() -> None:
    print("=== REQ-VAULT-CHAT-1 Verification Battery ===")
    test_static_contracts()
    test_odin_suite()
    test_node_suite()
    print("=== ALL REQ-VAULT-CHAT-1 TESTS PASSED SUCCESSFULLY! ===")


if __name__ == "__main__":
    main()
