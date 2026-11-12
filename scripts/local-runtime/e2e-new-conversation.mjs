// Starts a New-conversation coordinator on a local hub exactly as the UI's
// createLaunchConversation does (POST /api/v1/chats with create_owner_chain and
// a vault-sealed initial message), as the hub's dev user with the seed
// approver's keyring. Local throwaway hubs only (scripts/local-hub.sh).
//
//   node --import ./tests/helpers/vaultEndpointHarness.ts scripts/local-runtime/e2e-new-conversation.mjs \
//     --api <hub-url> --key <approver/device.json> --agent <agt_…> --bridge <brg_…> \
//     --prompt <text> [--user <dev-user>] [--provider claude --model <m>]
//
// Prints one JSON line: {conversation_id, agent_instance_id, chain_id}.
//
// With --conversation <chat_…> (and no --agent/--bridge) it instead sends
// --prompt as the user's next message in that conversation, as the chat
// composer does (POST /api/v1/chats/<id>/messages), and prints {message_id}.
import { hubLogin, sessionHeaders } from '../../tests/e2e/hubOidc.mjs';
import { openSeedApprover } from './approver.mjs';
import { importKeyring } from '../../src/ui/utils/vaultKeyring.ts';
import { encryptVaultText } from '../../src/ui/utils/vaultCrypto.ts';

function args(argv) {
  const out = { user: '', provider: '', model: '', conversation: '' };
  for (let i = 0; i < argv.length; i += 2) {
    const k = argv[i].replace(/^--/, '');
    if (!['api', 'key', 'agent', 'bridge', 'prompt', 'user', 'provider', 'model', 'conversation'].includes(k) || argv[i + 1] === undefined) throw new Error(`bad argument ${argv[i]}`);
    out[k] = argv[i + 1];
  }
  for (const k of out.conversation ? ['api', 'key', 'prompt'] : ['api', 'key', 'agent', 'bridge', 'prompt']) if (!out[k]) throw new Error(`--${k} is required`);
  return out;
}

const a = args(process.argv.slice(2));
const seed = await openSeedApprover({ api: a.api, key: a.key, user: a.user });
let keyring;
try {
  keyring = await importKeyring(seed.keyringBytes, seed.userId);
} finally {
  seed.keyringBytes.fill(0);
}
const sealed = await encryptVaultText(a.prompt, keyring);
const session = await hubLogin(a.api, a.user);
const headers = { ...sessionHeaders(session, process.env.HEIMDALL_LOCAL_UI_ORIGIN || a.api), 'Content-Type': 'application/json' };
async function post(path, body) {
  const res = await fetch(`${a.api}/api/v1${path}`, { method: 'POST', headers, body: JSON.stringify(body) });
  const raw = await res.text();
  let data = null;
  try { data = JSON.parse(raw)?.data ?? null; } catch { /* not JSON */ }
  if (res.status >= 300 || !data) {
    console.error(`POST /api/v1${path} refused: ${res.status} ${raw.slice(0, 500)}`);
    process.exit(1);
  }
  return data;
}

if (a.conversation) {
  const data = await post(`/chats/${encodeURIComponent(a.conversation)}/messages`, { body: sealed, artifact_ids: [] });
  console.log(JSON.stringify({ message_id: data.message_id ?? data.id ?? '' }));
} else {
  const body = { agent_id: a.agent, bridge_id: a.bridge, create_owner_chain: true, artifact_ids: [], initial_message: { body: sealed } };
  if (a.provider) body.provider = a.provider;
  if (a.model) body.model = a.model;
  const data = await post('/chats', body);
  if (!data.agent_instance_id) { console.error(`POST /api/v1/chats returned no agent_instance_id: ${JSON.stringify(data)}`); process.exit(1); }
  console.log(JSON.stringify({ conversation_id: data.conversation_id ?? '', agent_instance_id: data.agent_instance_id, chain_id: data.chain_id ?? '' }));
}
