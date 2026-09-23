// REQ-LSP-ENV-1: the surface where a language server's own complaint becomes
// something a human actually sees.
//
// WHY THIS IS ITS OWN COMPONENT AND NOT INLINE JSX IN ProjectFilesPanel.
// This whole task exists because a message reached the render path and no user
// ever saw it. While fixing it, two MORE surfaces in this codebase turned out to
// have the same shape:
//   - useMonacoLsp's return value was computed every render and discarded, because
//     ProjectFilesPanel called the hook as a bare statement.
//   - ToastViewport.tsx is mounted nowhere, while four call sites dispatch into
//     its Redux queue (filed as REQ-UI-TOAST-1).
// So "the code path reaches a render call" does NOT imply "a human sees it" here,
// and a typecheck-green, unit-test-green banner buried in a 4000-line component
// would be the third instance of exactly that. Pulling it out gives the banner a
// seam it can be MOUNTED AND PHOTOGRAPHED through, independently of the panel's
// store, monaco namespace and RTK Query wiring — which is how the on-screen proof
// for this task was actually obtained. Same instinct as lspSessionKey.ts: move
// the thing that must be verified to where it CAN be verified.
//
// Rendering rules that are load-bearing, not cosmetic:
//   - THE TEXT MUST NOT TRUNCATE. gopls' actual sentence is
//     "Error loading packages: go command required, not found: exec: \"go\":
//      executable file not found in $PATH"
//     and the only part worth showing is the end of it. The toolbar's existing
//     save-feedback chip is `truncate max-w-[120px]`, which renders that as
//     "Error loading pac…" — a notification that names nothing actionable. This
//     banner is full-width and wraps for that reason.
//   - Info renders at LOWER weight than an error. The show channel is admitted
//     down to Info (see lspServerNotice.ts for why severity is not the gate), so
//     an info notice must inform without alarming.

import { Icon } from '@ui';

import type { LspServerNotice } from './lspServerNotice';

export type LspNoticeBannerProps = {
  /** Null on a healthy session — the component renders nothing. */
  notice: LspServerNotice | null;
  onDismiss: () => void;
  /** Prefix for data-debug-id, matching the host panel's convention. */
  debugPrefix?: string;
};

const TONE: Record<LspServerNotice['level'], string> = {
  error: 'border-danger/30 bg-danger-soft text-danger',
  warning: 'border-warning/30 bg-warning-soft text-warning',
  info: 'border-subtle bg-surface-raised text-muted',
};

export function LspNoticeBanner({ notice, onDismiss, debugPrefix = 'files' }: LspNoticeBannerProps) {
  if (!notice) return null;

  return (
    <div
      data-debug-id={`${debugPrefix}-lsp-notice`}
      // An error is assertive so a screen reader interrupts; anything softer is
      // polite. Matches how the notice is rendered visually.
      role={notice.level === 'error' ? 'alert' : 'status'}
      className={`flex shrink-0 items-start gap-2 border-b px-3 py-2 text-[11px] ${TONE[notice.level]}`}
    >
      <Icon name="alert" size={12} className="mt-px shrink-0" />
      <div className="min-w-0 flex-1">
        <span className="font-medium">Language server: </span>
        {/* break-words, NEVER truncate — see the note in this file's header. */}
        <span className="break-words">{notice.text}</span>
      </div>
      <button
        data-debug-id={`${debugPrefix}-lsp-notice-dismiss`}
        type="button"
        onClick={onDismiss}
        title="Dismiss"
        aria-label="Dismiss language server message"
        className="shrink-0 rounded px-1 font-medium opacity-70 hover:opacity-100"
      >
        ✕
      </button>
    </div>
  );
}

export default LspNoticeBanner;
