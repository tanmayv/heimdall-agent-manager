// Enables a provider on a local Bridge the way Settings > Bridges does
// (POST providers/discover, PUT providers/<provider> {enabled:true}), then waits
// until GET provider-status reports it present and enabled. Local throwaway
// hubs only (scripts/local-hub.sh); scripts/e2e-req-e2e-1.sh runs it per Bridge.
//
//   node scripts/local-runtime/e2e-enable-provider.mjs --api <hub-url> --bridge <brg_…> \
//     [--user <dev-user>] [--provider claude] [--timeout-ms 120000]
//
// Prints the provider's provider-status entry as one JSON line.
import { hubLogin, sessionHeaders } from '../../tests/e2e/hubOidc.mjs';

function args(argv) {
  const out = { user: '', provider: 'claude', 'timeout-ms': '120000' };
  for (let i = 0; i < argv.length; i += 2) {
    const k = argv[i].replace(/^--/, '');
    if (!['api', 'bridge', 'user', 'provider', 'timeout-ms'].includes(k) || argv[i + 1] === undefined) throw new Error(`bad argument ${argv[i]}`);
    out[k] = argv[i + 1];
  }
  for (const k of ['api', 'bridge']) if (!out[k]) throw new Error(`--${k} is required`);
  return out;
}

const a = args(process.argv.slice(2));
const session = await hubLogin(a.api, a.user);
const headers = { ...sessionHeaders(session, process.env.HEIMDALL_LOCAL_UI_ORIGIN || a.api), 'Content-Type': 'application/json' };
const bridge = `${a.api}/api/v1/bridges/${encodeURIComponent(a.bridge)}`;
async function call(method, path, body) {
  const res = await fetch(bridge + path, { method, headers, body: body ? JSON.stringify(body) : undefined });
  const raw = await res.text();
  if (!res.ok) throw new Error(`${method} ${path} -> ${res.status}: ${raw.slice(0, 300)}`);
  const json = raw ? JSON.parse(raw) : {};
  return json.data ?? json;
}

await call('POST', '/providers/discover', { stage: 'providers', providers: [a.provider] });
await call('PUT', `/providers/${a.provider}`, { enabled: true, profile_id: a.provider });
const deadline = Date.now() + Number(a['timeout-ms']);
let entry = null;
while (Date.now() < deadline) {
  const status = await call('GET', '/provider-status');
  entry = (status.providers || []).find((p) => p.provider === a.provider && (p.profile_id || p.provider) === a.provider) || null;
  if (entry?.state === 'present' && entry.enabled) break;
  await new Promise((r) => setTimeout(r, 2000));
}
if (!(entry?.state === 'present' && entry.enabled)) {
  console.error(`provider ${a.provider} on ${a.bridge} not present+enabled: ${JSON.stringify(entry)}`);
  process.exit(1);
}
console.log(JSON.stringify(entry));
