import { useEffect, useState } from 'react';
import {
  normalizeBridgeCapabilities,
  useListBridgesQuery,
  useListBridgeEnrollmentsQuery,
  useRenameBridgeMutation,
  useRevokeBridgeMutation,
  useCreateBridgeEnrollmentMutation,
  useRevokeBridgeEnrollmentMutation,
} from '../../api/endpoints/bridgeSupport';

// UI-11: Settings → Bridges. The user's machines (arch doc §6A).
// List shows status dot, label, hostname/OS/arch, capabilities, instance count.
// Add bridge = enrollment ceremony (one-time token shown once). Detail allows
// rename (PATCH), revoke (= "remove", POST /revoke). No hard delete in v1.
// Rotate-token is a documented backend gap (not yet served).
export default function BridgesPanel() {
  const [enrollOpen, setEnrollOpen] = useState(false);
  const [hasPendingEnrollments, setHasPendingEnrollments] = useState(false);
  const pollActive = enrollOpen || hasPendingEnrollments;
  const bridgesQuery = useListBridgesQuery(undefined, { pollingInterval: pollActive ? 3000 : 0 });
  const enrollmentsQuery = useListBridgeEnrollmentsQuery(undefined, { pollingInterval: pollActive ? 3000 : 0 });
  const [renameBridge] = useRenameBridgeMutation();
  const [revokeBridge] = useRevokeBridgeMutation();
  const [createEnrollment] = useCreateBridgeEnrollmentMutation();
  const [revokeEnrollment] = useRevokeBridgeEnrollmentMutation();

  const [enrollLabel, setEnrollLabel] = useState('');
  const [enrollBusy, setEnrollBusy] = useState(false);
  const [enrollResult, setEnrollResult] = useState<any>(null);
  const [enrollError, setEnrollError] = useState('');
  const [renamingId, setRenamingId] = useState('');
  const [renameValue, setRenameValue] = useState('');
  const [revokeConfirmId, setRevokeConfirmId] = useState('');
  const [actionError, setActionError] = useState('');
  const [copiedToken, setCopiedToken] = useState(false);

  const bridges = bridgesQuery.data?.bridges || [];
  const enrollments = enrollmentsQuery.data?.enrollments || [];
  const pendingEnrollments = enrollments.filter(isPendingEnrollment);

  useEffect(() => {
    setHasPendingEnrollments(pendingEnrollments.length > 0);
  }, [pendingEnrollments.length]);

  function isPendingEnrollment(enrollment: any): boolean {
    const status = String(enrollment?.status || enrollment?.state || '').toLowerCase();
    if (status) return status === 'pending' || status === 'created' || status === 'active';
    if (enrollment?.consumed_at || enrollment?.consumed_by_bridge_id || enrollment?.revoked_at) return false;
    return true;
  }

  function statusTone(bridge: any): string {
    const status = String(bridge?.status || bridge?.runtime_status || '').toLowerCase();
    if (status === 'revoked') return 'bg-rose-400';
    if (status === 'online' || status === 'connected') return 'bg-emerald-400';
    return 'bg-zinc-600';
  }

  function statusLabel(bridge: any): string {
    const status = String(bridge?.status || bridge?.runtime_status || '').toLowerCase();
    return status || 'offline';
  }

  function capabilitiesLabel(bridge: any): string {
    const providers = normalizeBridgeCapabilities(bridge);
    return providers.length ? providers.map((cap) => `${cap.provider}${cap.tiers.length ? ` (${cap.tiers.join('/')})` : ''}`).join(', ') : '—';
  }

  function bridgeReady(bridge: any): boolean {
    return statusLabel(bridge) === 'online' && normalizeBridgeCapabilities(bridge).length > 0;
  }

  function buildSetupCommand(result: any): string {
    const responseCommand = String(result?.setup_command || '');
    const url = result?.hub_url || result?.daemon_url || (typeof window !== 'undefined' ? window.location.origin : '');
    if (responseCommand && !responseCommand.includes('$HAM_HUB_URL') && responseCommand.includes(String(result?.enrollment_token || ''))) return responseCommand;
    if (responseCommand && !responseCommand.includes('$HAM_HUB_URL')) return `${responseCommand} \\\n  --enrollment-token ${result?.enrollment_token || ''}`;
    const token = result?.enrollment_token || '';
    return `ham-bridge enroll --hub ${url} \\\n  --enrollment-token ${token}`;
  }

  async function handleCreateEnrollment() {
    setEnrollBusy(true);
    setEnrollError('');
    try {
      const result = await createEnrollment({ label: enrollLabel.trim() || undefined, expiresInSeconds: 900 }).unwrap();
      setEnrollResult(result?.enrollment || result);
      setHasPendingEnrollments(true);
      void enrollmentsQuery.refetch();
      void bridgesQuery.refetch();
    } catch (err: any) {
      setEnrollError(String(err?.message || err || 'Unable to create enrollment'));
    } finally {
      setEnrollBusy(false);
    }
  }

  async function handleSaveRename(bridgeId: string) {
    const label = renameValue.trim();
    if (!label) return;
    try {
      await renameBridge({ bridgeId, label }).unwrap();
      setRenamingId('');
    } catch (err: any) {
      setActionError(String(err?.message || 'Rename failed'));
    }
  }

  async function handleRevoke(bridgeId: string) {
    try {
      await revokeBridge({ bridgeId }).unwrap();
      setRevokeConfirmId('');
    } catch (err: any) {
      setActionError(String(err?.message || 'Revoke failed'));
    }
  }

  async function handleRevokeEnrollment(enrollmentId: string) {
    try {
      await revokeEnrollment({ enrollmentId }).unwrap();
    } catch (err: any) {
      setActionError(String(err?.message || 'Revoke enrollment failed'));
    }
  }

  async function copyToken(token: string) {
    try {
      await navigator.clipboard.writeText(token);
      setCopiedToken(true);
      window.setTimeout(() => setCopiedToken(false), 1200);
    } catch {
      setActionError('Copy failed — select and copy manually.');
    }
  }

  return (
    <section data-debug-id="settings-bridges-panel" className="rounded-2xl border border-white/10 bg-white/[0.035] p-4">
      <div className="flex items-center justify-between gap-2">
        <div>
          <h3 className="font-semibold">Bridges</h3>
          <p className="mt-0.5 text-xs text-zinc-500">Your machines. “Remove” revokes the token (record kept); no hard delete in v1.</p>
        </div>
        <button type="button" data-debug-id="settings-bridges-add-btn" onClick={() => { setEnrollOpen((o) => !o); setEnrollResult(null); setEnrollError(''); }} className="rounded-xl border border-sky-400/30 bg-sky-400/10 px-3 py-1.5 text-sm text-sky-100 hover:bg-sky-400/20">＋ Add bridge</button>
      </div>

      {bridgesQuery.isError || enrollmentsQuery.isError ? <div data-debug-id="settings-bridges-load-error" className="mt-3 rounded-xl border border-red-400/30 bg-red-500/10 px-3 py-2 text-sm text-red-100">Unable to load bridges. Check your trusted-proxy session and Hub connection.</div> : null}
      {actionError ? <div data-debug-id="settings-bridges-error" className="mt-3 rounded-xl border border-red-400/30 bg-red-500/10 px-3 py-2 text-sm text-red-100">{actionError}</div> : null}

      {/* Enrollment ceremony */}
      {enrollOpen ? (
        <div data-debug-id="settings-bridges-enroll-panel" className="mt-3 rounded-2xl border border-sky-400/25 bg-sky-400/[0.05] p-4">
          {!enrollResult ? (
            <>
              <div className="text-sm font-medium text-sky-100">Create bridge enrollment</div>
              <label className="mt-2 block text-xs uppercase tracking-wide text-zinc-500">Label (optional; defaults to reported hostname)
                <input data-debug-id="settings-bridges-enroll-label" value={enrollLabel} onChange={(e) => setEnrollLabel(e.target.value)} placeholder="MacBook" className="mt-1 w-full rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm text-zinc-100 outline-none focus:border-sky-400" />
              </label>
              {enrollError ? <div className="mt-2 text-xs text-red-300">{enrollError}</div> : null}
              <div className="mt-3 flex justify-end gap-2">
                <button type="button" data-debug-id="settings-bridges-enroll-cancel" onClick={() => setEnrollOpen(false)} className="rounded-xl border border-white/10 px-3 py-1.5 text-sm text-zinc-400 hover:bg-white/10">Cancel</button>
                <button type="button" data-debug-id="settings-bridges-enroll-create" onClick={() => void handleCreateEnrollment()} disabled={enrollBusy} className="rounded-xl bg-sky-400 px-3 py-1.5 text-sm font-semibold text-black hover:bg-sky-300 disabled:opacity-50">{enrollBusy ? 'Creating…' : 'Create enrollment'}</button>
              </div>
            </>
          ) : (
            <>
              <div data-debug-id="settings-bridges-enroll-result" className="text-sm font-medium text-sky-100">Enrollment created — run on your machine:</div>
              <div className="mt-1 text-xs text-amber-200">⚠ Shown once. Store the token now — it is a secret. This page will poll while you connect the bridge.</div>
              <pre data-debug-id="settings-bridges-enroll-command" className="mt-2 overflow-x-auto rounded-xl border border-white/10 bg-black/50 p-3 text-[12px] leading-5 text-emerald-200">{buildSetupCommand(enrollResult)}</pre>
              <div className="mt-2 flex flex-wrap items-center gap-2">
                <button type="button" data-debug-id="settings-bridges-enroll-copy-token" onClick={() => void copyToken(enrollResult?.enrollment_token || '')} className="rounded-xl bg-white/10 px-3 py-1.5 text-sm text-zinc-200 hover:bg-white/15">{copiedToken ? 'Copied' : 'Copy token'}</button>
                <button type="button" data-debug-id="settings-bridges-enroll-done" onClick={() => { setEnrollOpen(false); setEnrollResult(null); setEnrollLabel(''); }} className="rounded-xl bg-sky-400 px-3 py-1.5 text-sm font-semibold text-black hover:bg-sky-300">Done</button>
              </div>
            </>
          )}
        </div>
      ) : null}

      {/* Pending enrollments */}
      {pendingEnrollments.length > 0 ? (
        <div data-debug-id="settings-bridges-pending" className="mt-4">
          <div className="mb-2 text-[11px] uppercase tracking-[0.18em] text-zinc-500">Pending enrollments</div>
          <div className="space-y-2">
            {pendingEnrollments.map((enr: any) => {
              const id = String(enr?.enrollment_id || enr?.id || '');
              return (
                <div key={id} data-debug-id={`settings-bridges-pending-${id}`} className="flex items-center justify-between gap-2 rounded-xl border border-amber-400/20 bg-amber-400/[0.04] px-3 py-2 text-sm">
                  <div className="min-w-0">
                    <div className="truncate text-zinc-200">{enr?.label || 'Unlabeled enrollment'}</div>
                    <div className="mt-0.5 text-[11px] text-zinc-500">waiting for bridge to connect… · expires: {enr?.expires_at ? new Date(enr.expires_at).toLocaleString() : enr?.expires_unix_ms ? new Date(Number(enr.expires_unix_ms)).toLocaleString() : '—'}</div>
                  </div>
                  <button type="button" data-debug-id={`settings-bridges-pending-revoke-${id}`} onClick={() => void handleRevokeEnrollment(id)} className="shrink-0 rounded-lg border border-white/10 px-2 py-1 text-[11px] text-zinc-400 hover:bg-white/10">Revoke</button>
                </div>
              );
            })}
          </div>
        </div>
      ) : null}

      {/* Bridge list */}
      <div data-debug-id="settings-bridges-list" className="mt-4">
        <div className="mb-2 text-[11px] uppercase tracking-[0.18em] text-zinc-500">Bridges ({bridges.length})</div>
        {bridgesQuery.isFetching && bridges.length === 0 ? <div className="text-sm text-zinc-500">Loading bridges…</div> : null}
        {bridges.length === 0 && !bridgesQuery.isFetching ? (
          <div data-debug-id="settings-bridges-empty" className="rounded-xl border border-dashed border-white/10 bg-black/20 p-4 text-center text-sm text-zinc-500">No bridges yet. Add one to connect a machine.</div>
        ) : (
          <div className="space-y-2">
            {bridges.map((bridge: any) => {
              const id = String(bridge?.bridge_id || bridge?.bridgeId || bridge?.id || '');
              const isRenaming = renamingId === id;
              const isRevoking = revokeConfirmId === id;
              return (
                <div key={id} data-debug-id={`settings-bridge-row-${id}`} className="rounded-xl border border-white/10 bg-black/20 px-3 py-2.5">
                  <div className="flex items-start justify-between gap-2">
                    <div className="min-w-0">
                      <div className="flex items-center gap-2">
                        <span data-debug-id={`settings-bridge-status-${id}`} className={`h-2 w-2 shrink-0 rounded-full ${statusTone(bridge)}`} />
                        {isRenaming ? (
                          <input data-debug-id={`settings-bridge-rename-input-${id}`} value={renameValue} onChange={(e) => setRenameValue(e.target.value)} className="min-w-0 flex-1 rounded-lg border border-white/10 bg-black/40 px-2 py-0.5 text-sm text-zinc-100 outline-none focus:border-sky-400" autoFocus />
                        ) : (
                          <span className="truncate text-sm font-medium text-zinc-100">{bridge?.label || bridge?.machine_hostname || bridge?.hostname || id}</span>
                        )}
                        <span data-debug-id={`settings-bridge-ready-${id}`} className={`rounded-full border px-2 py-0.5 text-[10px] ${bridgeReady(bridge) ? 'border-emerald-400/30 bg-emerald-400/10 text-emerald-200' : 'border-amber-400/20 bg-amber-400/5 text-amber-200'}`}>{bridgeReady(bridge) ? 'ready' : 'setup incomplete'}</span>
                      </div>
                      <div className="mt-1 flex flex-wrap gap-x-3 gap-y-0.5 text-[11px] text-zinc-500">
                        <span>status: <span data-debug-id={`settings-bridge-status-label-${id}`} className="text-zinc-300">{statusLabel(bridge)}</span></span>
                        <span>host: <span className="text-zinc-300">{bridge?.machine_hostname || bridge?.hostname || '—'}</span></span>
                        <span>os: <span className="text-zinc-300">{bridge?.machine_os || bridge?.os || '—'}</span></span>
                        <span>arch: <span className="text-zinc-300">{bridge?.machine_arch || bridge?.arch || '—'}</span></span>
                        <span>caps: <span data-debug-id={`settings-bridge-caps-${id}`} className="text-zinc-300">{capabilitiesLabel(bridge)}</span></span>
                        <span>instances: <span className="text-zinc-300">{bridge?.active_instance_count ?? bridge?.instance_count ?? bridge?.instances?.length ?? 0}</span></span>
                        <span>last seen: <span className="text-zinc-300">{bridge?.last_seen_at ? new Date(bridge.last_seen_at).toLocaleString() : '—'}</span></span>
                      </div>
                    </div>
                    <div className="flex shrink-0 items-center gap-1">
                      {isRenaming ? (
                        <>
                          <button type="button" data-debug-id={`settings-bridge-rename-save-${id}`} onClick={() => void handleSaveRename(id)} className="rounded-lg bg-sky-400 px-2 py-1 text-[11px] font-semibold text-black hover:bg-sky-300">Save</button>
                          <button type="button" data-debug-id={`settings-bridge-rename-cancel-${id}`} onClick={() => setRenamingId('')} className="rounded-lg border border-white/10 px-2 py-1 text-[11px] text-zinc-400 hover:bg-white/10">Cancel</button>
                        </>
                      ) : isRevoking ? (
                        <>
                          <button type="button" data-debug-id={`settings-bridge-revoke-confirm-${id}`} onClick={() => void handleRevoke(id)} className="rounded-lg bg-rose-400 px-2 py-1 text-[11px] font-semibold text-black hover:bg-rose-300">Confirm revoke</button>
                          <button type="button" data-debug-id={`settings-bridge-revoke-cancel-${id}`} onClick={() => setRevokeConfirmId('')} className="rounded-lg border border-white/10 px-2 py-1 text-[11px] text-zinc-400 hover:bg-white/10">Cancel</button>
                        </>
                      ) : (
                        <>
                          <button type="button" data-debug-id={`settings-bridge-rename-btn-${id}`} onClick={() => { setRenamingId(id); setRenameValue(bridge?.label || ''); }} className="rounded-lg border border-white/10 px-2 py-1 text-[11px] text-zinc-400 hover:bg-white/10">Rename</button>
                          <button type="button" data-debug-id={`settings-bridge-revoke-btn-${id}`} onClick={() => setRevokeConfirmId(id)} className="rounded-lg border border-white/10 px-2 py-1 text-[11px] text-rose-300 hover:bg-rose-500/10">Revoke</button>
                        </>
                      )}
                    </div>
                  </div>
                </div>
              );
            })}
          </div>
        )}
      </div>

      <div data-debug-id="settings-bridges-gap-note" className="mt-4 rounded-xl border border-white/[0.06] bg-black/20 px-3 py-2 text-[11px] text-zinc-500">
        Backend gap: token rotation (<code>POST /bridges/&#123;id&#125;/rotate-token</code>) is not yet served by the Hub. Rename (PATCH) and revoke (POST /revoke) work against <code>/api/v1/bridges</code>.
      </div>
    </section>
  );
}
