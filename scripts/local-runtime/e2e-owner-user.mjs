// Plays the user for an agent-driven local E2E: one pass over an owner chain
// that approves every task in review whose brief asks for the USER's approval
// (requires_user_approval, e.g. the coordinator's planning task), exactly as the
// UI's Approve does (ownerTaskVerdict: runtime.read, task.read, signed
// review.post through the owner relay), as the hub's dev user with the seed
// approver's device and keyring. Tasks reviewed by agents are left alone.
// Local throwaway hubs only (scripts/local-hub.sh).
//
//   node --import ./tests/helpers/vaultEndpointHarness.ts scripts/local-runtime/e2e-owner-user.mjs \
//     --api <hub-url> --key <approver/device.json> --bridge <owner brg_…> --chain <chain_…> \
//     [--user <dev-user>] [--body <approval text>] [--proposal <proposal id>]
//
// Prints one JSON line per approved task: {task_id, attempt}. With --proposal it
// also approves that pending chain proposal (signed chain.decide, the user's
// device decision): a harness fallback when a coordinator's plan waits on a
// UI click; the harness records each use (S1 expects none).
import { hubLogin, sessionHeaders } from '../../tests/e2e/hubOidc.mjs';
import { openSeedApprover } from './approver.mjs';
import { importKeyring } from '../../src/ui/utils/vaultKeyring.ts';
import { ownerCall, readOwnerChain, readOwnerRuntime, readOwnerTask } from '../../src/ui/api/ownerChains.ts';

function args(argv) {
  const out = { user: '', body: 'Approved, go ahead.', proposal: '' };
  for (let i = 0; i < argv.length; i += 2) {
    const k = argv[i].replace(/^--/, '');
    if (!['api', 'key', 'bridge', 'chain', 'user', 'body', 'proposal'].includes(k) || argv[i + 1] === undefined) throw new Error(`bad argument ${argv[i]}`);
    out[k] = argv[i + 1];
  }
  for (const k of ['api', 'key', 'bridge', 'chain']) if (!out[k]) throw new Error(`--${k} is required`);
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
const session = { identity: seed.identity, chain: await seed.chain(), keyring };
const cookie = await hubLogin(a.api, a.user);
// ownerRelaySend, with the dev user's session cookie instead of the browser's.
const send = async (relay) => {
  const res = await fetch(`${a.api}/api/v1/owner-local/relay`, {
    method: 'POST',
    headers: { ...sessionHeaders(cookie, process.env.HEIMDALL_LOCAL_UI_ORIGIN || a.api), 'Content-Type': 'application/json' },
    body: JSON.stringify(relay),
  });
  const raw = await res.text();
  if (!res.ok) throw new Error(`owner relay ${res.status}: ${raw.slice(0, 300)}`);
  const json = raw ? JSON.parse(raw) : {};
  return json.data !== undefined ? json.data : json;
};

const chain = await readOwnerChain(session, a.bridge, a.chain, send);
for (const t of chain.tasks) {
  const rt = await readOwnerRuntime(session, a.bridge, a.chain, t.task_id, send);
  if (rt.lifecycle !== 'in_review' || !rt.requirements?.requiresUserApproval || !rt.submission) continue;
  const task = await readOwnerTask(session, a.bridge, a.chain, t.task_id, send);
  const sub = rt.submission;
  await ownerCall(session, a.bridge, 'review.post', {
    chainId: a.chain, taskId: t.task_id, expectedRevision: task.revision, verdict: 'approve', body: a.body,
    attempt: sub.attempt, head: sub.head, requirementsRevision: sub.requirementsRevision,
  }, send);
  console.log(JSON.stringify({ task_id: t.task_id, title: t.title, attempt: sub.attempt }));
}
if (a.proposal) {
  await ownerCall(session, a.bridge, 'chain.decide', {
    chainId: a.chain, expectedRevision: chain.revision,
    body: JSON.stringify({ proposal_id: a.proposal, decision: 'approve', note: 'Approved by the scripted user (harness fallback for a pending proposal).' }),
  }, send);
  console.log(JSON.stringify({ proposal_id: a.proposal, decision: 'approve' }));
}
