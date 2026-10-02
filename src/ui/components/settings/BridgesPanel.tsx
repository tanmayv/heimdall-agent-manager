import { useEffect, useMemo, useState } from 'react';
import {
  type Bridge,
  normalizeBridgeCapabilities,
  useListBridgesQuery,
  useListBridgeEnrollmentsQuery,
  useRenameBridgeMutation,
  useRevokeBridgeMutation,
  useUpdateBridgeMutation,
  useCreateBridgeEnrollmentMutation,
  useRevokeBridgeEnrollmentMutation,
  useUpdateBridgeTelemetryMutation,
} from '../../api/endpoints/bridgeSupport';
import {
  useFetchTelemetryDefaultEnabledQuery,
  useSaveTelemetryDefaultEnabledMutation,
} from '../../api/endpoints/settings';
import { Button, FormField, Icon, Input, PageShell, StatusDot, Text, Modal, ModalBody, ModalFooter, Spinner, Toggle } from '@ui';
import type { Tone } from '@ui';
import {
  isPendingEnrollment as checkIsPendingEnrollment,
  bridgeReady as checkBridgeReady,
} from './bridgeEnrollment';
import {
  formatBridgeVersion,
  formatLatestVersion,
  isBridgeUpdating,
  getActiveTaskCount,
} from './bridgeUpdate';

// UI-11: Settings → Bridges. The user's machines (arch doc §6A).
// List shows status dot, label, hostname/OS/arch, capabilities, instance count.
// Add bridge = enrollment ceremony (one-time token shown once). Detail allows
// rename (PATCH), revoke (= "remove", POST /revoke). No hard delete in v1.
// Rotate-token is a documented backend gap (not yet served).
export default function BridgesPanel() {
  const [enrollOpen, setEnrollOpen] = useState(false);
  const [hasPendingEnrollments, setHasPendingEnrollments] = useState(false);
  const pollActive = enrollOpen || hasPendingEnrollments;
  const bridgesQuery = useListBridgesQuery(undefined, { pollingInterval: pollActive ? 120000 : 0 });
  const enrollmentsQuery = useListBridgeEnrollmentsQuery(undefined, { pollingInterval: pollActive ? 120000 : 0 });
  const [renameBridge] = useRenameBridgeMutation();
  const [updateBridgeTelemetry] = useUpdateBridgeTelemetryMutation();
  const [revokeBridge] = useRevokeBridgeMutation();
  const [updateBridge] = useUpdateBridgeMutation();
  const [createEnrollment] = useCreateBridgeEnrollmentMutation();
  const [revokeEnrollment] = useRevokeBridgeEnrollmentMutation();
  const { data: globalTelemetryData } = useFetchTelemetryDefaultEnabledQuery();
  const [saveGlobalTelemetry] = useSaveTelemetryDefaultEnabledMutation();

  const [enrollLabel, setEnrollLabel] = useState('');
  const [enrollBusy, setEnrollBusy] = useState(false);
  const [enrollResult, setEnrollResult] = useState<any>(null);
  const [enrollError, setEnrollError] = useState('');
  const [renamingId, setRenamingId] = useState('');
  const [renameValue, setRenameValue] = useState('');
  const [revokeConfirmId, setRevokeConfirmId] = useState('');
  const [actionError, setActionError] = useState('');
  const [copiedToken, setCopiedToken] = useState(false);

  // Update modal state
  const [updateModalBridge, setUpdateModalBridge] = useState<Bridge | null>(null);
  const [updateForce, setUpdateForce] = useState(false);
  const [updateDrainTimeout, setUpdateDrainTimeout] = useState(60);
  const [updateBusy, setUpdateBusy] = useState(false);
  const [updateError, setUpdateError] = useState('');

  const bridges: Bridge[] = (bridgesQuery.data?.bridges || []).filter((b: Bridge) => String(b?.status || b?.runtime_status || '').toLowerCase() !== 'revoked');
  const enrolledBridgeIds = useMemo(() => new Set<string>(
    bridges.map((b: Bridge) => String(b?.bridge_id || b?.bridgeId || b?.id || '')).filter(Boolean)
  ), [bridges]);
  const enrollments = enrollmentsQuery.data?.enrollments || [];
  const pendingEnrollments = enrollments.filter((enr: any) => isPendingEnrollment(enr));

  useEffect(() => {
    setHasPendingEnrollments(pendingEnrollments.length > 0);
  }, [pendingEnrollments.length]);

  // REQ-BRG-1: Check terminal and consumed states first (status === 'consumed' || status === 'revoked' || status === 'expired', consumed_at, revoked_at, and consumed_by_bridge_id matching an enrolled bridge in bridges). If consumed or revoked, return false.
  function isPendingEnrollment(enrollment: any): boolean {
    return checkIsPendingEnrollment(enrollment, enrolledBridgeIds);
  }

  function statusTone(bridge: Bridge): Tone {
    const status = String(bridge?.status || bridge?.runtime_status || '').toLowerCase();
    if (status === 'revoked') return 'danger';
    if (status === 'online' || status === 'connected') return 'success';
    return 'neutral';
  }

  function statusLabel(bridge: Bridge): string {
    const status = String(bridge?.status || bridge?.runtime_status || '').toLowerCase();
    return status || 'offline';
  }

  function capabilitiesLabel(bridge: Bridge): string {
    const providers = normalizeBridgeCapabilities(bridge);
    return providers.length ? providers.map((cap) => `${cap.provider}${cap.tiers.length ? ` (${cap.tiers.join('/')})` : ''}`).join(', ') : '—';
  }

  // REQ-BRG-1: An enrolled, online bridge is ready regardless of whether provider capabilities are loaded yet.
  function bridgeReady(bridge: Bridge): boolean {
    return checkBridgeReady(bridge);
  }

  function configuredHubUrl(): string {
    const explicit = String(
      resultEnv('VITE_HEIMDALL_HUB_API_URL') ||
      resultEnv('VITE_HEIMDALL_HUB_URL') ||
      (typeof window !== 'undefined' ? ((window as any).odinApi?.hubApiBaseUrl || '') : '')
    ).trim().replace(/\/$/, '');
    if (explicit) return explicit;
    if (typeof window === 'undefined') return '';
    const { protocol, hostname, port } = window.location;
    if (hostname.startsWith('heimdall.')) return `${protocol}//hub.${hostname.slice('heimdall.'.length)}${port ? `:${port}` : ''}`;
    return window.location.origin;
  }

  function resultEnv(key: string): string {
    return String((import.meta as any).env?.[key] || '');
  }

  function buildSetupCommand(result: any): string {
    const responseCommand = String(result?.setup_command || '');
    const url = String(result?.hub_url || result?.daemon_url || configuredHubUrl()).replace(/\/$/, '');
    if (responseCommand && !responseCommand.includes('$HAM_HUB_URL') && responseCommand.includes(String(result?.enrollment_token || ''))) return responseCommand;
    if (responseCommand && !responseCommand.includes('$HAM_HUB_URL')) return `${responseCommand} \\\n  --enrollment-token ${result?.enrollment_token || ''}`;
    const token = result?.enrollment_token || '';
    return `ham-bridge enroll --hub ${url || '<hub-url>'} \\\n  --enrollment-token ${token}`;
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

  async function handleToggleGlobalTelemetry(enabled: boolean) {
    try {
      await saveGlobalTelemetry({ enabled }).unwrap();
    } catch (err: any) {
      setActionError(String(err?.message || 'Failed to update global telemetry setting'));
    }
  }

  async function handleUpdateBridgeTelemetry(bridgeId: string, telemetry: 'inherit' | 'enabled' | 'disabled') {
    try {
      await updateBridgeTelemetry({ bridgeId, telemetry_enabled: telemetry }).unwrap();
    } catch (err: any) {
      setActionError(String(err?.message || 'Failed to update bridge telemetry preference'));
    }
  }

  async function handleConfirmUpdate() {
    if (!updateModalBridge) return;
    const bridgeId = String(updateModalBridge.bridge_id || updateModalBridge.bridgeId || updateModalBridge.id || '');
    setUpdateBusy(true);
    setUpdateError('');
    try {
      await updateBridge({
        bridgeId,
        targetVersion: updateModalBridge.latest_version || 'latest',
        force: updateForce,
        drainTimeoutSeconds: updateDrainTimeout,
      }).unwrap();
      setUpdateModalBridge(null);
    } catch (err: any) {
      setUpdateError(String(err?.data?.error?.message || err?.error || err?.message || 'Failed to trigger bridge update'));
    } finally {
      setUpdateBusy(false);
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
    <PageShell
      title="Bridges"
      description="Your machines. “Remove” revokes the token (record kept); no hard delete in v1."
      actions={
        <Button variant="primary" data-debug-id="settings-bridges-add-btn" onClick={() => { setEnrollOpen((o) => !o); setEnrollResult(null); setEnrollError(''); }} leading={<Icon name="plus" size={16} />}>Add bridge</Button>
      }
    >
      <div data-debug-id="settings-bridges-panel" className="min-w-0">
      {bridgesQuery.isError || enrollmentsQuery.isError ? <div data-debug-id="settings-bridges-load-error" className="mt-3 rounded-xl border border-danger/30 bg-danger-soft px-3 py-2 text-sm text-danger">Unable to load bridges. Check your trusted-proxy session and Hub connection.</div> : null}
      {actionError ? <div data-debug-id="settings-bridges-error" className="mt-3 rounded-xl border border-danger/30 bg-danger-soft px-3 py-2 text-sm text-danger">{actionError}</div> : null}

      {/* Enrollment ceremony */}
      {enrollOpen ? (
        <div data-debug-id="settings-bridges-enroll-panel" className="mt-3 rounded-2xl border border-info/30 bg-info-soft p-4">
          {!enrollResult ? (
            <>
              <div className="text-sm font-medium text-info">Create bridge enrollment</div>
              <FormField label="Label (optional; defaults to reported hostname)" className="mt-2">
                <Input data-debug-id="settings-bridges-enroll-label" value={enrollLabel} onChange={setEnrollLabel} placeholder="MacBook" width="full" />
              </FormField>
              {enrollError ? <div className="mt-2 text-xs text-danger">{enrollError}</div> : null}
              <div className="mt-3 flex justify-end gap-2">
                <Button variant="secondary" size="sm" data-debug-id="settings-bridges-enroll-cancel" onClick={() => setEnrollOpen(false)}>Cancel</Button>
                <Button variant="primary" size="sm" data-debug-id="settings-bridges-enroll-create" onClick={() => void handleCreateEnrollment()} disabled={enrollBusy}>{enrollBusy ? 'Creating…' : 'Create enrollment'}</Button>
              </div>
            </>
          ) : (
            <>
              <div data-debug-id="settings-bridges-enroll-result" className="text-sm font-medium text-info">Enrollment created — run on your machine:</div>
              <div className="mt-1 text-xs text-warning">⚠ Shown once. Store the token now — it is a secret. This page will poll while you connect the bridge.</div>
              <pre data-debug-id="settings-bridges-enroll-command" className="mt-2 overflow-x-auto rounded-xl border border-subtle bg-surface-raised/50 p-3 text-[12px] leading-5 text-success">{buildSetupCommand(enrollResult)}</pre>
              <div className="mt-2 flex flex-wrap items-center gap-2">
                <Button variant="secondary" size="sm" data-debug-id="settings-bridges-enroll-copy-token" onClick={() => void copyToken(enrollResult?.enrollment_token || '')}>{copiedToken ? 'Copied' : 'Copy token'}</Button>
                <Button variant="primary" size="sm" data-debug-id="settings-bridges-enroll-done" onClick={() => { setEnrollOpen(false); setEnrollResult(null); setEnrollLabel(''); }}>Done</Button>
              </div>
            </>
          )}
        </div>
      ) : null}

      {/* Pending enrollments */}
      {pendingEnrollments.length > 0 ? (
        <div data-debug-id="settings-bridges-pending" className="mt-4">
          <Text as="div" role="overline" tone="muted" className="mb-2">Pending enrollments</Text>
          <div className="space-y-2">
            {/* TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema */}
            {pendingEnrollments.map((enr: any) => {
              // TODO(FIX): Replace loose fallback chain with canonical typed schema property
              const id = String(enr?.enrollment_id || enr?.id || '');
              return (
                <div key={id} data-debug-id={`settings-bridges-pending-${id}`} className="flex items-center justify-between gap-2 rounded-xl border border-warning/30 bg-warning-soft px-3 py-2 text-sm">
                  <div className="min-w-0">
                    <div className="truncate text-primary">{enr?.label || 'Unlabeled enrollment'}</div>
                    <div className="mt-0.5 text-caption text-muted">waiting for bridge to connect… · expires: {enr?.expires_at ? new Date(enr.expires_at).toLocaleString() : enr?.expires_unix_ms ? new Date(Number(enr.expires_unix_ms)).toLocaleString() : '—'}</div>
                  </div>
                  <Button variant="secondary" size="sm" data-debug-id={`settings-bridges-pending-revoke-${id}`} onClick={() => void handleRevokeEnrollment(id)} className="shrink-0">Revoke</Button>
                </div>
              );
            })}
          </div>
        </div>
      ) : null}

      {/* Global Telemetry Setting */}
      <div data-debug-id="settings-bridges-global-telemetry" className="mt-4 rounded-xl border border-subtle bg-surface-raised/40 p-3.5 flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
        <div className="min-w-0">
          <div className="text-sm font-medium text-primary">Global Bridge Telemetry</div>
          <div className="text-xs text-muted">Enable telemetry across all bridges by default unless overridden per-bridge.</div>
        </div>
        <div className="flex items-center gap-2">
          <Toggle
            data-debug-id="settings-global-telemetry-toggle"
            checked={globalTelemetryData?.enabled ?? true}
            onChange={(checked) => void handleToggleGlobalTelemetry(checked)}
          />
          <span className="text-xs text-muted font-medium w-16">
            {(globalTelemetryData?.enabled ?? true) ? 'Enabled' : 'Disabled'}
          </span>
        </div>
      </div>

      {/* Bridge list */}
      <div data-debug-id="settings-bridges-list" className="mt-4">
        <Text as="div" role="overline" tone="muted" className="mb-2">Bridges ({bridges.length})</Text>
        {bridgesQuery.isFetching && bridges.length === 0 ? <div className="text-sm text-muted">Loading bridges…</div> : null}
        {bridges.length === 0 && !bridgesQuery.isFetching ? (
          <div data-debug-id="settings-bridges-empty" className="rounded-xl border border-dashed border-subtle bg-surface-raised/30 p-4 text-center text-sm text-muted">No bridges yet. Add one to connect a machine.</div>
        ) : (
          <div className="space-y-2">
            {bridges.map((bridge: Bridge) => {
              const id = String(bridge?.bridge_id || bridge?.bridgeId || bridge?.id || '');
              const isRenaming = renamingId === id;
              const isRevoking = revokeConfirmId === id;
              const isReady = bridgeReady(bridge);
              const status = statusLabel(bridge);
              const isUpdating = isBridgeUpdating(bridge);
              const hasVersion = Boolean(bridge?.version || bridge?.commit_sha);
              const versionLabel = formatBridgeVersion(bridge);
              const latestLabel = formatLatestVersion(bridge);

              return (
                <div key={id} data-debug-id={`settings-bridge-row-${id}`} className="rounded-xl border border-subtle bg-surface-raised/30 p-3 sm:px-3 sm:py-2.5">
                  <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between sm:gap-2">
                    <div className="min-w-0 flex-1">
                      <div className="flex flex-wrap items-center gap-1.5 sm:gap-2">
                        <StatusDot data-debug-id={`settings-bridge-status-${id}`} tone={statusTone(bridge)} label={statusLabel(bridge)} />
                        {isRenaming ? (
                          <Input data-debug-id={`settings-bridge-rename-input-${id}`} value={renameValue} onChange={setRenameValue} size="sm" className="min-w-0 flex-1" autoFocus />
                        ) : (
                          <span className="truncate text-sm font-medium text-primary">{bridge?.label || bridge?.machine_hostname || bridge?.hostname || id}</span>
                        )}
                        <span data-debug-id={`settings-bridge-ready-${id}`} className={`rounded-full border px-2 py-0.5 text-[10px] whitespace-nowrap ${isReady ? 'border-success/30 bg-success-soft text-success' : status === 'revoked' ? 'border-danger/30 bg-danger-soft text-danger' : 'border-warning/30 bg-warning-soft text-warning'}`}>{isReady ? 'ready' : status}</span>

                        {/* Monospace version badge: e.g. v0.1.0 (a57c83d9) */}
                        {hasVersion ? (
                          <span
                            data-debug-id={`settings-bridge-version-${id}`}
                            className="inline-flex items-center rounded-full border border-subtle bg-surface-raised/60 px-2 py-0.5 font-mono text-[10px] text-primary whitespace-nowrap"
                            title={bridge?.build_timestamp ? `Built: ${bridge.build_timestamp}` : undefined}
                          >
                            {versionLabel}
                          </span>
                        ) : null}

                        {/* Prominent Update Available badge */}
                        {bridge?.update_available ? (
                          <span
                            data-debug-id={`settings-bridge-update-available-${id}`}
                            className="inline-flex items-center gap-1 rounded-full border border-accent/40 bg-accent-soft px-2 py-0.5 text-[10px] font-medium text-accent whitespace-nowrap"
                          >
                            <Icon name="sparkle" size="sm" />
                            <span>Update available: {latestLabel}</span>
                          </span>
                        ) : null}

                        {/* Real-time progress state if update is in progress (downloading, validating, restarting) */}
                        {isUpdating ? (
                          <span
                            data-debug-id={`settings-bridge-update-progress-${id}`}
                            className="inline-flex items-center gap-1.5 rounded-full border border-accent/40 bg-accent-soft px-2 py-0.5 text-[10px] font-medium text-accent animate-pulse whitespace-nowrap"
                          >
                            <Spinner size="sm" />
                            <span>Updating ({bridge.update_status}…)</span>
                          </span>
                        ) : bridge?.update_status === 'failed' ? (
                          <span
                            data-debug-id={`settings-bridge-update-failed-${id}`}
                            className="inline-flex items-center gap-1 rounded-full border border-danger/40 bg-danger-soft px-2 py-0.5 text-[10px] text-danger whitespace-nowrap"
                            title={bridge?.update_error || 'Update failed'}
                          >
                            <Icon name="alert" size="sm" />
                            <span>Update failed{bridge?.update_error ? `: ${bridge.update_error}` : ''}</span>
                          </span>
                        ) : null}

                        {normalizeBridgeCapabilities(bridge).length === 0 ? (
                          <a
                            href={`#settings/providers?bridge=${encodeURIComponent(id)}`}
                            data-debug-id={`settings-bridge-no-providers-${id}`}
                            className="inline-flex items-center gap-1 rounded-full border border-subtle bg-surface-raised/40 px-2 py-0.5 text-[10px] text-muted hover:border-accent hover:text-accent transition-colors whitespace-nowrap"
                          >
                            no providers configured
                          </a>
                        ) : null}
                      </div>
                      <div className="mt-2 flex flex-wrap gap-x-3 gap-y-1 text-caption text-muted">
                        <span>status: <span data-debug-id={`settings-bridge-status-label-${id}`} className="text-primary">{statusLabel(bridge)}</span></span>
                        <span>host: <span className="text-primary">{bridge?.machine_hostname || bridge?.hostname || '—'}</span></span>
                        <span>os: <span className="text-primary">{bridge?.machine_os || bridge?.os || '—'}</span></span>
                        <span>arch: <span className="text-primary">{bridge?.machine_arch || bridge?.arch || '—'}</span></span>
                        <span>caps: <span data-debug-id={`settings-bridge-caps-${id}`} className="text-primary">{capabilitiesLabel(bridge)}</span></span>
                        <span>instances: <span className="text-primary">{bridge?.active_instance_count ?? bridge?.instance_count ?? bridge?.instances?.length ?? 0}</span></span>
                        <span>last seen: <span className="text-primary">{bridge?.last_seen_at ? new Date(bridge.last_seen_at).toLocaleString() : '—'}</span></span>
                      </div>
                      <div className="mt-2.5 flex flex-wrap items-center gap-2 text-xs">
                        <span className="text-muted font-medium">Telemetry:</span>
                        <div
                          data-debug-id={`settings-bridge-telemetry-toggle-${id}`}
                          className="inline-flex rounded-lg border border-subtle bg-surface p-0.5"
                          role="group"
                          aria-label={`Bridge ${id} Telemetry`}
                        >
                          <button
                            type="button"
                            data-debug-id={`settings-bridge-telemetry-inherit-${id}`}
                            className={`rounded px-2 py-0.5 text-xs transition-colors ${
                              (bridge?.telemetry_enabled || 'inherit') === 'inherit'
                                ? 'bg-surface-raised text-primary font-medium shadow-sm'
                                : 'text-muted hover:text-primary'
                            }`}
                            onClick={() => void handleUpdateBridgeTelemetry(id, 'inherit')}
                          >
                            Inherit Global ({(globalTelemetryData?.enabled ?? true) ? 'Enabled' : 'Disabled'})
                          </button>
                          <button
                            type="button"
                            data-debug-id={`settings-bridge-telemetry-enabled-${id}`}
                            className={`rounded px-2 py-0.5 text-xs transition-colors ${
                              bridge?.telemetry_enabled === 'enabled'
                                ? 'bg-success text-success-contrast font-medium shadow-sm'
                                : 'text-muted hover:text-primary'
                            }`}
                            onClick={() => void handleUpdateBridgeTelemetry(id, 'enabled')}
                          >
                            Enabled
                          </button>
                          <button
                            type="button"
                            data-debug-id={`settings-bridge-telemetry-disabled-${id}`}
                            className={`rounded px-2 py-0.5 text-xs transition-colors ${
                              bridge?.telemetry_enabled === 'disabled'
                                ? 'bg-danger text-danger-contrast font-medium shadow-sm'
                                : 'text-muted hover:text-primary'
                            }`}
                            onClick={() => void handleUpdateBridgeTelemetry(id, 'disabled')}
                          >
                            Disabled
                          </button>
                        </div>
                      </div>
                    </div>
                    <div className="flex flex-wrap items-center gap-1.5 sm:shrink-0 sm:justify-end">
                      {isRenaming ? (
                        <>
                          <Button variant="primary" size="sm" data-debug-id={`settings-bridge-rename-save-${id}`} onClick={() => void handleSaveRename(id)}>Save</Button>
                          <Button variant="secondary" size="sm" data-debug-id={`settings-bridge-rename-cancel-${id}`} onClick={() => setRenamingId('')}>Cancel</Button>
                        </>
                      ) : isRevoking ? (
                        <>
                          <Button variant="danger" size="sm" data-debug-id={`settings-bridge-revoke-confirm-${id}`} onClick={() => void handleRevoke(id)}>Revoke</Button>
                          <Button variant="secondary" size="sm" data-debug-id={`settings-bridge-revoke-cancel-${id}`} onClick={() => setRevokeConfirmId('')}>Cancel</Button>
                        </>
                      ) : (
                        <>
                          <Button
                            variant={bridge?.update_available ? 'primary' : 'secondary'}
                            size="sm"
                            data-debug-id={`settings-bridge-update-btn-${id}`}
                            disabled={!isReady || isUpdating}
                            onClick={() => {
                              setUpdateModalBridge(bridge);
                              setUpdateForce(false);
                              setUpdateDrainTimeout(60);
                              setUpdateError('');
                            }}
                          >
                            Update
                          </Button>
                          <Button variant="secondary" size="sm" data-debug-id={`settings-bridge-rename-btn-${id}`} onClick={() => { setRenamingId(id); setRenameValue(bridge?.label || ''); }}>Rename</Button>
                          <Button variant="danger" size="sm" data-debug-id={`settings-bridge-revoke-btn-${id}`} onClick={() => setRevokeConfirmId(id)}>Revoke</Button>
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


      {/* Update Bridge Modal */}
      {updateModalBridge ? (
        <Modal
          open
          onOpenChange={(next) => { if (!next && !updateBusy) setUpdateModalBridge(null); }}
          title={`Update: ${updateModalBridge?.label || updateModalBridge?.machine_hostname || updateModalBridge?.hostname || updateModalBridge?.bridge_id || 'Bridge'}`}
          size="md"
          data-debug-id="settings-bridge-update-modal"
        >
          <ModalBody className="space-y-4">
            <div className="flex flex-col gap-2 rounded-xl border border-subtle bg-surface-raised/40 p-3 text-xs">
              <div className="flex items-center justify-between">
                <span className="text-muted">Current Version:</span>
                <span className="font-mono text-primary" data-debug-id="settings-bridge-modal-current-version">
                  {updateModalBridge.version ? `v${updateModalBridge.version}` : 'unknown'}
                  {updateModalBridge.commit_sha ? ` (${updateModalBridge.commit_sha.slice(0, 8)})` : ''}
                </span>
              </div>
              <div className="flex items-center justify-between">
                <span className="text-muted">Target Version:</span>
                <span className="font-mono text-accent font-semibold" data-debug-id="settings-bridge-modal-target-version">
                  {updateModalBridge.latest_version ? `v${updateModalBridge.latest_version}` : 'latest'}
                  {updateModalBridge.latest_commit_sha ? ` (${updateModalBridge.latest_commit_sha.slice(0, 8)})` : ''}
                </span>
              </div>
            </div>

            {(updateModalBridge.active_instance_count ?? updateModalBridge.instance_count ?? 0) > 0 ? (
              <div data-debug-id="settings-bridge-update-warning" className="rounded-xl border border-warning/30 bg-warning-soft p-3 text-xs text-warning">
                <div className="flex items-center gap-1.5 font-semibold text-warning">
                  <Icon name="alert" size="sm" />
                  <span>Active Agent Tasks Running</span>
                </div>
                <p className="mt-1 text-primary">
                  {(updateModalBridge.active_instance_count ?? updateModalBridge.instance_count ?? 0)} agent task{((updateModalBridge.active_instance_count ?? updateModalBridge.instance_count ?? 0) === 1 ? ' is' : 's are')} currently running on this machine. Updating now will wait up to {updateDrainTimeout}s for tasks to complete, or force an immediate restart.
                </p>
                <div className="mt-3 space-y-2 text-primary">
                  <label className="flex items-center gap-2 cursor-pointer">
                    <input
                      type="radio"
                      name="update_strategy"
                      checked={!updateForce}
                      onChange={() => setUpdateForce(false)}
                      data-debug-id="settings-bridge-update-drain-option"
                      className="text-accent"
                    />
                    <span>Wait for tasks to complete (graceful drain, 60s timeout)</span>
                  </label>
                  <label className="flex items-center gap-2 cursor-pointer">
                    <input
                      type="radio"
                      name="update_strategy"
                      checked={updateForce}
                      onChange={() => setUpdateForce(true)}
                      data-debug-id="settings-bridge-update-force-option"
                      className="text-accent"
                    />
                    <span>Force immediate update (terminate active tasks now)</span>
                  </label>
                </div>
              </div>
            ) : (
              <div className="text-xs text-muted">
                This will stage the latest update bundle on the remote bridge, verify its cryptographic checksum and binary compatibility, and perform an in-situ restart with automated health-checked rollback.
              </div>
            )}

            {updateError ? (
              <div data-debug-id="settings-bridge-update-error" className="rounded-xl border border-danger/30 bg-danger-soft p-2.5 text-xs text-danger">
                {updateError}
              </div>
            ) : null}
          </ModalBody>
          <ModalFooter>
            <Button
              variant="secondary"
              data-debug-id="settings-bridge-update-cancel"
              onClick={() => setUpdateModalBridge(null)}
              disabled={updateBusy}
            >
              Cancel
            </Button>
            <Button
              variant="primary"
              loading={updateBusy}
              data-debug-id="settings-bridge-update-confirm"
              onClick={() => void handleConfirmUpdate()}
            >
              {updateForce ? 'Force' : 'Update'}
            </Button>
          </ModalFooter>
        </Modal>
      ) : null}

      <div data-debug-id="settings-bridges-gap-note" className="mt-4 rounded-xl border border-subtle bg-surface-raised/30 px-3 py-2 text-caption text-muted">
        Backend gap: token rotation (<code>{"POST /bridges/{id}/rotate-token"}</code>) is not yet served by the Hub. Rename (PATCH) and revoke (POST /revoke) work against <code>/api/v1/bridges</code>.
      </div>
      </div>
    </PageShell>
  );
}
