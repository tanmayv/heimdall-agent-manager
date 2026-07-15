import { useEffect, useMemo, useRef } from 'react';
import { useSelector } from 'react-redux';
import mermaid from 'mermaid';
import * as daemonApi from '../api/daemonApi';

let mermaidInitialized = false;
function ensureMermaidInitialized() {
  if (!mermaidInitialized) {
    mermaid.initialize({
      startOnLoad: false,
      theme: 'dark',
      securityLevel: 'loose',
    });
    mermaidInitialized = true;
  }
}

// Module-level caches so repeated renders / multiple bubbles referencing the
// same artifact don't refetch metadata. Names are safe to display; tokens never
// touch these caches or the DOM.
const artifactNameCache = new Map<string, string>();
const artifactNamePending = new Map<string, Promise<string>>();

export type MarkdownTextSelection = {
  selectedText: string;
};

export type MarkdownBodyProps = {
  source: string;
  className?: string;
  compact?: boolean;
  copyAll?: boolean;
  'data-debug-id'?: string;
  onArtifactClick?: (artifactId: string) => void;
  onTextSelectionChange?: (selection: MarkdownTextSelection | null) => void;
};

const ARTIFACT_TOKEN_RE = /(^|[^"'>])(artifact:\/\/(art_[0-9a-f]{8,}))/g;

function escapeHtml(value: string): string {
  return value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function normalizeMarkdownSource(source: string): string {
  return String(source || '').replace(/\\n/g, '\n');
}

function renderInline(text: string): string {
  let escaped = escapeHtml(text);
  escaped = escaped.replace(/`([^`\n]+)`/g, (_m, code) => `<code class="rounded bg-white/10 px-1 py-0.5 font-mono text-[0.85em] text-zinc-100">${code}</code>`);
  escaped = escaped.replace(/\*\*\*([^*\n]+)\*\*\*/g, '<strong><em>$1</em></strong>');
  escaped = escaped.replace(/(^|[^A-Za-z0-9_])___([^_\n]+)___(?![A-Za-z0-9_])/g, '$1<strong><em>$2</em></strong>');
  escaped = escaped.replace(/\*\*([^*\n]+)\*\*/g, '<strong>$1</strong>');
  escaped = escaped.replace(/(^|[^A-Za-z0-9_])__([^_\n]+)__(?![A-Za-z0-9_])/g, '$1<strong>$2</strong>');
  escaped = escaped.replace(/(^|[^*])\*([^*\n]+)\*/g, '$1<em>$2</em>');
  escaped = escaped.replace(/(^|[^A-Za-z0-9_])_([^_\s](?:[^_\n]*?[^_\s])?)_(?![A-Za-z0-9_])/g, '$1<em>$2</em>');
  escaped = escaped.replace(/~~([^~\n]+)~~/g, '<del>$1</del>');
  escaped = escaped.replace(/\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/g, (_m, label, url) => (
    `<a href="${url}" target="_blank" rel="noreferrer" class="text-sky-300 underline decoration-sky-500/40 hover:decoration-sky-400">${label}</a>`
  ));
  escaped = escaped.replace(ARTIFACT_TOKEN_RE, (_m, prefix, _link, artifactId) => {
    // Initial visible text is the artifact ID (safe fallback). A React-side
    // effect asynchronously swaps in the resolved artifact name when available.
    const cachedName = artifactNameCache.get(artifactId) || '';
    const initialText = escapeHtml(cachedName || artifactId);
    return `${prefix}<button type="button" data-artifact-id="${artifactId}" data-artifact-link="true" data-debug-id="artifact-link-chip-${artifactId}" title="Open artifact" class="inline-flex items-center gap-1 rounded-full border border-sky-400/30 bg-sky-400/10 px-2.5 py-0.5 text-xs font-medium text-sky-200 hover:bg-sky-400/15"><span aria-hidden="true">\u{1F4CE}</span><span data-artifact-label="true">${initialText}</span></button>`;
  });
  escaped = escaped.replace(/(^|[^"'>])((?:https?:\/\/)[\w\-._~:\/?#\[\]@!$&'()*+,;=%]+[\w\-_~:\/?#\[\]@!$&'()*+;=%])/g, (_m, prefix, url) => {
    return `${prefix}<a href="${url}" target="_blank" rel="noreferrer" class="text-sky-300 underline decoration-sky-500/40 hover:decoration-sky-400">${url}</a>`;
  });
  return escaped;
}

function splitTableRow(line: string): string[] {
  let trimmed = line.trim();
  if (trimmed.startsWith('|')) trimmed = trimmed.slice(1);
  if (trimmed.endsWith('|')) trimmed = trimmed.slice(0, -1);
  const cells: string[] = [];
  let current = '';
  let escaped = false;
  for (const ch of trimmed) {
    if (escaped) {
      current += ch;
      escaped = false;
      continue;
    }
    if (ch === '\\') {
      escaped = true;
      continue;
    }
    if (ch === '|') {
      cells.push(current.trim());
      current = '';
    } else {
      current += ch;
    }
  }
  cells.push(current.trim());
  return cells;
}

function isTableSeparator(line: string): boolean {
  const cells = splitTableRow(line);
  return cells.length > 0 && cells.every((cell) => /^:?-{3,}:?$/.test(cell.trim()));
}

function isLikelyTableHeader(line: string, next?: string): boolean {
  return Boolean(next && line.includes('|') && isTableSeparator(next));
}

function renderTable(lines: string[], start: number): { html: string; nextIndex: number } {
  const headers = splitTableRow(lines[start]);
  const aligns = splitTableRow(lines[start + 1]).map((cell) => {
    const trimmed = cell.trim();
    if (trimmed.startsWith(':') && trimmed.endsWith(':')) return 'text-center';
    if (trimmed.endsWith(':')) return 'text-right';
    return 'text-left';
  });
  const rows: string[][] = [];
  let i = start + 2;
  while (i < lines.length && lines[i].trim() !== '' && lines[i].includes('|') && !/^```/.test(lines[i])) {
    rows.push(splitTableRow(lines[i]));
    i += 1;
  }
  const head = headers.map((cell, idx) => `<th class="border-b border-white/10 px-3 py-2 ${aligns[idx] || 'text-left'} font-semibold text-zinc-100">${renderInline(cell)}</th>`).join('');
  const body = rows.map((row) => `<tr>${headers.map((_h, idx) => `<td class="border-b border-white/5 px-3 py-2 align-top ${aligns[idx] || 'text-left'}">${renderInline(row[idx] || '')}</td>`).join('')}</tr>`).join('');
  return {
    html: `<div class="markdown-table my-2 overflow-hidden rounded-xl border border-white/10"><div class="flex items-center justify-between border-b border-white/10 bg-white/[0.03] px-3 py-1.5 text-[11px] text-zinc-500"><span>table</span><button type="button" data-markdown-copy-table="true" class="rounded-md bg-white/10 px-2 py-1 text-xs text-zinc-200 opacity-80 hover:bg-white/15 hover:opacity-100">Copy CSV</button></div><div class="overflow-x-auto"><table class="min-w-full border-collapse text-left text-sm"><thead class="bg-white/[0.04]"><tr>${head}</tr></thead><tbody>${body}</tbody></table></div></div>`,
    nextIndex: i,
  };
}

function renderBlocks(source: string): string {
  const lines = normalizeMarkdownSource(source).replace(/\r\n?/g, '\n').split('\n');
  const out: string[] = [];
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    const fence = line.match(/^```([\w+-]*)\s*$/);
    if (fence) {
      const lang = fence[1] || '';
      const body: string[] = [];
      i += 1;
      while (i < lines.length && !/^```\s*$/.test(lines[i])) {
        body.push(lines[i]);
        i += 1;
      }
      if (i < lines.length) i += 1;
      const escapedCode = escapeHtml(body.join('\n'));
      const langLabel = escapeHtml(lang || 'code');
      if (/^(?:mermaid|mermedai)$/i.test((lang || '').trim())) {
        out.push(`<div class="group my-2 overflow-hidden rounded-xl border border-white/10 bg-black/40 mermaid-block" data-mermaid-code="${escapedCode}"><div class="flex items-center justify-between border-b border-white/10 px-3 py-1.5 text-[11px] text-zinc-500"><span class="font-mono">mermaid</span><button type="button" data-markdown-copy-code="true" data-debug-id="markdown-copy-code-btn" class="rounded-md bg-white/10 px-2 py-1 text-xs text-zinc-200 opacity-80 hover:bg-white/15 hover:opacity-100">Copy</button></div><div class="mermaid-diagram-container p-3 overflow-x-auto flex flex-col items-center justify-center bg-black/20" data-mermaid-rendered="false"><pre class="font-mono text-[12px] leading-relaxed text-zinc-100 text-left w-full" data-lang="mermaid"><code>${escapedCode}</code></pre></div></div>`);
        continue;
      }
      out.push(`<div class="group my-2 overflow-hidden rounded-xl border border-white/10 bg-black/40"><div class="flex items-center justify-between border-b border-white/10 px-3 py-1.5 text-[11px] text-zinc-500"><span class="font-mono">${langLabel}</span><button type="button" data-markdown-copy-code="true" data-debug-id="markdown-copy-code-btn" class="rounded-md bg-white/10 px-2 py-1 text-xs text-zinc-200 opacity-80 hover:bg-white/15 hover:opacity-100">Copy</button></div><pre class="overflow-x-auto p-3 font-mono text-[12px] leading-relaxed text-zinc-100" data-lang="${escapeHtml(lang)}"><code>${escapedCode}</code></pre></div>`);
      continue;
    }
    if (line.trim() === '') { i += 1; continue; }
    const heading = line.match(/^(#{1,6})\s+(.+?)\s*#*$/);
    if (heading) {
      const level = heading[1].length;
      const tag = `h${Math.min(6, level + 2)}`;
      out.push(`<${tag} class="mt-2 font-semibold text-zinc-100">${renderInline(heading[2])}</${tag}>`);
      i += 1;
      continue;
    }
    if (isLikelyTableHeader(line, lines[i + 1])) {
      const table = renderTable(lines, i);
      out.push(table.html);
      i = table.nextIndex;
      continue;
    }
    if (line.startsWith('> ')) {
      const quote: string[] = [];
      while (i < lines.length && lines[i].startsWith('> ')) {
        quote.push(lines[i].slice(2));
        i += 1;
      }
      out.push(`<blockquote class="my-1 border-l-2 border-sky-400/40 pl-3 text-zinc-300">${renderInline(quote.join(' '))}</blockquote>`);
      continue;
    }
    if (/^[-*+]\s+/.test(line)) {
      const items: string[] = [];
      while (i < lines.length && /^[-*+]\s+/.test(lines[i])) {
        items.push(`<li>${renderInline(lines[i].replace(/^[-*+]\s+/, ''))}</li>`);
        i += 1;
      }
      out.push(`<ul class="my-1 list-disc space-y-0.5 pl-5">${items.join('')}</ul>`);
      continue;
    }
    if (/^\d+\.\s+/.test(line)) {
      const items: string[] = [];
      while (i < lines.length && /^\d+\.\s+/.test(lines[i])) {
        items.push(`<li>${renderInline(lines[i].replace(/^\d+\.\s+/, ''))}</li>`);
        i += 1;
      }
      out.push(`<ol class="my-1 list-decimal space-y-0.5 pl-5">${items.join('')}</ol>`);
      continue;
    }
    if (/^(---|\*\*\*|___)\s*$/.test(line)) {
      out.push('<hr class="my-2 border-white/10" />');
      i += 1;
      continue;
    }
    const paragraph: string[] = [line];
    i += 1;
    while (i < lines.length && lines[i].trim() !== '' && !isLikelyTableHeader(lines[i], lines[i + 1]) && !/^(?:#{1,6}\s+|>\s+|[-*+]\s+|\d+\.\s+|```)/.test(lines[i])) {
      paragraph.push(lines[i]);
      i += 1;
    }
    out.push(`<p class="my-1 leading-relaxed">${paragraph.map((chunk) => renderInline(chunk)).join('<br />')}</p>`);
  }
  return out.join('');
}

export function renderMarkdown(source: string, copyAll = true): string {
  if (!source) return '';
  const raw = normalizeMarkdownSource(source);
  if (!raw.trim()) return '';
  if (!copyAll) return renderBlocks(source);
  const escapedSource = escapeHtml(raw);
  const copyBtn = `<div class="mb-1 flex items-center justify-end"><button type="button" data-markdown-copy-all="true" data-debug-id="markdown-copy-all-btn" data-markdown-source="${escapedSource}" title="Copy entire markdown" class="inline-flex h-6 w-6 items-center justify-center rounded-md border border-white/10 bg-white/5 text-zinc-400 opacity-60 transition hover:bg-white/15 hover:text-zinc-100 hover:opacity-100"><span aria-hidden="true" class="text-xs">\u{1F4CB}</span></button></div>`;
  return copyBtn + renderBlocks(source);
}

function csvEscape(value: string): string {
  const normalized = String(value || '').replace(/\r?\n/g, ' ').trim();
  if (/[",\n]/.test(normalized)) return `"${normalized.replace(/"/g, '""')}"`;
  return normalized;
}

function tableToCsv(table: HTMLTableElement): string {
  return Array.from(table.querySelectorAll('tr')).map((row) => (
    Array.from(row.querySelectorAll('th,td')).map((cell) => csvEscape(cell.textContent || '')).join(',')
  )).join('\n');
}

function readMarkdownSelection(root: HTMLElement): MarkdownTextSelection | null {
  const selection = window.getSelection?.() || document.getSelection?.();
  if (!selection || selection.rangeCount === 0 || selection.isCollapsed) return null;
  const range = selection.getRangeAt(0);
  const commonAncestor = range.commonAncestorContainer;
  if (!root.contains(commonAncestor)) return null;
  if (selection.anchorNode && !root.contains(selection.anchorNode)) return null;
  if (selection.focusNode && !root.contains(selection.focusNode)) return null;
  const selectedText = selection.toString().replace(/\s+/g, ' ').trim();
  if (!selectedText) return null;
  return { selectedText };
}

export default function MarkdownBody({ source, className, compact, copyAll = true, 'data-debug-id': dataDebugId, onArtifactClick, onTextSelectionChange }: MarkdownBodyProps) {
  const rootRef = useRef<HTMLDivElement | null>(null);
  const html = useMemo(() => renderMarkdown(source || '', copyAll), [source, copyAll]);
  const spacing = compact ? 'space-y-1' : 'space-y-2';
  const session = useSelector((state: any) => state.chat?.session || {});
  const daemonUrl = session?.daemonUrl || '';
  const clientToken = session?.clientToken || '';

  // Resolve artifact names from metadata and swap them into the rendered chips.
  // Uses textContent (auto-escaped) so no untrusted HTML is injected, and keeps
  // an ID fallback when metadata is unavailable or not yet loaded (UIART-5).
  useEffect(() => {
    const root = rootRef.current;
    if (!root) return undefined;
    const chips = Array.from(root.querySelectorAll('[data-artifact-id]')) as HTMLElement[];
    if (chips.length === 0) return undefined;
    let cancelled = false;
    const applyName = (artifactId: string, name: string) => {
      if (cancelled || !name) return;
      const nodes = Array.from(root.querySelectorAll(`[data-artifact-id="${artifactId}"]`)) as HTMLElement[];
      nodes.forEach((node) => {
        const label = node.querySelector('[data-artifact-label="true"]') as HTMLElement | null;
        if (label) label.textContent = name;
      });
    };
    chips.forEach((chip) => {
      const artifactId = chip.getAttribute('data-artifact-id') || '';
      if (!artifactId) return;
      const cachedName = artifactNameCache.get(artifactId);
      if (cachedName) { applyName(artifactId, cachedName); return; }
      if (!daemonUrl || !clientToken) return; // leave ID fallback in place
      let pending = artifactNamePending.get(artifactId);
      if (!pending) {
        pending = daemonApi.fetchArtifactMeta({ daemonUrl, clientToken, artifactId })
          .then((data: any) => {
            const name = String(data?.artifact?.name || '');
            if (name) artifactNameCache.set(artifactId, name);
            return name;
          })
          .catch(() => '')
          .finally(() => { artifactNamePending.delete(artifactId); });
        artifactNamePending.set(artifactId, pending);
      }
      pending.then((name) => applyName(artifactId, name));
    });
    return () => { cancelled = true; };
  }, [html, daemonUrl, clientToken]);

  useEffect(() => {
    const root = rootRef.current;
    if (!root) return undefined;
    const containers = Array.from(root.querySelectorAll('.mermaid-block [data-mermaid-rendered="false"]')) as HTMLElement[];
    if (containers.length === 0) return undefined;

    let cancelled = false;
    ensureMermaidInitialized();

    containers.forEach(async (container, idx) => {
      if (cancelled) return;
      const block = container.closest('.mermaid-block') as HTMLElement | null;
      const code = block?.getAttribute('data-mermaid-code') || container.textContent || '';
      if (!code.trim()) return;

      const uniqueId = `mermaid-svg-${Date.now()}-${idx}-${Math.random().toString(36).substring(2, 8)}`;
      try {
        const { svg, bindFunctions } = await mermaid.render(uniqueId, code);
        if (cancelled) return;
        container.innerHTML = svg;
        container.setAttribute('data-mermaid-rendered', 'true');
        if (bindFunctions && typeof bindFunctions === 'function') {
          bindFunctions(container);
        }
      } catch (err) {
        if (cancelled) return;
        console.warn('Mermaid rendering failed:', err);
        container.setAttribute('data-mermaid-rendered', 'error');
        const tempEl = document.getElementById(`d${uniqueId}`) || document.getElementById(uniqueId);
        if (tempEl && tempEl.parentNode) {
          tempEl.parentNode.removeChild(tempEl);
        }
        const errorBanner = document.createElement('div');
        errorBanner.className = 'mb-2 rounded bg-rose-500/10 border border-rose-500/30 px-2 py-1 text-[11px] text-rose-300';
        errorBanner.textContent = 'Failed to render Mermaid diagram';
        if (!container.querySelector('.text-rose-300')) {
          container.insertBefore(errorBanner, container.firstChild);
        }
      }
    });

    return () => {
      cancelled = true;
    };
  }, [html]);

  useEffect(() => {
    const root = rootRef.current;
    if (!root) return undefined;
    const onClick = async (event: MouseEvent) => {
      const target = event.target as HTMLElement | null;
      const artifactButton = target?.closest?.('[data-artifact-id]') as HTMLButtonElement | null;
      if (artifactButton) {
        const artifactId = String(artifactButton.getAttribute('data-artifact-id') || '');
        if (artifactId && onArtifactClick) onArtifactClick(artifactId);
        return;
      }
      const button = target?.closest?.('[data-markdown-copy-code="true"],[data-markdown-copy-table="true"],[data-markdown-copy-all="true"]') as HTMLButtonElement | null;
      if (!button) return;
      let text = '';
      if (button.matches('[data-markdown-copy-all="true"]')) {
        text = button.getAttribute('data-markdown-source') || normalizeMarkdownSource(source || '');
      } else if (button.matches('[data-markdown-copy-code="true"]')) {
        const wrapper = button.closest('.group');
        text = wrapper?.getAttribute('data-mermaid-code') || wrapper?.querySelector('pre code')?.textContent || '';
      } else {
        const wrapper = button.closest('.markdown-table');
        const table = wrapper?.querySelector('table') as HTMLTableElement | null;
        text = table ? tableToCsv(table) : '';
      }
      if (!text) return;
      await navigator.clipboard?.writeText(text).catch(() => undefined);
      if (button.matches('[data-markdown-copy-all="true"]')) {
        const iconSpan = button.querySelector('span') || button;
        const prevText = iconSpan.textContent || '\u{1F4CB}';
        const prevTitle = button.getAttribute('title') || 'Copy entire markdown';
        iconSpan.textContent = '\u{2713}';
        button.setAttribute('title', 'Copied!');
        window.setTimeout(() => {
          iconSpan.textContent = prevText;
          button.setAttribute('title', prevTitle);
        }, 1200);
        return;
      }
      const previous = button.getAttribute('data-original-text') || button.textContent || 'Copy';
      if (!button.getAttribute('data-original-text')) {
        button.setAttribute('data-original-text', previous);
      }
      button.textContent = 'Copied';
      window.setTimeout(() => { button.textContent = previous; }, 1200);
    };
    root.addEventListener('click', onClick);
    return () => root.removeEventListener('click', onClick);
  }, [html, source, onArtifactClick]);

  useEffect(() => {
    const root = rootRef.current;
    if (!root || !onTextSelectionChange) return undefined;
    const emitSelection = () => onTextSelectionChange(readMarkdownSelection(root));
    root.addEventListener('mouseup', emitSelection);
    root.addEventListener('keyup', emitSelection);
    return () => {
      root.removeEventListener('mouseup', emitSelection);
      root.removeEventListener('keyup', emitSelection);
    };
  }, [html, onTextSelectionChange]);

  return (
    <div
      ref={rootRef}
      data-debug-id={dataDebugId}
      className={`markdown ${spacing} text-sm text-zinc-200 ${className || ''}`}
      dangerouslySetInnerHTML={{ __html: html }}
    />
  );
}
