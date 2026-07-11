import { useEffect, useMemo, useRef } from 'react';

// Minimal, dependency-free markdown renderer used for chat messages,
// task descriptions, and task comments. Focused on what agents actually
// send: headings, bold/italic/code, inline links, ordered/unordered lists,
// blockquotes, and fenced code blocks. Everything else falls through as
// plain text so untrusted input can never inject HTML.

type MarkdownProps = {
  source: string;
  className?: string;
  compact?: boolean;
  'data-debug-id'?: string;
};

function escapeHtml(value: string): string {
  return value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function normalizeMarkdownSource(source: string): string {
  // Some agent/chat paths hand the UI an already-escaped body, so literal
  // backslash-n sequences appear as "\\n\\n" instead of line breaks.
  return String(source || '').replace(/\\n/g, '\n');
}

function renderInline(text: string): string {
  let escaped = escapeHtml(text);

  // Inline code — captured before other transforms so their markers stay literal inside.
  escaped = escaped.replace(/`([^`\n]+)`/g, (_m, code) => `<code class="rounded bg-white/10 px-1 py-0.5 font-mono text-[0.85em] text-zinc-100">${code}</code>`);

  // Bold + italic combinations.
  escaped = escaped.replace(/\*\*\*([^*\n]+)\*\*\*/g, '<strong><em>$1</em></strong>');
  escaped = escaped.replace(/(^|[^A-Za-z0-9_])___([^_\n]+)___(?![A-Za-z0-9_])/g, '$1<strong><em>$2</em></strong>');
  escaped = escaped.replace(/\*\*([^*\n]+)\*\*/g, '<strong>$1</strong>');
  escaped = escaped.replace(/(^|[^A-Za-z0-9_])__([^_\n]+)__(?![A-Za-z0-9_])/g, '$1<strong>$2</strong>');
  escaped = escaped.replace(/(^|[^*])\*([^*\n]+)\*/g, '$1<em>$2</em>');
  escaped = escaped.replace(/(^|[^A-Za-z0-9_])_([^_\s](?:[^_\n]*?[^_\s])?)_(?![A-Za-z0-9_])/g, '$1<em>$2</em>');

  // Strikethrough.
  escaped = escaped.replace(/~~([^~\n]+)~~/g, '<del>$1</del>');

  // Explicit markdown links [label](url) — only http(s) allowed to keep xss-safe.
  escaped = escaped.replace(/\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/g, (_m, label, url) => (
    `<a href="${url}" target="_blank" rel="noreferrer" class="text-sky-300 underline decoration-sky-500/40 hover:decoration-sky-400">${label}</a>`
  ));
  // Autolink bare http(s) URLs that were not already turned into anchors.
  escaped = escaped.replace(/(^|[^"'>])((?:https?:\/\/)[\w\-._~:\/?#\[\]@!$&'()*+,;=%]+[\w\-_~:\/?#\[\]@!$&'()*+;=%])/g, (_m, prefix, url) => {
    // avoid double wrapping if this url appears inside an existing anchor
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

    // Fenced code block.
    const fence = line.match(/^```([\w+-]*)\s*$/);
    if (fence) {
      const lang = fence[1] || '';
      const body: string[] = [];
      i += 1;
      while (i < lines.length && !/^```\s*$/.test(lines[i])) {
        body.push(lines[i]);
        i += 1;
      }
      if (i < lines.length) i += 1; // consume closing fence
      const escapedCode = escapeHtml(body.join('\n'));
      const langLabel = escapeHtml(lang || 'code');
      out.push(
        `<div class="group my-2 overflow-hidden rounded-xl border border-white/10 bg-black/40"><div class="flex items-center justify-between border-b border-white/10 px-3 py-1.5 text-[11px] text-zinc-500"><span class="font-mono">${langLabel}</span><button type="button" data-markdown-copy-code="true" class="rounded-md bg-white/10 px-2 py-1 text-xs text-zinc-200 opacity-80 hover:bg-white/15 hover:opacity-100">Copy</button></div><pre class="overflow-x-auto p-3 font-mono text-[12px] leading-relaxed text-zinc-100" data-lang="${escapeHtml(lang)}"><code>${escapedCode}</code></pre></div>`
      );
      continue;
    }

    // Blank line.
    if (line.trim() === '') { i += 1; continue; }

    // Heading.
    const heading = line.match(/^(#{1,6})\s+(.+?)\s*#*$/);
    if (heading) {
      const level = heading[1].length;
      const tag = `h${Math.min(6, level + 2)}`; // demote so h1 renders like h3
      out.push(`<${tag} class="mt-2 font-semibold text-zinc-100">${renderInline(heading[2])}</${tag}>`);
      i += 1;
      continue;
    }

    // GitHub-style pipe table.
    if (isLikelyTableHeader(line, lines[i + 1])) {
      const table = renderTable(lines, i);
      out.push(table.html);
      i = table.nextIndex;
      continue;
    }

    // Blockquote.
    if (line.startsWith('> ')) {
      const quote: string[] = [];
      while (i < lines.length && lines[i].startsWith('> ')) {
        quote.push(lines[i].slice(2));
        i += 1;
      }
      out.push(`<blockquote class="my-1 border-l-2 border-sky-400/40 pl-3 text-zinc-300">${renderInline(quote.join(' '))}</blockquote>`);
      continue;
    }

    // Unordered list.
    if (/^[-*+]\s+/.test(line)) {
      const items: string[] = [];
      while (i < lines.length && /^[-*+]\s+/.test(lines[i])) {
        items.push(`<li>${renderInline(lines[i].replace(/^[-*+]\s+/, ''))}</li>`);
        i += 1;
      }
      out.push(`<ul class="my-1 list-disc space-y-0.5 pl-5">${items.join('')}</ul>`);
      continue;
    }

    // Ordered list.
    if (/^\d+\.\s+/.test(line)) {
      const items: string[] = [];
      while (i < lines.length && /^\d+\.\s+/.test(lines[i])) {
        items.push(`<li>${renderInline(lines[i].replace(/^\d+\.\s+/, ''))}</li>`);
        i += 1;
      }
      out.push(`<ol class="my-1 list-decimal space-y-0.5 pl-5">${items.join('')}</ol>`);
      continue;
    }

    // Horizontal rule.
    if (/^(---|\*\*\*|___)\s*$/.test(line)) {
      out.push('<hr class="my-2 border-white/10" />');
      i += 1;
      continue;
    }

    // Paragraph — accumulate consecutive non-empty lines and use soft line breaks.
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

export function renderMarkdown(source: string): string {
  if (!source) return '';
  return renderBlocks(source);
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

export default function Markdown({ source, className, compact, 'data-debug-id': dataDebugId }: MarkdownProps) {
  const rootRef = useRef<HTMLDivElement | null>(null);
  const html = useMemo(() => renderMarkdown(source || ''), [source]);
  const spacing = compact ? 'space-y-1' : 'space-y-2';
  useEffect(() => {
    const root = rootRef.current;
    if (!root) return undefined;
    const onClick = async (event: MouseEvent) => {
      const target = event.target as HTMLElement | null;
      const button = target?.closest?.('[data-markdown-copy-code="true"],[data-markdown-copy-table="true"]') as HTMLButtonElement | null;
      if (!button) return;
      let text = '';
      if (button.matches('[data-markdown-copy-code="true"]')) {
        const wrapper = button.closest('.group');
        text = wrapper?.querySelector('pre code')?.textContent || '';
      } else {
        const wrapper = button.closest('.markdown-table');
        const table = wrapper?.querySelector('table') as HTMLTableElement | null;
        text = table ? tableToCsv(table) : '';
      }
      if (!text) return;
      await navigator.clipboard?.writeText(text).catch(() => undefined);
      const previous = button.textContent || 'Copy';
      button.textContent = 'Copied';
      window.setTimeout(() => { button.textContent = previous; }, 1200);
    };
    root.addEventListener('click', onClick);
    return () => root.removeEventListener('click', onClick);
  }, [html]);
  return (
    <div
      ref={rootRef}
      data-debug-id={dataDebugId}
      className={`markdown ${spacing} text-sm text-zinc-200 ${className || ''}`}
      // eslint-disable-next-line react/no-danger -- content is escaped in renderInline/renderBlocks before being wrapped in safe tag templates
      dangerouslySetInnerHTML={{ __html: html }}
    />
  );
}
