/**
 * useAgentSettingsPanelState — open/closed state, layout mode and focus handoff for
 * the Agent settings panel (see DESIGN.md).
 *
 * Layout follows the viewport: docked beside the transcript at >= DOCK_MIN (1280px),
 * an overlay drawer below that, and a full-screen page on mobile (< 768px).
 *
 * Persistence: the docked panel's open/closed state is stored per user
 * (userScopedStorageKey). The drawer and the mobile page cover the conversation, so
 * they always start closed and opening them is never persisted; otherwise a reload
 * on a phone would land on the settings page instead of the chat.
 *
 * Focus: opening moves focus to the panel heading, closing returns it to the gear
 * (only on user-driven transitions; a restored open panel does not steal focus).
 */
import { useCallback, useEffect, useRef, useState } from 'react';
import { DOCK_MIN, MOBILE_MAX, useViewportWidth } from '../ui/hooks/useViewport';
import { userScopedStorageKey } from '../../utils/clientPersistence';

export type AgentSettingsPanelMode = 'docked' | 'drawer' | 'page';

export const AGENT_SETTINGS_PANEL_STORAGE_KEY = 'agentSettingsPanel.open';

export function agentSettingsPanelMode(width: number): AgentSettingsPanelMode {
  if (width <= MOBILE_MAX) return 'page';
  if (width < DOCK_MIN) return 'drawer';
  return 'docked';
}

/** The stored docked preference; false when unset or storage is unavailable. */
export function readAgentSettingsPanelOpen(userId?: string): boolean {
  try {
    return globalThis.localStorage?.getItem(userScopedStorageKey(AGENT_SETTINGS_PANEL_STORAGE_KEY, userId)) === '1';
  } catch {
    return false;
  }
}

export function writeAgentSettingsPanelOpen(open: boolean, userId?: string): void {
  try {
    const key = userScopedStorageKey(AGENT_SETTINGS_PANEL_STORAGE_KEY, userId);
    if (open) globalThis.localStorage?.setItem(key, '1');
    else globalThis.localStorage?.removeItem(key);
  } catch {
    /* Storage can be unavailable (private mode, hardened contexts): state stays in memory. */
  }
}

export interface AgentSettingsPanelState {
  /** Whether the panel is shown in the current mode. */
  open: boolean;
  mode: AgentSettingsPanelMode;
  setOpen: (open: boolean) => void;
  toggle: () => void;
  /** Attach to the header gear (focus returns here on close). */
  gearRef: React.RefObject<HTMLButtonElement | null>;
  /** Attach to the panel heading (focus moves here on open). */
  headingRef: React.RefObject<HTMLHeadingElement | null>;
}

export function useAgentSettingsPanelState(options: { enabled?: boolean; width?: number } = {}): AgentSettingsPanelState {
  const enabled = options.enabled !== false;
  const viewportWidth = useViewportWidth();
  const mode = agentSettingsPanelMode(options.width ?? viewportWidth);
  const [docked, setDocked] = useState<boolean>(() => readAgentSettingsPanelOpen());
  const [overlay, setOverlay] = useState(false);
  const gearRef = useRef<HTMLButtonElement | null>(null);
  const headingRef = useRef<HTMLHeadingElement | null>(null);
  // Set by a user action; consumed by the focus effect after the panel (un)mounts.
  const pendingFocus = useRef<'heading' | 'gear' | null>(null);

  const open = enabled && (mode === 'docked' ? docked : overlay);

  const setOpen = useCallback((next: boolean) => {
    pendingFocus.current = next ? 'heading' : 'gear';
    if (mode === 'docked') {
      setDocked(next);
      writeAgentSettingsPanelOpen(next);
    } else {
      setOverlay(next);
    }
  }, [mode]);

  const toggle = useCallback(() => setOpen(!open), [open, setOpen]);

  // Leaving the overlay modes closes the transient drawer/page.
  useEffect(() => {
    if (mode === 'docked') setOverlay(false);
  }, [mode]);

  useEffect(() => {
    const target = pendingFocus.current;
    if (!target) return;
    pendingFocus.current = null;
    if (target === 'heading' && open) headingRef.current?.focus();
    if (target === 'gear' && !open) gearRef.current?.focus();
  }, [open]);

  // Esc closes the drawer and the mobile page, never the docked panel. The @ui Drawer
  // hosting those modes handles Esc itself (capture phase); this is the fallback for
  // hosts that render the panel without it.
  useEffect(() => {
    if (!open || mode === 'docked' || typeof document === 'undefined') return;
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== 'Escape' || event.defaultPrevented) return;
      // A dialog opened from inside the panel (Force stop) handles its own Esc.
      if (document.querySelector('[role="dialog"][aria-modal="true"]')) return;
      event.preventDefault();
      setOpen(false);
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [open, mode, setOpen]);

  return { open, mode, setOpen, toggle, gearRef, headingRef };
}
