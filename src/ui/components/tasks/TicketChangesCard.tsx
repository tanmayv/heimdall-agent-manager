// origin/main's Changes card behind a props seam: the caller reads an
// attempt's changes (files, output, head) when the card opens or another
// attempt is picked, and may offer a per-file diff. A Bridge-owned chain
// supplies its attempt submissions (summary, head, author); it records no
// per-file changes, so no file list or diff shows for it.

import React, { useEffect, useState } from 'react';
import { Button, Icon, Text } from '@ui';
import { DecryptedMarkdown } from '../vault';
import type { TaskChangedFile } from './taskV2Types';

/** One attempt's changes, as read. */
export interface TicketAttemptChanges {
  attempt: number;
  files: TaskChangedFile[];
  /** What the attempt produced (its handoff / submission summary). */
  output?: string;
  head?: string;
  author?: string;
}

export interface TicketChangesProps {
  /** The ticket's current attempt (shown first). */
  attemptNo: number;
  /** The attempt shown, null until read. */
  changes: TicketAttemptChanges | null;
  loading?: boolean;
  error?: string;
  /** Read this attempt's changes (on open, and when another attempt is picked). */
  onLoad: (attempt: number) => void;
  /** Present: earlier attempts can be picked. */
  attempts?: number[];
  /** Open the card on this attempt (a deep link to a submission). */
  focusAttempt?: number | null;
  /** Present: a changed file opens its diff. */
  loadDiff?: (path: string) => Promise<string>;
}

/* Changes and output (read on first open) ---------------------------- */

export function TicketChangesCard({ attemptNo, changes, loading = false, error = '', onLoad, attempts, focusAttempt, loadDiff }: TicketChangesProps) {
  const [open, setOpen] = useState(Boolean(focusAttempt));
  const [attempt, setAttempt] = useState(focusAttempt || attemptNo || 1);
  const [diffFile, setDiffFile] = useState<string | null>(null);
  const [diff, setDiff] = useState<{ path: string; text: string; failed: boolean } | null>(null);

  useEffect(() => {
    if (!focusAttempt) return;
    setOpen(true);
    setAttempt(focusAttempt);
  }, [focusAttempt]);
  // The current attempt moves on (a new submission): follow it unless another was picked.
  useEffect(() => { if (!focusAttempt) setAttempt(attemptNo || 1); }, [attemptNo]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => {
    if (open) onLoad(attempt);
    setDiffFile(null);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, attempt]);
  useEffect(() => {
    if (!diffFile || !loadDiff) return;
    let live = true;
    setDiff(null);
    loadDiff(diffFile).then((text) => live && setDiff({ path: diffFile, text, failed: false })).catch(() => live && setDiff({ path: diffFile, text: '', failed: true }));
    return () => { live = false; };
  }, [diffFile, loadDiff]);

  const shown = changes && changes.attempt === attempt ? changes : null;
  const files = shown?.files ?? [];
  return (
    <section data-debug-id="task-details-changes" className="flex flex-col gap-2">
      <button
        type="button"
        aria-expanded={open}
        onClick={() => setOpen((o) => !o)}
        data-debug-id="ticket-view-changes-toggle"
        className="flex min-h-11 items-center gap-2 self-start rounded-sm text-left focus-visible:outline-none focus-visible:shadow-focus"
      >
        <Icon name={open ? 'chevron-down' : 'chevron-right'} size={14} className="text-muted" />
        <Text as="span" role="title" className="text-primary">Changes</Text>
        {open && files.length > 0 && <Text as="span" role="caption" tone="faint">{files.length} files</Text>}
      </button>
      {open && (
        <div className="flex flex-col gap-2">
          {attempts && attempts.length > 1 && (
            <ul className="flex flex-wrap gap-1.5" aria-label="Attempts">
              {attempts.map((n) => (
                <li key={n}>
                  <Button size="sm" variant={n === attempt ? 'primary' : 'secondary'} aria-pressed={n === attempt} onClick={() => setAttempt(n)} data-debug-id={`ticket-view-changes-attempt-${n}`}>
                    Attempt {n}
                  </Button>
                </li>
              ))}
            </ul>
          )}
          {error && <Text role="caption" tone="danger">{error}</Text>}
          {!error && (loading || !shown) && <Text role="caption" tone="faint" aria-live="polite">Loading changes…</Text>}
          {shown && !loading && files.length === 0 && !shown.output && <Text role="caption" tone="faint">No file changes recorded for attempt {attempt}.</Text>}
          {files.length > 0 && (
            <ul className="divide-y divide-subtle overflow-hidden rounded-lg border border-subtle bg-surface">
              {files.map(({ path, add, del }) => (
                <li key={path}>
                  <button
                    type="button"
                    aria-expanded={loadDiff ? diffFile === path : undefined}
                    disabled={!loadDiff}
                    onClick={() => setDiffFile(diffFile === path ? null : path)}
                    data-debug-id={`ticket-view-changed-file-${path}`}
                    className="flex min-h-11 w-full min-w-0 items-center gap-2 px-3 py-2 text-left enabled:hover:bg-surface-raised focus-visible:outline-none focus-visible:shadow-focus disabled:cursor-default"
                  >
                    <span className="min-w-0 flex-1 truncate font-mono text-code-sm text-primary">{path}</span>
                    {typeof add === 'number' && typeof del === 'number' && (
                      <span className="shrink-0 font-mono text-code-sm"><span className="text-success">+{add}</span> <span className="text-danger">-{del}</span></span>
                    )}
                  </button>
                  {diffFile === path && (
                    <pre className="max-h-80 overflow-auto bg-canvas p-3 font-mono text-code-sm text-primary">
                      {diff?.path === path ? (diff.failed ? 'Could not load this diff.' : diff.text) : 'Loading diff…'}
                    </pre>
                  )}
                </li>
              ))}
            </ul>
          )}
          {shown?.output && (
            <div data-debug-id="task-details-output" className="flex flex-col gap-1">
              <Text as="span" role="overline" tone="faint">Output</Text>
              {(shown.author || shown.head) && (
                <Text as="span" role="caption" tone="muted" data-debug-id="task-details-output-meta">
                  Attempt {shown.attempt}{shown.author ? ` · by ${shown.author}` : ''}{shown.head ? <> · head <Text as="code" role="code-sm">{shown.head.slice(0, 12)}</Text></> : null}
                </Text>
              )}
              <DecryptedMarkdown source={shown.output} compact copyAll={false} />
            </div>
          )}
        </div>
      )}
    </section>
  );
}
