#!/usr/bin/env python3
"""Static regression guard for the active daemon profile dropdown."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "src" / "ui" / "components" / "App.tsx"
CHAT_SLICE = ROOT / "src" / "ui" / "store" / "chatSlice.ts"


def main() -> None:
    app = APP.read_text()
    chat = CHAT_SLICE.read_text()

    assert "daemon-profile-select" in app, "App should render daemon profile dropdown"
    assert "daemon-profile-add-btn" in app, "App should include basic add daemon flow"
    assert "switchDaemon" in app and "updateSessionConfig" in app, "Switching should update session config"
    assert "setUrlParams({ agentId: '', taskId: '', chainId: '' })" in app, "Switch should clear daemon-specific selection params"
    assert "connectSession" in app, "Switch should reconnect/re-register after changing daemon"

    assert "DAEMON_PROFILES_KEY" in chat, "Daemon profiles should persist to localStorage"
    assert "loadDaemonProfiles" in chat, "Daemon profiles should load from localStorage"
    assert "addDaemonProfile" in chat, "Reducer should add daemon profiles"
    assert "state.agents = []" in chat and "state.chats = {}" in chat, "Daemon switch should clear stale agent/chat state"
    assert "state.session.clientToken = ''" in chat, "Daemon switch should force re-registration"
    assert "setStoredValue('odin.daemonUrl', daemonUrl)" in chat, "Active daemon should persist across reload"

    print("DAEMON PROFILE SWITCHER REGRESSION PASSED")


if __name__ == "__main__":
    main()
