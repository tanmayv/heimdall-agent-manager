import { useEffect, useMemo, useState } from 'react';
import * as daemonApi from '../api/daemonApi';
import MarkdownBody from './MarkdownBody';

type ArtifactViewerProps = {
  artifactId: string;
  daemonUrl: string;
  clientToken: string;
  onClose: () => void;
};

type ArtifactMeta = {
  artifact_id: string;
  name: string;
  kind: string;
  mime: string;
  ext: string;
  size_bytes: number;
  sha256: string;
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
  renderer?: string;
};

const metaCache = new Map<string, ArtifactMeta>();
const textCache = new Map<string, string>();

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

function parseCsv(text: string) {
  const rows: string[][] = [];
  let row: string[] = [];
  let cell = '';
  let inQuotes = false;
  for (let i = 0; i < text.length; i += 1) {
    const ch = text[i];
    const next = text[i + 1];
    if (ch === '"') {
      if (inQuotes && next === '"') {
        cell += '"';
        i += 1;
      } else {
        inQuotes = !inQuotes;
      }
      continue;
    }
    if (!inQuotes && ch === ',') {
      row.push(cell);
      cell = '';
      continue;
    }
    if (!inQuotes && (ch === '\n' || ch === '\r')) {
      if (ch === '\r' && next === '\n') i += 1;
      row.push(cell);
      rows.push(row);
      row = [];
      cell = '';
      continue;
    }
    cell += ch;
  }
  if (cell.length > 0 || row.length > 0) {
    row.push(cell);
    rows.push(row);
  }
  return rows;
}

function ArtifactCsvPreview({ text }: { text: string }) {
  const rows = useMemo(() => parseCsv(text).slice(0, 50), [text]);
  if (rows.length === 0) return <div className="text-sm text-zinc-400">CSV is empty.</div>;
  const headers = rows[0] || [];
  const body = rows.slice(1);
  return (
    <div className="overflow-auto rounded-xl border border-white/10">
      <table className="min-w-full border-collapse text-left text-sm">
        <thead className="bg-white/[0.05] text-zinc-100">
          <tr>{headers.map((cell, index) => <th key={index} className="border-b border-white/10 px-3 py-2 font-medium">{cell}</th>)}</tr>
        </thead>
        <tbody>
          {body.map((cells, rowIndex) => (
            <tr key={rowIndex} className="odd:bg-white/[0.02]">
              {headers.map((_, cellIndex) => <td key={cellIndex} className="border-b border-white/5 px-3 py-2 align-top text-zinc-300">{cells[cellIndex] || ''}</td>)}
            </tr>
          ))}
        </tbody>
      </table>
      {parseCsv(text).length > 50 && <div className="border-t border-white/10 px-3 py-2 text-xs text-zinc-500">Preview truncated to 50 rows.</div>}
    </div>
  );
}

export default function ArtifactViewer({ artifactId, daemonUrl, clientToken, onClose }: ArtifactViewerProps) {
  const [meta, setMeta] = useState<ArtifactMeta | null>(metaCache.get(artifactId) || null);
  const [textContent, setTextContent] = useState<string>(textCache.get(artifactId) || '');
  const [loading, setLoading] = useState(!metaCache.has(artifactId));
  const [loadingText, setLoadingText] = useState(false);
  const [error, setError] = useState('');
  const [nestedArtifactId, setNestedArtifactId] = useState('');

  const contentUrl = useMemo(() => daemonApi.artifactContentUrl({ daemonUrl, clientToken, artifactId }), [daemonUrl, clientToken, artifactId]);

  useEffect(() => {
    let cancelled = false;
    async function loadMeta() {
      if (metaCache.has(artifactId)) {
        setMeta(metaCache.get(artifactId) || null);
        setLoading(false);
        return;
      }
      setLoading(true);
      setError('');
      try {
        const data = await daemonApi.fetchArtifactMeta({ daemonUrl, clientToken, artifactId });
        if (cancelled) return;
        const nextMeta = data?.artifact || null;
        if (nextMeta) metaCache.set(artifactId, nextMeta);
        setMeta(nextMeta);
      } catch (err: any) {
        if (!cancelled) setError(String(err?.message || err || 'Failed to load artifact metadata.'));
      } finally {
        if (!cancelled) setLoading(false);
      }
    }
    loadMeta();
    return () => { cancelled = true; };
  }, [artifactId, daemonUrl, clientToken]);

  useEffect(() => {
    let cancelled = false;
    async function loadText() {
      if (!meta || !(meta.kind === 'markdown' || meta.kind === 'csv')) return;
      if (textCache.has(artifactId)) {
        setTextContent(textCache.get(artifactId) || '');
        return;
      }
      setLoadingText(true);
      try {
        const response = await fetch(contentUrl);
        if (!response.ok) throw new Error(`Failed to load artifact content (${response.status})`);
        const text = await response.text();
        if (cancelled) return;
        textCache.set(artifactId, text);
        setTextContent(text);
      } catch (err: any) {
        if (!cancelled) setError(String(err?.message || err || 'Failed to load artifact content.'));
      } finally {
        if (!cancelled) setLoadingText(false);
      }
    }
    loadText();
    return () => { cancelled = true; };
  }, [artifactId, contentUrl, meta]);

  const title = meta?.name || artifactId;

  return (
    <div className="fixed inset-0 z-[80] flex items-center justify-center bg-black/70 p-4" onClick={onClose}>
      <div data-debug-id="artifact-viewer" className="flex max-h-[90vh] w-full max-w-5xl flex-col overflow-hidden rounded-3xl border border-white/10 bg-[#0d0f14] shadow-2xl" onClick={(event) => event.stopPropagation()}>
        <div className="flex items-start justify-between gap-4 border-b border-white/10 px-5 py-4">
          <div className="min-w-0">
            <div className="truncate text-lg font-semibold text-zinc-100">{title}</div>
            <div className="mt-1 flex flex-wrap gap-2 text-xs text-zinc-400">
              <span>{meta?.kind || 'artifact'}</span>
              {meta?.mime && <span>{meta.mime}</span>}
              {meta?.size_bytes != null && <span>{formatBytes(Number(meta.size_bytes))}</span>}
              {meta?.link && <span className="font-mono">{meta.link}</span>}
            </div>
          </div>
          <div className="flex items-center gap-2">
            <a data-debug-id="artifact-viewer-download-btn" href={contentUrl} download={meta?.name || artifactId} className="rounded-xl bg-sky-400 px-3 py-2 text-sm font-semibold text-black hover:bg-sky-300">Download</a>
            <button type="button" onClick={onClose} className="rounded-xl bg-white/10 px-3 py-2 text-sm text-zinc-200 hover:bg-white/15">Close</button>
          </div>
        </div>
        <div className="overflow-auto p-5">
          {loading && <div className="text-sm text-zinc-400">Loading artifact…</div>}
          {!loading && error && <div className="rounded-xl border border-amber-400/20 bg-amber-400/10 px-4 py-3 text-sm text-amber-100">{error}</div>}
          {!loading && !error && meta && (
            <div className="space-y-4">
              {meta.description && <div className="text-sm text-zinc-300">{meta.description}</div>}
              {meta.kind === 'png' || meta.kind === 'jpeg' ? (
                <img src={contentUrl} alt={meta.name || artifactId} className="max-h-[70vh] max-w-full rounded-2xl border border-white/10 bg-black/30" />
              ) : meta.kind === 'html' ? (
                <iframe title={meta.name || artifactId} src={contentUrl} sandbox="allow-downloads allow-forms allow-modals allow-pointer-lock allow-popups allow-popups-to-escape-sandbox allow-presentation allow-same-origin allow-scripts" className="h-[70vh] w-full rounded-2xl border border-white/10 bg-white" />
              ) : meta.kind === 'csv' ? (
                loadingText ? <div className="text-sm text-zinc-400">Loading CSV preview…</div> : <ArtifactCsvPreview text={textContent} />
              ) : meta.kind === 'markdown' ? (
                loadingText ? <div className="text-sm text-zinc-400">Loading markdown…</div> : <MarkdownBody source={textContent} className="text-zinc-200" onArtifactClick={setNestedArtifactId} />
              ) : (
                <div className="rounded-xl border border-white/10 bg-black/20 px-4 py-3 text-sm text-zinc-400">Unsupported artifact kind: {meta.kind}</div>
              )}
            </div>
          )}
        </div>
      </div>
      {nestedArtifactId ? (
        <ArtifactViewer artifactId={nestedArtifactId} daemonUrl={daemonUrl} clientToken={clientToken} onClose={() => setNestedArtifactId('')} />
      ) : null}
    </div>
  );
}
