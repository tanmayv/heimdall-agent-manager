import { useCallback, useEffect, useMemo, useState } from 'react';
import { useDispatch } from 'react-redux';
import * as daemonApi from '../api/daemonApi';
import { showToast } from '../store/toastSlice';
import ArtifactViewer from './ArtifactViewer';
import { useArtifactUpload } from './ArtifactUpload';

type ChainArtifactsPanelProps = {
  daemonUrl?: string;
  clientToken?: string;
  projectId?: string;
  chainId?: string;
};

type ArtifactRow = {
  artifact_id: string;
  name: string;
  kind: string;
  mime: string;
  ext: string;
  size_bytes: number;
  description: string;
  project_id: string;
  creator_type: string;
  creator_id: string;
  origin_kind: string;
  origin_ref: string;
  created_unix_ms: number;
  updated_unix_ms: number;
  deleted: boolean;
  link: string;
};

function formatBytes(value: number) {
  if (!Number.isFinite(value) || value <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB'];
  let size = value;
  let unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit += 1;
  }
  return `${size >= 10 || unit === 0 ? size.toFixed(0) : size.toFixed(1)} ${units[unit]}`;
}

function formatWhen(value: number) {
  if (!Number.isFinite(value) || value <= 0) return '';
  try {
    return new Date(value).toLocaleString();
  } catch (_err) {
    return '';
  }
}

function humanArtifactName(row: ArtifactRow) {
  return String(row?.name || row?.artifact_id || 'Untitled artifact');
}

function normalizeArtifacts(data: any): ArtifactRow[] {
  const rows = Array.isArray(data?.artifacts) ? data.artifacts : [];
  return [...rows]
    .filter((row: any) => row?.artifact_id)
    .sort((a: any, b: any) => {
      const left = Number(b?.updated_unix_ms || b?.created_unix_ms || 0);
      const right = Number(a?.updated_unix_ms || a?.created_unix_ms || 0);
      return left - right;
    });
}

export default function ChainArtifactsPanel({ daemonUrl = '', clientToken = '', projectId = '', chainId = '' }: ChainArtifactsPanelProps) {
  const dispatch = useDispatch<any>();
  const [artifacts, setArtifacts] = useState<ArtifactRow[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const [activeArtifactId, setActiveArtifactId] = useState('');
  const pasteUpload = useArtifactUpload({ projectId, originRef: chainId || '', originKind: 'clipboard_panel' });

  const refreshArtifacts = useCallback(async () => {
    if (!projectId) {
      setArtifacts([]);
      setError('');
      setLoading(false);
      return;
    }
    if (!daemonUrl || !clientToken) {
      setArtifacts([]);
      setError('Artifact listing is unavailable until the UI is connected to the daemon.');
      setLoading(false);
      return;
    }
    setLoading(true);
    setError('');
    try {
      const data = await daemonApi.listArtifacts({ daemonUrl, clientToken, projectId, limit: 100 });
      setArtifacts(normalizeArtifacts(data));
    } catch (err: any) {
      setArtifacts([]);
      setError(String(err?.message || err || 'Failed to load project artifacts.'));
    } finally {
      setLoading(false);
    }
  }, [daemonUrl, clientToken, projectId]);

  useEffect(() => {
    refreshArtifacts();
  }, [refreshArtifacts, chainId]);

  const projectLabel = useMemo(() => projectId || 'No project', [projectId]);

  const copyArtifactLink = useCallback(async (artifactId: string) => {
    const link = `artifact://${artifactId}`;
    try {
      if (!navigator?.clipboard?.writeText) throw new Error('Clipboard access is unavailable in this browser.');
      await navigator.clipboard.writeText(link);
      dispatch(showToast({ kind: 'success', title: 'Artifact link copied', message: link }));
    } catch (err: any) {
      dispatch(showToast({ kind: 'error', title: 'Copy failed', message: String(err?.message || err || 'Unable to copy artifact link.') }));
    }
  }, [dispatch]);

  const handlePanelPaste = useCallback(async (event: any) => {
    const result = await pasteUpload.uploadClipboardImage(event, { projectId, originKind: 'clipboard_panel', originRef: chainId || '' });
    if (result.link) {
      dispatch(showToast({ kind: 'success', title: 'Artifact created', message: result.link }));
      refreshArtifacts();
    }
  }, [pasteUpload, projectId, chainId, dispatch, refreshArtifacts]);

  return (
    <>
      <section data-debug-id="chain-artifacts-panel" tabIndex={0} onPaste={handlePanelPaste} className="flex h-[70vh] max-h-[70vh] min-h-[420px] flex-col rounded-2xl border border-white/10 bg-white/[0.035] p-4 outline-none focus:border-sky-400/50 focus:ring-1 focus:ring-sky-400/30">
        <div className="mb-3 flex flex-wrap items-start justify-between gap-3">
          <div
            data-debug-id="chain-artifacts-paste-zone"
            className="order-last w-full rounded-xl border border-dashed border-white/10 bg-black/20 px-3 py-2 text-xs text-zinc-400 xl:order-none"
          >
            Focus this panel or any artifact row and paste a PNG screenshot/image to create a project artifact.
            {pasteUpload.uploading ? <span className="ml-2 text-sky-200">Uploading clipboard image…</span> : null}
          </div>
          <div className="min-w-0">
            <h2 className="font-semibold">Project artifacts</h2>
            <p className="mt-0.5 truncate text-xs text-zinc-500">{projectId ? `Project ${projectLabel}` : 'Listing unavailable without project context.'}</p>
          </div>
          <button
            type="button"
            data-debug-id="chain-artifacts-refresh-btn"
            disabled={loading || !projectId}
            onClick={() => refreshArtifacts()}
            className="rounded-xl bg-white/10 px-3 py-2 text-xs font-medium text-zinc-200 hover:bg-white/15 disabled:cursor-not-allowed disabled:bg-white/5 disabled:text-zinc-500"
          >
            {loading ? 'Refreshing…' : 'Refresh'}
          </button>
        </div>

        {pasteUpload.error ? (
          <div data-debug-id="chain-artifacts-paste-error" className="mb-3 rounded-xl border border-red-400/30 bg-red-500/10 px-3 py-2 text-xs text-red-100">
            {pasteUpload.error}
          </div>
        ) : null}

        {!projectId ? (
          <div className="flex flex-1 items-center justify-center rounded-2xl border border-dashed border-white/10 bg-black/20 px-4 text-center text-sm text-zinc-400">
            This chain has no project_id, so project artifact listing is unavailable.
          </div>
        ) : loading && artifacts.length === 0 ? (
          <div className="flex flex-1 items-center justify-center rounded-2xl border border-dashed border-white/10 bg-black/20 px-4 text-sm text-zinc-400">
            Loading project artifacts…
          </div>
        ) : error ? (
          <div data-debug-id="chain-artifacts-error" className="flex flex-1 items-center justify-center rounded-2xl border border-amber-400/20 bg-amber-400/10 px-4 text-center text-sm text-amber-100">
            {error}
          </div>
        ) : artifacts.length === 0 ? (
          <div data-debug-id="chain-artifacts-empty" className="flex flex-1 items-center justify-center rounded-2xl border border-dashed border-white/10 bg-black/20 px-4 text-center text-sm text-zinc-400">
            No artifacts found for this project yet.
          </div>
        ) : (
          <div className="min-h-0 flex-1 overflow-y-auto pr-1">
            <div className="space-y-3">
              {artifacts.map((row) => {
                const artifactId = String(row.artifact_id || '');
                const kind = String(row.kind || '').trim();
                const mime = String(row.mime || '').trim();
                const originKind = String(row.origin_kind || '').trim();
                const originRef = String(row.origin_ref || '').trim();
                const creator = String(row.creator_id || row.creator_type || '').trim();
                const createdAt = formatWhen(Number(row.created_unix_ms || 0));
                const updatedAt = formatWhen(Number(row.updated_unix_ms || 0));
                const detailBits = [kind || 'artifact', mime, formatBytes(Number(row.size_bytes || 0))].filter(Boolean);
                const contextBits = [
                  creator ? `creator ${creator}` : '',
                  originKind ? `origin ${originKind}${originRef ? ` · ${originRef}` : ''}` : '',
                  updatedAt ? `updated ${updatedAt}` : createdAt ? `created ${createdAt}` : '',
                ].filter(Boolean);
                return (
                  <div key={artifactId} data-debug-id={`chain-artifact-row-${artifactId}`} className="rounded-2xl border border-white/10 bg-black/20 p-3">
                    <div className="flex items-start justify-between gap-3">
                      <div className="min-w-0 flex-1">
                        <div className="truncate text-sm font-semibold text-zinc-100">{humanArtifactName(row)}</div>
                        <div className="mt-1 truncate text-[11px] font-mono text-zinc-500">artifact://{artifactId}</div>
                        <div className="mt-2 flex flex-wrap gap-2 text-xs text-zinc-300">
                          {detailBits.map((bit) => (
                            <span key={bit} className="rounded-full bg-white/5 px-2 py-1">{bit}</span>
                          ))}
                        </div>
                        {contextBits.length > 0 ? (
                          <div className="mt-2 flex flex-wrap gap-x-3 gap-y-1 text-xs text-zinc-500">
                            {contextBits.map((bit) => (
                              <span key={bit}>{bit}</span>
                            ))}
                          </div>
                        ) : null}
                      </div>
                      <div className="flex shrink-0 flex-col gap-2 sm:flex-row">
                        <button
                          type="button"
                          data-debug-id={`chain-artifact-copy-btn-${artifactId}`}
                          onClick={() => copyArtifactLink(artifactId)}
                          className="rounded-xl bg-white/10 px-3 py-2 text-xs font-medium text-zinc-100 hover:bg-white/15"
                        >
                          Copy link
                        </button>
                        <button
                          type="button"
                          data-debug-id={`chain-artifact-open-btn-${artifactId}`}
                          onClick={() => setActiveArtifactId(artifactId)}
                          className="rounded-xl bg-sky-400 px-3 py-2 text-xs font-semibold text-black hover:bg-sky-300"
                        >
                          Open
                        </button>
                      </div>
                    </div>
                  </div>
                );
              })}
            </div>
          </div>
        )}
      </section>
      {activeArtifactId && daemonUrl && clientToken ? (
        <ArtifactViewer artifactId={activeArtifactId} daemonUrl={daemonUrl} clientToken={clientToken} onClose={() => setActiveArtifactId('')} />
      ) : null}
    </>
  );
}
