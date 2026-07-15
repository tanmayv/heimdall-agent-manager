#!/usr/bin/env python3
"""Static regression checks for agent instances + settings daemon/provider UI wiring."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "src/ui/components/App.tsx"
SETTINGS = ROOT / "src/ui/components/SettingsPage.tsx"
CHAT_SLICE = ROOT / "src/ui/store/chatSlice.ts"
DAEMON_API = ROOT / "src/ui/api/daemonApi.ts"
AGENTS = ROOT / "AGENTS.md"


def require(text: str, needle: str, message: str) -> None:
    if needle not in text:
        raise AssertionError(message)


def main() -> None:
    app = APP.read_text(encoding="utf-8")
    settings = SETTINGS.read_text(encoding="utf-8")
    chat_slice = CHAT_SLICE.read_text(encoding="utf-8")
    daemon_api = DAEMON_API.read_text(encoding="utf-8")
    agents = AGENTS.read_text(encoding="utf-8")

    for needle, message in [
        ('data-debug-id="agent-detail-new-instance-btn"', 'missing new instance button debug id'),
        ('data-debug-id={`agent-instance-row-${instance.id}`}', 'missing agent instance row debug id'),
        ('data-debug-id={`agent-instance-open-btn-${instance.id}`}', 'missing agent instance open debug id'),
        ('All concrete instances for durable agent', 'missing agent instances explanatory copy'),
        ('function DaemonSwitcher', 'daemon switcher component missing'),
        ('daemonSwitcherDotClass', 'daemon switcher color helper missing'),
    ]:
        require(app, needle, message)

    for needle, message in [
        ('data-debug-id="settings-daemon-add-btn"', 'missing settings daemon add button debug id'),
        ('data-debug-id="settings-daemons-list"', 'missing settings daemon list debug id'),
        ('data-debug-id={`settings-daemon-row-${identity || profile?.url}`}', 'missing settings daemon row debug id'),
        ('data-debug-id={`settings-daemon-color-select-${identity || profile?.url}`}', 'missing settings daemon color select debug id'),
        ('data-debug-id={`settings-daemon-connect-btn-${identity || profile?.url}`}', 'missing settings daemon connect debug id'),
        ('data-debug-id={`settings-daemon-rename-btn-${identity || profile?.url}`}', 'missing settings daemon rename debug id'),
        ('data-debug-id={`settings-daemon-remove-btn-${identity || profile?.url}`}', 'missing settings daemon remove debug id'),
        ('data-debug-id="settings-provider-daemon-pill"', 'missing provider daemon pill debug id'),
        ('data-debug-id={`settings-provider-card-${item.name}`}', 'missing provider card debug id'),
        ('function DaemonsPanel(', 'missing settings daemons panel'),
        ('function ProvidersPanel({ session, providers, preferences, onSaveDefault }: any)', 'providers panel not session-scoped'),
    ]:
        require(settings, needle, message)

    for needle, message in [
        ('fetchDaemonInfo({ daemonUrl: session.daemonUrl })', 'register session does not fetch daemon info'),
        ('updateDaemonProfileAppearance(state, action)', 'missing daemon profile appearance reducer'),
        ('daemonId: \'\'', 'session missing daemonId field'),
        ('daemonVersion: \'\'', 'session missing daemonVersion field'),
    ]:
        require(chat_slice, needle, message)

    require(daemon_api, "export async function fetchDaemonInfo", 'daemon api missing fetchDaemonInfo helper')

    for needle, message in [
        ('agent-detail-new-instance-btn', 'AGENTS registry missing new instance button'),
        ('agent-instance-row-${instanceId}', 'AGENTS registry missing agent instance row'),
        ('agent-instance-open-btn-${instanceId}', 'AGENTS registry missing agent instance open button'),
        ('settings-daemon-add-btn', 'AGENTS registry missing settings daemon add button'),
        ('settings-daemons-list', 'AGENTS registry missing settings daemons list'),
        ('settings-daemon-row-${daemonIdentity}', 'AGENTS registry missing settings daemon row'),
        ('settings-daemon-color-select-${daemonIdentity}', 'AGENTS registry missing settings daemon color select'),
        ('settings-daemon-connect-btn-${daemonIdentity}', 'AGENTS registry missing settings daemon connect'),
        ('settings-daemon-rename-btn-${daemonIdentity}', 'AGENTS registry missing settings daemon rename'),
        ('settings-daemon-remove-btn-${daemonIdentity}', 'AGENTS registry missing settings daemon remove'),
        ('settings-provider-daemon-pill', 'AGENTS registry missing settings provider daemon pill'),
        ('settings-provider-card-${providerName}', 'AGENTS registry missing settings provider card'),
    ]:
        require(agents, needle, message)

    print('PASS: agent instances + settings UI static')


if __name__ == '__main__':
    main()
