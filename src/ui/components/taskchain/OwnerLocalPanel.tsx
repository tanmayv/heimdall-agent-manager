import React, { useEffect, useState } from 'react';
import { cookieJsonFetch, cookieMutation } from '../../api/cookieFetch';
import { prepareOwnerOperation, ownerRelayFile, sendOwnerOperation, openOwnerReply, ownerId, type OwnerOperation, type OwnerSession } from '../../api/ownerLocalClient';
import { getKeyringSession, subscribeKeyringSession } from '../../utils/vaultKeyringSession';
import { decryptVaultText } from '../../utils/vaultContent';
import { pinsFromChain, verifyDirectory } from '../../utils/vaultDirectoryVerify';

export default function OwnerLocalPanel({ onClose }: { onClose: () => void }) {
  const [bridge, setBridge] = useState('');
  const [chainId, setChainId] = useState('');
  const [taskId, setTaskId] = useState('');
  const [title, setTitle] = useState('');
  const [body, setBody] = useState('');
  const [instanceId, setInstanceId] = useState('');
  const [configRevision, setConfigRevision] = useState('1');
  const [revision, setRevision] = useState('0');
  const [listing, setListing] = useState<any[]>([]);
  const [detail, setDetail] = useState<any>(null);
  const [error, setError] = useState('');
  const [pending, setPending] = useState<OwnerOperation | null>(null);
  const [busy, setBusy] = useState(false);
  useEffect(() => subscribeKeyringSession(() => { setDetail(null); setPending(null); setListing([]); setError('Vault session changed; reopen this screen'); onClose(); }), [onClose]);
  const session = getKeyringSession();
  const bridges = session ? [...session.chain.trusted.values()].filter((d) => d.kind === 'bridge' && d.row.bridge_id) : [];
  async function current(): Promise<OwnerSession> {
    const s = getKeyringSession();
    if (!s) throw new Error('Unlock the vault first');
    const chain = await verifyDirectory(await cookieJsonFetch('/api/v1/vault/directory'), s.identity.userId, pinsFromChain(s.chain));
    if (getKeyringSession() !== s || chain.currentEpoch !== s.keyring.currentEpoch) throw new Error('Vault session changed; refresh it first');
    return { ...s, chain };
  }
  async function run(action: () => Promise<void>) {
    setBusy(true); setError(''); setDetail(null);
    try { await action(); } catch (e) { setError(e instanceof Error ? e.message : String(e)); }
    finally { setBusy(false); }
  }
  async function list() {
    const s = await current(); const before = getKeyringSession();
    const rows = await cookieJsonFetch('/api/v1/owner-local/chains');
    const visible = await Promise.all(rows.map(async (r: any) => {
      const registry = JSON.parse(r.registry_json);
      return { ...r, title: await decryptVaultText(registry.task_title_cipher || registry.chain_title_cipher, s.keyring) };
    }));
    if (getKeyringSession() === before) setListing(visible);
  }
  async function perform(method: 'chain.create' | 'task.create' | 'task.comment' | 'chain.read' | 'task.read' | 'fleet.edit' | 'runtime.read') {
    const s = await current(); const before = getKeyringSession();
    const cid = method === 'chain.create' ? ownerId('chain_') : chainId;
    const tid = method === 'task.create' ? ownerId('task_') : (['task.comment', 'task.read', 'fleet.edit', 'runtime.read'].includes(method) ? taskId : '');
    const op = await prepareOwnerOperation(s, bridge, method, { chainId: cid, taskId: tid, expectedRevision: method === "chain.create" || method.endsWith(".read") ? "0" : revision, title, body, description: body, instanceId, configurationRevision: configRevision });
    setPending(op); setChainId(cid); if (tid) setTaskId(tid);
    const result = await sendOwnerOperation(s, op, (relay) => cookieMutation('/api/v1/owner-local/relay', 'POST', relay));
    if (getKeyringSession() !== before) return;
    const data = JSON.parse(result.body); setDetail(data); setRevision(data.revision ?? '0'); await list();
  }
  async function retry() {
    if (!pending) return;
    const s = await current(); const before = getKeyringSession();
    const result = await sendOwnerOperation(s, pending, (relay) => cookieMutation('/api/v1/owner-local/relay', 'POST', relay));
    if (getKeyringSession() === before) setDetail({ ...JSON.parse(result.body), replay: result.replay });
  }
  const inputClass = 'border border-subtle rounded p-2 bg-surface text-primary';
  return <div className="fixed inset-0 z-50 overflow-auto bg-surface p-6" role="dialog" aria-label="Owner-local tasks">
    <div className="flex justify-between"><h2>Owner-local tasks</h2><button data-debug-id="owner-local-close" onClick={onClose}>Close</button></div>
    <p>Tasks and comments live on the selected owner Bridge. Assign a running local instance, then use its CLI to claim and renew a lease. Read runtime shows the current lease.</p>
    <div className="flex flex-wrap gap-2 my-3">
      <select data-debug-id="owner-local-bridge" aria-label="Owner Bridge" className={inputClass} value={bridge} onChange={(e) => setBridge(e.target.value)}><option value="">Choose owner Bridge</option>{bridges.map((d) => <option key={d.device_id} value={d.row.bridge_id}>{d.row.bridge_id}</option>)}</select>
      <input data-debug-id="owner-local-chain" aria-label="Chain ID" placeholder="Chain ID" className={inputClass} value={chainId} onChange={(e) => setChainId(e.target.value)} />
      <input data-debug-id="owner-local-task" aria-label="Task ID" placeholder="Task ID" className={inputClass} value={taskId} onChange={(e) => setTaskId(e.target.value)} />
      <input data-debug-id="owner-local-revision" aria-label="Expected revision" className={inputClass} value={revision} onChange={(e) => setRevision(e.target.value)} />
      <input data-debug-id="owner-local-title" aria-label="Title" placeholder="Title" className={inputClass} value={title} onChange={(e) => setTitle(e.target.value)} />
      <input data-debug-id="owner-local-fleet-instance" aria-label="Fleet instance ID" placeholder="Running instance ID" className={inputClass} value={instanceId} onChange={(e) => setInstanceId(e.target.value)} />
      <input data-debug-id="owner-local-config-revision" aria-label="Configuration revision" className={inputClass} value={configRevision} onChange={(e) => setConfigRevision(e.target.value)} />
      <textarea data-debug-id="owner-local-body" aria-label="Body or comment" placeholder="Description, task body, or comment" className={inputClass} value={body} onChange={(e) => setBody(e.target.value)} />
    </div>
    <div className="flex flex-wrap gap-3">
      {(['chain.create', 'task.create', 'task.comment', 'chain.read', 'task.read', 'fleet.edit', 'runtime.read'] as const).map((method) => <button key={method} data-debug-id={'owner-local-' + method.replace('.', '-')} disabled={busy || !bridge} onClick={() => void run(() => perform(method))}>{{ 'chain.create': 'Create chain', 'task.create': 'Create task', 'task.comment': 'Add comment', 'chain.read': 'Read chain', 'task.read': 'Read task', 'fleet.edit': 'Assign local instance', 'runtime.read': 'Read runtime' }[method]}</button>)}
      <button data-debug-id="owner-local-list" disabled={busy} onClick={() => void run(list)}>Refresh listing</button>
      <button data-debug-id="owner-local-retry" disabled={busy || !pending} onClick={() => void run(retry)}>Retry same operation</button>
      <button data-debug-id="owner-local-export" disabled={busy || !pending} onClick={() => void run(async () => {
        if (!pending) return;
        const relay = await ownerRelayFile(await current(), pending);
        const url = URL.createObjectURL(new Blob([JSON.stringify(relay)], { type: 'application/json' }));
        const a = document.createElement('a'); a.href = url; a.download = 'owner-local-request.json'; a.click(); URL.revokeObjectURL(url);
      })}>Export signed request for CLI</button>
      <label>Open CLI response <input data-debug-id="owner-local-import-reply" type="file" accept="application/json" onChange={(e) => void run(async () => {
        const file = e.target.files?.[0]; if (!file || !pending) return;
        const s = await current(); const before = getKeyringSession(); const raw = JSON.parse(await file.text());
        const result = await openOwnerReply(s, pending, raw.data ?? raw);
        if (getKeyringSession() === before) setDetail(JSON.parse(result.body));
      })} /></label>
    </div>
    {error && <p role="alert">{error}</p>}
    <ul>{listing.map((r) => <li key={r.chain_id + r.task_id}><button data-debug-id={'owner-local-select-' + r.chain_id + r.task_id} onClick={() => {setChainId(r.chain_id);setTaskId(r.task_id);setBridge(r.owner_bridge_id);setRevision('0');setDetail(null);}}>{r.title} — {r.online ? 'owner online' : 'owner offline; details unavailable'}</button></li>)}</ul>
    {detail && <pre className="whitespace-pre-wrap">{JSON.stringify(detail, null, 2)}</pre>}
  </div>;
}
