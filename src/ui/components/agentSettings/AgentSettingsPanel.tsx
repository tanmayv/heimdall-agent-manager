/**
 * AgentSettingsPanel — the Agent settings inspector beside the conversation.
 * Rationale and layout rules: ./DESIGN.md.
 *
 * Hosted by AgentChatPane as a flex sibling of the transcript (not an AuxDock tab):
 *   - docked  (>= 1280px): a 400px (max 440px) column with a left border;
 *   - drawer  (< 1280px):  the same column in the @ui Drawer (modal: focus trap,
 *     Esc and backdrop close, focus restored to the gear);
 *   - page    (< 768px):   a full-screen Drawer page with a 44px back button.
 *
 * Sections, top to bottom: Runtime (T5), then the slots for Runs on / Model /
 * Connection / Permissions (T6) and the staged-changes footer (T7). The panel owns
 * only the frame; the pane passes each section in.
 */
import React, { useEffect, useId, useState } from 'react';
import { Drawer, IconButton, Text } from '@ui';
import type { AgentSettingsPanelState } from './useAgentSettingsPanelState';

/** Fallback unmount delay for the docked panel slide-out when no `transitionend` arrives. */
export const AGENT_PANEL_DOCK_EXIT_FALLBACK_MS = 240;

export interface AgentSettingsPanelProps {
  state: Pick<AgentSettingsPanelState, 'open' | 'mode' | 'setOpen' | 'headingRef'> &
    Partial<Pick<AgentSettingsPanelState, 'gearRef'>>;
  /** "<agent name> #<n>", e.g. "coordinator #41". */
  agentLabel: React.ReactNode;
  /** The project name (may be a VaultText). Omitted from the subtitle when absent. */
  projectLabel?: React.ReactNode;
  /** Measured width of the fixed workspace chrome over the header's right edge. */
  closeRightInset?: number;
  /** Section 1: <RuntimeSection/>. */
  runtime: React.ReactNode;
  /** Sections 2-5 (T6). */
  children?: React.ReactNode;
  /** Sticky staged-changes footer (T7). */
  footer?: React.ReactNode;
}

export function AgentSettingsPanel({ state, agentLabel, projectLabel, closeRightInset, runtime, children, footer }: AgentSettingsPanelProps) {
  const headingId = useId();
  const { mode, open } = state;
  const isDocked = mode === 'docked';

  // Keep the docked panel mounted while its width slides back to 0, then unmount
  // so closed panels hold no hidden focusable nodes. Derived during render (matching
  // Drawer) to avoid a one-frame unmount/remount gap. Under prefers-reduced-motion
  // the CSS transition is disabled, so unmount immediately.
  const prefersReducedMotion =
    typeof window !== 'undefined' &&
    typeof window.matchMedia === 'function' &&
    window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  const [dockedClosing, setDockedClosing] = useState(false);
  const [prevDockedOpen, setPrevDockedOpen] = useState(isDocked && open);
  const dockedOpen = isDocked && open;
  if (prevDockedOpen !== dockedOpen) {
    setPrevDockedOpen(dockedOpen);
    setDockedClosing(!dockedOpen && isDocked && !prefersReducedMotion);
  } else if (!isDocked && dockedClosing) {
    setDockedClosing(false);
  }
  useEffect(() => {
    if (!dockedClosing) return;
    const timer = setTimeout(() => setDockedClosing(false), AGENT_PANEL_DOCK_EXIT_FALLBACK_MS);
    return () => clearTimeout(timer);
  }, [dockedClosing]);

  const close = () => state.setOpen(false);
  const subtitle = (
    <>
      {agentLabel}
      {projectLabel ? <> · {projectLabel}</> : null}
    </>
  );

  const header =
    mode === 'page' ? (
      <header
        data-debug-id="agent-panel-header"
        className="flex min-h-14 shrink-0 items-center gap-2 border-b border-subtle px-2 py-2"
      >
        <IconButton
          icon="chevron-left"
          label="Back to the conversation"
          size="md"
          data-debug-id="agent-panel-back"
          onClick={close}
        />
        <div className="min-w-0 flex-1">
          <Text
            as="h2"
            role="title"
            id={headingId}
            ref={state.headingRef}
            tabIndex={-1}
            className="truncate outline-none"
          >
            Agent settings
          </Text>
          <Text role="body-sm" tone="muted" className="truncate" data-debug-id="agent-panel-subtitle">
            {subtitle}
          </Text>
        </div>
      </header>
    ) : (
      <header
        data-debug-id="agent-panel-header"
        className="flex h-12 shrink-0 items-center justify-between gap-2 border-b border-subtle pl-4 pr-2"
      >
        <Text
          as="h2"
          role="heading"
          id={headingId}
          ref={state.headingRef}
          tabIndex={-1}
          className="min-w-0 truncate font-[family-name:var(--font-display)] outline-none"
        >
          Agent
        </Text>
        <IconButton
          icon="close"
          label="Close agent settings"
          size="sm"
          data-debug-id="agent-panel-close"
          className="shrink-0"
          style={closeRightInset ? { marginRight: closeRightInset } : undefined}
          onClick={close}
        />
      </header>
    );

  const aside = (
    <aside
      data-debug-id="agent-panel"
      data-mode={mode}
      data-state={open ? 'open' : 'closing'}
      aria-labelledby={headingId}
      aria-hidden={open ? undefined : true}
      className={
        isDocked
          ? 'flex h-full min-h-0 w-[400px] min-w-[400px] flex-col bg-surface text-primary'
          : 'flex h-full min-h-0 w-full flex-col bg-surface text-primary'
      }
    >
      {header}
      {/* scroll-py-4: scrollIntoView keeps the 16px panel padding (the ACP alert clears the footer). */}
      <div className="chat-scrollbar flex min-h-0 flex-1 scroll-py-4 flex-col gap-6 overflow-y-auto p-4">
        {mode !== 'page' ? (
          <Text role="body-sm" tone="muted" className="-mb-3 shrink-0 truncate" data-debug-id="agent-panel-subtitle">
            {subtitle}
          </Text>
        ) : null}
        {runtime}
        {children}
      </div>
      {footer ? <div className="shrink-0">{footer}</div> : null}
    </aside>
  );

  if (isDocked) {
    return (
      <div
        data-debug-id="agent-panel-dock-shell"
        data-state={open ? 'open' : dockedClosing ? 'closing' : 'closed'}
        onTransitionEnd={(e) => {
          if (!open && e.target === e.currentTarget && e.propertyName === 'width') {
            setDockedClosing(false);
          }
        }}
        className={`flex h-full min-h-0 shrink-0 grow-0 flex-col overflow-hidden bg-surface transition-[width] duration-200 ease-out motion-reduce:transition-none ${
          open
            ? 'visible w-[400px] border-l border-subtle'
            : dockedClosing
              ? 'visible w-0 border-l border-subtle pointer-events-none'
              : 'invisible w-0 border-l-0 pointer-events-none'
        }`}
      >
        {open || dockedClosing ? aside : null}
      </div>
    );
  }
  // Drawer and page cover the conversation, so they are modal: the @ui Drawer gives
  // role=dialog + aria-modal, the focus trap, Esc, backdrop close, scroll lock,
  // horizontal slide-in/out motion and focus restore to the gear (useDialogA11y).
  return (
    <Drawer
      open={open}
      onOpenChange={(next) => state.setOpen(next)}
      title="Agent settings"
      hideHeader
      side="right"
      size="md"
      animated
      autoFocus={false}
      returnFocusRef={state.gearRef}
      data-debug-id="agent-panel-dialog"
      className={mode === 'page' ? '!max-w-none border-l-0 shadow-none' : '!max-w-[440px]'}
    >
      {aside}
    </Drawer>
  );
}

/** A labelled section slot (overline label + optional trailing header content). */
export function AgentPanelSection({
  id,
  label,
  trailing,
  children,
}: {
  id: string;
  label: string;
  trailing?: React.ReactNode;
  children: React.ReactNode;
}) {
  const headingId = `agent-panel-${id}-heading`;
  return (
    <section data-debug-id={`agent-panel-${id}`} aria-labelledby={headingId} className="flex flex-col gap-2">
      <div className="flex items-center justify-between gap-2">
        <Text as="h3" role="overline" tone="muted" id={headingId}>{label}</Text>
        {trailing}
      </div>
      {children}
    </section>
  );
}

export default AgentSettingsPanel;
