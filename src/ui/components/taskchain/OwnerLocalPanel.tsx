import { listOwnerRegistryPages } from '../../api/ownerRegistryListing';
import React, { useEffect, useState } from 'react';
import { cookieJsonFetch, cookieMutation } from '../../api/cookieFetch';
import { prepareOwnerOperation, ownerRelayFile, sendOwnerOperation, openOwnerReply, ownerId, type OwnerOperation, type OwnerSession } from '../../api/ownerLocalClient';
import { getKeyringSession, subscribeKeyringSession } from '../../utils/vaultKeyringSession';
import { decryptVaultText } from '../../utils/vaultContent';
import { pinsFromChain, verifyDirectory } from '../../utils/vaultDirectoryVerify';
import { describeMigrationBlockers, migrationBlockersFromError, prepareMigrationRequest, type MigrationPreflight, type MigrationRequest, type MigrationResult } from '../../api/ownerMigrationClient';

export default function OwnerLocalPanel({ onClose, initialChainId = "", initialBridgeId = "", initialTaskId = "", initialSubmissionAttempt }: { onClose: () => void; initialChainId?: string; initialBridgeId?: string; initialTaskId?: string; initialSubmissionAttempt?: string }) {
  const [bridge, setBridge] = useState(initialBridgeId);
  const [chainId, setChainId] = useState(initialChainId);
  const [taskId, setTaskId] = useState(initialTaskId);
  const [title, setTitle] = useState('');
  const [body, setBody] = useState('');
  const [instanceId, setInstanceId] = useState('');
  const [enabled, setEnabled] = useState(true);
  const [fleetPolicy, setFleetPolicy] = useState('{}');
  const [configRevision, setConfigRevision] = useState('1');
  const [lifecycleConfig, setLifecycleConfig] = useState('{}');
  const [requirementsRevision, setRequirementsRevision] = useState('1');
  const [attempt, setAttempt] = useState(initialSubmissionAttempt ?? '1');
  const [head, setHead] = useState('');
  const [verdict, setVerdict] = useState<'approve' | 'request_changes'>('approve');
  const [revision, setRevision] = useState('0');
  const [listing, setListing] = useState<any[]>([]);
  const [detail, setDetail] = useState<any>(null);
  const [error, setError] = useState('');
  const [pending, setPending] = useState<OwnerOperation | null>(null);
  const [busy, setBusy] = useState(false);
  const [migration, setMigration] = useState<{ preflight?: MigrationPreflight; refusals: string[]; result?: MigrationResult; request?: MigrationRequest }>({ refusals: [] });
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
    const rows = await listOwnerRegistryPages(cookieJsonFetch, () => getKeyringSession() === before);
    const visible = await Promise.all(rows.map(async (r: any) => {
      const registry = JSON.parse(r.registry_json);
      return { ...r, title: await decryptVaultText(registry.task_title_cipher || registry.chain_title_cipher, s.keyring) };
    }));
    if (getKeyringSession() === before) setListing(visible);
  }
  async function perform(method: 'migration.archive.read' | 'fleet.policy.set' | 'fleet.policy.read' | 'context.read' | 'workflow.coordinator' | 'workflow.cancel' | 'workflow.gate' | 'workflow.define' | 'workflow.run' | 'workflow.retry' | 'workflow.read' | 'source.observe' | 'source.consume' | 'source.ack' | 'source.retire' | 'source.resolve' | 'source.escalate' | 'source.read' | 'dependency.edit' | 'task.hold' | 'task.release' | 'task.cancel' | 'task.reopen' | 'task.resolve' | 'merge.retry' | 'submission.read' | 'chain.edit' | 'task.edit' | 'task.delete' | 'chain.search' | 'chain.create' | 'task.create' | 'task.comment' | 'chain.read' | 'task.read' | 'fleet.edit' | 'runtime.read' | 'lifecycle.configure' | 'requirements.edit' | 'review.post', target?: { taskId?: string; attempt?: string; offset?: string; contextCursor?: string; cursor?: string; archiveKind?: string; archiveTaskId?: string }) {
    const s = await current(); const before = getKeyringSession();
    const cid = method === 'chain.create' ? ownerId('chain_') : chainId;
    const tid = target?.taskId ?? (method === 'task.create' ? ownerId('task_') : (['dependency.edit', 'task.hold', 'task.release', 'task.cancel', 'task.reopen', 'task.resolve', 'merge.retry', 'submission.read', 'task.edit', 'task.delete', 'task.comment', 'task.read', 'fleet.edit', 'runtime.read', 'lifecycle.configure', 'requirements.edit', 'review.post'].includes(method) ? taskId : ''));
    const op = await prepareOwnerOperation(s, bridge, method, { chainId: cid, taskId: tid, expectedRevision: method === "chain.create" || (method.endsWith(".read") || method === "chain.search") ? "0" : revision, title, body: method === 'fleet.policy.set' ? fleetPolicy : body, query: body, description: body, enabled, instanceId, configurationRevision: configRevision, lifecycleConfig: method === 'lifecycle.configure' ? JSON.parse(lifecycleConfig) : undefined, requirementsRevision, attempt: target?.attempt ?? attempt, offset: target?.offset, cursor: target?.contextCursor ?? target?.cursor, head, verdict, archiveKind: target?.archiveKind, archiveTaskId: target?.archiveTaskId });
    setPending(op); setChainId(cid); if (tid) setTaskId(tid);
    const result = await sendOwnerOperation(s, op, (relay) => cookieMutation('/api/v1/owner-local/relay', 'POST', relay));
    if (getKeyringSession() !== before) return;
    const data = JSON.parse(result.body); setDetail(data); setRevision(data.revision ?? '0'); if (data.attempt) setAttempt(data.attempt); await list();
  }
  async function retry() {
    if (!pending) return;
    const s = await current(); const before = getKeyringSession();
    const result = await sendOwnerOperation(s, pending, (relay) => cookieMutation('/api/v1/owner-local/relay', 'POST', relay));
    if (getKeyringSession() === before) setDetail({ ...JSON.parse(result.body), replay: result.replay });
  }
  async function migrationPreflight(): Promise<MigrationPreflight> {
    const preflight = await cookieJsonFetch('/api/v1/owner-local/migrations/preflight?chain_id=' + encodeURIComponent(chainId)) as MigrationPreflight;
    setMigration({ preflight, refusals: describeMigrationBlockers(preflight.blockers) });
    return preflight;
  }
  // One-shot move of a legacy Hub chain: this device signs the selection and
  // genesis; the Hub freezes (neutralizing live work), the owner imports, the
  // Hub cuts over. The result lists the work that was neutralized.
  async function migrate() {
    const s = await current();
    const preflight = await migrationPreflight();
    if (preflight.state !== 'none' && preflight.owner_bridge_id !== bridge) throw new Error('This chain is already being moved to ' + preflight.owner_bridge_id);
    const request = migration.request && preflight.state !== 'none' ? migration.request : await prepareMigrationRequest(s, chainId, bridge, preflight.work_revision);
    setMigration({ preflight, refusals: [], request });
    try {
      const result = await cookieMutation('/api/v1/owner-local/migrations', 'POST', request) as MigrationResult;
      setMigration({ preflight, refusals: [], request, result });
      await list();
    } catch (e) {
      const blockers = migrationBlockersFromError(e);
      setMigration({ preflight, refusals: describeMigrationBlockers(blockers), request });
      if (blockers.length === 0) throw e;
    }
  }
  useEffect(() => {
    if (initialChainId && initialBridgeId) void run(() => perform(initialSubmissionAttempt !== undefined ? 'submission.read' : initialTaskId ? 'task.read' : 'chain.read'));
  }, [initialChainId, initialBridgeId, initialTaskId, initialSubmissionAttempt]);
  const inputClass = 'border border-subtle rounded p-2 bg-surface text-primary';
  return <div className="fixed inset-0 z-50 overflow-auto bg-surface p-6" role="dialog" aria-label="Owner-local tasks">
    <div className="flex justify-between"><h2>Owner-local tasks</h2><button data-debug-id="owner-local-close" onClick={onClose}>Close</button></div>
    <p>Tasks and comments live on the selected owner Bridge. Assign a running local instance, then use its CLI to claim and renew a lease. Configure independent review and merge, save requirements, then use the assigned child’s CLI to read, acknowledge and submit. Read runtime shows the current submission and gate.</p>
    <p>Task text and search documents are stored decrypted in the owner Bridge’s private directory. Use an encrypted disk. Vault lock blocks requests but does not erase those files.</p>
    <div className="flex flex-wrap gap-2 my-3">
      <select data-debug-id="owner-local-bridge" aria-label="Owner Bridge" className={inputClass} value={bridge} onChange={(e) => setBridge(e.target.value)}><option value="">Choose owner Bridge</option>{bridges.map((d) => <option key={d.device_id} value={d.row.bridge_id}>{d.row.bridge_id}</option>)}</select>
      <input data-debug-id="owner-local-chain" aria-label="Chain ID" placeholder="Chain ID" className={inputClass} value={chainId} onChange={(e) => setChainId(e.target.value)} />
      <input data-debug-id="owner-local-task" aria-label="Task ID" placeholder="Task ID" className={inputClass} value={taskId} onChange={(e) => setTaskId(e.target.value)} />
      <input data-debug-id="owner-local-revision" aria-label="Expected revision" className={inputClass} value={revision} onChange={(e) => setRevision(e.target.value)} />
      <input data-debug-id="owner-local-title" aria-label="Title" placeholder="Title" className={inputClass} value={title} onChange={(e) => setTitle(e.target.value)} />
      <input data-debug-id="owner-local-fleet-instance" aria-label="Fleet instance ID" placeholder="Running instance ID" className={inputClass} value={instanceId} onChange={(e) => setInstanceId(e.target.value)} />
      <label><input data-debug-id="owner-local-fleet-enabled" type="checkbox" checked={enabled} onChange={(e) => setEnabled(e.target.checked)} />Enable assignment</label>
      <input data-debug-id="owner-local-config-revision" aria-label="Configuration revision" className={inputClass} value={configRevision} onChange={(e) => setConfigRevision(e.target.value)} />
      <textarea data-debug-id="owner-local-lifecycle-config" aria-label="Lifecycle configuration JSON" placeholder="Device-signed lifecycle configuration" className={inputClass} value={lifecycleConfig} onChange={(e) => setLifecycleConfig(e.target.value)} />
      <input data-debug-id="owner-local-requirements-revision" aria-label="Requirements revision" className={inputClass} value={requirementsRevision} onChange={(e) => setRequirementsRevision(e.target.value)} />
      <input data-debug-id="owner-local-attempt" aria-label="Submitted attempt" className={inputClass} value={attempt} onChange={(e) => setAttempt(e.target.value)} />
      <input data-debug-id="owner-local-head" aria-label="Submitted commit" className={inputClass} value={head} onChange={(e) => setHead(e.target.value)} />
      <select data-debug-id="owner-local-verdict" aria-label="Human verdict" className={inputClass} value={verdict} onChange={(e) => setVerdict(e.target.value as 'approve' | 'request_changes')}><option value="approve">Approve</option><option value="request_changes">Request changes</option></select>
      <textarea data-debug-id="owner-local-body" aria-label="Body or comment" placeholder="Description, task body, or comment" className={inputClass} value={body} onChange={(e) => setBody(e.target.value)} />
    </div>
    <fieldset className="border border-subtle p-3 my-3">
      <legend>Durable fleet policy</legend>
      <p>Save a durable agent’s roles, capacity and placement preferences. Existing running assignments continue. Automatic dispatch is not enabled by saving this policy.</p>
      <textarea data-debug-id="owner-local-fleet-policy" aria-label="Durable fleet policy JSON" className={inputClass} value={fleetPolicy} onChange={(e) => setFleetPolicy(e.target.value)} />
      <button data-debug-id="owner-local-fleet-policy-read" disabled={busy || !bridge || !chainId} onClick={() => void run(() => perform('fleet.policy.read'))}>Read fleet policy</button>
      <button data-debug-id="owner-local-fleet-policy-save" disabled={busy || !bridge || !chainId} onClick={() => void run(() => perform('fleet.policy.set'))}>Save fleet policy</button>
      {detail?.items?.some((item: any) => item.policy) && detail.next_cursor && <button data-debug-id="owner-local-fleet-policy-next" disabled={busy} onClick={() => void run(() => perform('fleet.policy.read', {cursor: detail.next_cursor}))}>Next fleet policy page</button>}
    </fieldset>
    <fieldset className="border border-subtle p-3 my-3">
      <legend>Move a legacy chain to its owner Bridge</legend>
      <p>One-shot and irreversible: the Hub freezes the chain, the selected Bridge imports it in one transaction, and only after the Hub retires its own writer does the Bridge accept work. Live work is neutralized first: in-progress tasks are held, live leases are ended, and running workflows and pending merges are cancelled. A failed import leaves the chain frozen; retry the same move.</p>
      <button data-debug-id="owner-local-migration-check" disabled={busy || !chainId} onClick={() => void run(async () => { await migrationPreflight(); })}>Check migration</button>
      <button data-debug-id="owner-local-migration-move" disabled={busy || !bridge || !chainId} onClick={() => void run(migrate)}>Move to Bridge</button>
      <button data-debug-id="owner-local-migration-export" disabled={busy || !migration.request} onClick={() => {
        if (!migration.request) return;
        const url = URL.createObjectURL(new Blob([JSON.stringify(migration.request)], { type: 'application/json' }));
        const a = document.createElement('a'); a.href = url; a.download = 'owner-migration-request.json'; a.click(); URL.revokeObjectURL(url);
      }}>Export signed migration request for CLI</button>
      <button data-debug-id="owner-local-migration-abort" disabled={busy || !chainId || !migration.preflight?.migration_id || migration.preflight.state === 'imported'} onClick={() => void run(async () => {
        const preflight = migration.preflight;
        if (!preflight?.migration_id) return;
        await cookieMutation('/api/v1/owner-local/migrations/abort', 'POST', { chain_id: chainId, migration_id: preflight.migration_id });
        setMigration({ refusals: [] });
        await migrationPreflight();
      })}>Abort unfinished migration</button>
      <button data-debug-id="owner-local-migration-reviews" disabled={busy || !bridge || !chainId} onClick={() => void run(() => perform('migration.archive.read', { archiveKind: 'review', archiveTaskId: taskId }))}>Read archived reviews</button>
      {detail?.migration_id && Array.isArray(detail.items) && <ul data-debug-id="owner-local-migration-archive">{detail.items.map((item: any) => { const r = JSON.parse(item.record); return <li key={item.doc_index + ':' + item.row}>{item.kind === 'review' ? `${r.task_id} attempt ${r.attempt_no}: ${r.verdict} by ${r.reviewer_kind}${r.reviewer_agent_id ? ' ' + r.reviewer_agent_id : ''}${r.role ? ' (' + r.role + ')' : ''} — findings ${r.findings_json}` : item.record}</li>; })}</ul>}
      {detail?.migration_id && detail.next_cursor && <button data-debug-id="owner-local-migration-archive-next" disabled={busy} onClick={() => void run(() => perform('migration.archive.read', { archiveKind: 'review', archiveTaskId: taskId, cursor: detail.next_cursor }))}>Next archived reviews</button>}
      {migration.preflight && <p>State: {migration.preflight.state}{migration.preflight.migration_id ? ' (' + migration.preflight.migration_id + ' to ' + migration.preflight.owner_bridge_id + ')' : ''}; work revision {migration.preflight.work_revision}</p>}
      {migration.refusals.length > 0 && <div role="status"><p>Live work on this chain (the move neutralizes it):</p><ul>{migration.refusals.map((r) => <li key={r}>{r}</li>)}</ul></div>}
      {migration.result && <p>Migration {migration.result.state}{migration.result.replayed ? ' (replayed)' : ''}; manifest {migration.result.manifest_digest.slice(0, 12)}…; {migration.result.activation_sent ? 'owner Bridge notified' : 'owner Bridge activates on reconnect'}</p>}
      {migration.result && describeMigrationBlockers(migration.result.neutralized).length > 0 && <div data-debug-id="owner-local-migration-neutralized"><p>Neutralized by the move:</p><ul>{describeMigrationBlockers(migration.result.neutralized).map((r) => <li key={r}>{r}</li>)}</ul></div>}
      {migration.result && (migration.result.forced_held?.length ?? 0) > 0 && <p data-debug-id="owner-local-migration-forced-held">{migration.result.forced_held!.length} tasks force-held: {migration.result.forced_held!.join(', ')}</p>}
    </fieldset>
    <div className="flex flex-wrap gap-3">
      {(['context.read', 'workflow.coordinator', 'workflow.cancel', 'workflow.gate', 'workflow.define', 'workflow.run', 'workflow.retry', 'workflow.read', 'source.observe', 'source.consume', 'source.ack', 'source.retire', 'source.resolve', 'source.escalate', 'source.read', 'dependency.edit', 'task.hold', 'task.release', 'task.cancel', 'task.reopen', 'task.resolve', 'merge.retry', 'submission.read', 'chain.edit', 'task.edit', 'task.delete', 'chain.search', 'chain.create', 'task.create', 'task.comment', 'chain.read', 'task.read', 'fleet.edit', 'runtime.read', 'lifecycle.configure', 'requirements.edit', 'review.post'] as const).map((method) => <button key={method} data-debug-id={'owner-local-' + method.replace('.', '-')} disabled={busy || !bridge} onClick={() => void run(() => perform(method))}>{{ 'context.read': 'Read full context evidence', 'workflow.coordinator': 'Bind workflow coordinator', 'workflow.cancel': 'Cancel workflow execution', 'workflow.gate': 'Record workflow gate verdict', 'workflow.define': 'Save workflow definition', 'workflow.run': 'Start workflow', 'workflow.retry': 'Retry workflow', 'workflow.read': 'Read workflows', 'source.observe': 'Record source fact', 'source.consume': 'Record source result', 'source.ack': 'Acknowledge source', 'source.retire': 'Retire source', 'source.resolve': 'Close resolved source card', 'source.escalate': 'Escalate source', 'source.read': 'Read pending sources', 'dependency.edit': 'Edit dependency', 'task.hold': 'Hold task', 'task.release': 'Release hold', 'task.cancel': 'Cancel task', 'task.reopen': 'Reopen task', 'task.resolve': 'Resolve human block', 'merge.retry': 'Retry unchanged merge', 'submission.read': 'Read submission attempt', 'chain.edit': 'Edit chain', 'task.edit': 'Edit task', 'task.delete': 'Delete unstarted task', 'chain.search': 'Search chain', 'chain.create': 'Create chain', 'task.create': 'Create task', 'task.comment': 'Add comment', 'chain.read': 'Read chain', 'task.read': 'Read task', 'fleet.edit': 'Assign local instance', 'runtime.read': 'Read runtime', 'lifecycle.configure': 'Configure review and merge', 'requirements.edit': 'Save requirements', 'review.post': 'Record human verdict' }[method]}</button>)}
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
    {detail?.kind === 'workflow' && detail.next_cursor && <button data-debug-id="owner-local-workflow-next" disabled={busy} onClick={() => void run(() => perform('workflow.read', { cursor: detail.next_cursor }))}>Next workflow records</button>}
    {detail?.kind === 'sources' && detail.next_cursor && <button data-debug-id="owner-local-source-next" disabled={busy} onClick={() => void run(() => perform('source.read', { cursor: detail.next_cursor }))}>Next pending sources</button>}
    {detail?.kind === 'submission' && <h3>Submission attempt {detail.attempt} (historical output)</h3>}
    {detail?.kind === 'submission' && detail.next_offset && <button data-debug-id="owner-local-submission-next" onClick={() => void run(() => perform('submission.read', { taskId: detail.task_id, attempt: detail.attempt, offset: detail.next_offset }))}>Next summary page</button>}
    {detail?.hits?.filter((hit: any) => hit.kind === 'output').map((hit: any) => <button key={hit.object_id} data-debug-id={'owner-local-output-' + hit.object_id} onClick={() => void run(() => perform('submission.read', { taskId: hit.task_id, attempt: hit.attempt }))}>Read submission attempt {hit.attempt}</button>)}
    {detail?.context?.body && <pre data-debug-id="owner-local-chain-context" className="whitespace-pre-wrap">{detail.context.body}</pre>}
    {detail?.kind === 'context_source' && detail.next_cursor && <button data-debug-id="owner-local-context-next" disabled={busy} onClick={() => void run(() => perform('context.read', {contextCursor: detail.next_cursor}))}>Next evidence page</button>}
    {detail && <pre className="whitespace-pre-wrap">{JSON.stringify(detail, null, 2)}</pre>}
  </div>;
}
