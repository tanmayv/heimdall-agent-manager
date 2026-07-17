from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
SETTINGS = (ROOT / 'src/ui/components/SettingsPage.tsx').read_text(encoding='utf-8')
PICKER = (ROOT / 'src/ui/components/AgentPicker.tsx').read_text(encoding='utf-8')
APP = (ROOT / 'src/ui/components/App.tsx').read_text(encoding='utf-8')
CHAT = (ROOT / 'src/ui/store/chatSlice.ts').read_text(encoding='utf-8')
AGENTS_MD = (ROOT / 'AGENTS.md').read_text(encoding='utf-8')
CHAIN_VIEW_SECTION = APP.split('function ChainView(', 1)[1].split('function GlobalRightSidebar(', 1)[0] if 'function ChainView(' in APP and 'function GlobalRightSidebar(' in APP else ''


def require(condition: bool, message: str):
    if not condition:
        print(f'FAIL: {message}')
        sys.exit(1)


require('settings-peer-daemon-list' in SETTINGS, 'settings peer daemon section missing')
require('settings-peer-daemon-token-input' in SETTINGS, 'peer token input should be write-only UI field')
require('daemonApi.listFederationPeers' in SETTINGS, 'settings should load federation peers live')
require('daemonApi.linkFederationPeer' in SETTINGS, 'settings should connect peer daemons')
require('daemonApi.reconnectFederationPeer' in SETTINGS, 'settings should reconnect peers')
require('daemonApi.removeFederationPeer' in SETTINGS, 'settings should remove peers')
require('Saved peer tokens stay on the daemon and are never shown again in the UI.' in SETTINGS, 'peer token redaction helper text missing')

require('remotePeersEnabled?: boolean;' in PICKER, 'AgentPicker should support remote peer mode')
require('daemonApi.listFederationPeers' in PICKER, 'AgentPicker should load peer list live')
require('daemonApi.listPeerAdvertisedAgents' in PICKER, 'AgentPicker should load live remote agent directory')
require('daemonApi.bindRemoteProxy' in PICKER, 'AgentPicker should bind remote proxy on selection')
require('remote-card-' in PICKER, 'remote row debug id missing')
require('REMOTE · LIVE' in PICKER and 'OFFLINE' in PICKER, 'remote row statuses missing')
require('!isRemoteProxyAgent(agent)' in PICKER, 'local proxy ids should be hidden from local picker rows')

require('remotePeersEnabled' in APP, 'task picker should enable remote peers')
require('clientToken={session.clientToken}' in APP or "clientToken={session?.clientToken || ''}" in APP, 'task picker should receive client token')
require('onRefreshAgents={() => dispatch(refreshAgents()).unwrap().catch(() => undefined)}' in APP, 'task picker should refresh agents after remote bind')
require('const dispatch = useDispatch<any>();' in CHAIN_VIEW_SECTION, 'ChainView should define a local dispatch for remote picker refresh wiring')

require('agentKind:' in CHAT and 'remote:' in CHAT, 'chat agent mapping should preserve remote proxy metadata')
require('settings-peer-daemon-list' in AGENTS_MD, 'AGENTS.md should register peer daemon debug ids')
require('${debugId}-remote-section-${peerId}' in AGENTS_MD, 'AGENTS.md should register AgentPicker remote debug ids')

print('remote_ui_static: ok')
