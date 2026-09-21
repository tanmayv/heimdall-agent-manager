// T11-UI-5: state behind the right-hand Preview Sidebar.
//
// A "preview tab" is one live server shell session whose HTTP port the hub proxies
// at /api/v1/preview/{sessionId}/. The sidebar is a browser-like multi-tab shell:
// several sessions can be open at once, one is focused, and each remembers the path
// the user navigated to inside it so switching tabs does not reset the iframe URL.
//
// Nothing here talks to the network. Tabs are opened from ShellsPanel and closed
// either by the user or automatically once the underlying session stops running —
// the auto-close lives in PreviewSidebar, which watches each session and dispatches
// closeTab (see the note there on why it is a per-tab watcher and not a WS
// subscription in this slice).
import { createSlice, type PayloadAction } from '@reduxjs/toolkit';
import type { ShellSession } from '../api/endpoints/shells';

export type PreviewTab = {
  sessionId: string;
  label: string;
  port: number;
  // Path *inside* the previewed server, always without a leading slash ('' is its
  // root). Stored normalized so the iframe src can be built by plain concatenation.
  currentPath: string;
};

export type PreviewTabsState = {
  tabs: PreviewTab[];
  activeTabId: string | null;
  // Bumped on EVERY openTab, including one that only re-focuses a tab that is
  // already open. The sidebar watches it to un-collapse itself: tab count and
  // activeTabId both stay put when the user re-opens the already-active session,
  // so neither is enough on its own to notice that "Open Preview" was pressed.
  openSeq: number;
};

const initialState: PreviewTabsState = {
  tabs: [],
  activeTabId: null,
  openSeq: 0,
};

// The hub proxy mounts each session at a directory URL, so a leading slash on the
// stored path would produce '//' and a trailing-slash-less root would break relative
// asset URLs inside the previewed page. Normalize once, on the way into the store.
function normalizePath(path: string): string {
  return String(path || '').replace(/^\/+/, '');
}

function tabLabel(session: ShellSession): string {
  return session.label || session.cmd || session.session_id.slice(0, 12);
}

const previewTabsSlice = createSlice({
  name: 'previewTabs',
  initialState,
  reducers: {
    // Opening a session that is already open focuses its existing tab rather than
    // duplicating it — and keeps the path the user had navigated to.
    openTab(state, action: PayloadAction<ShellSession>) {
      const session = action.payload;
      const sessionId = session?.session_id || '';
      if (!sessionId) return;
      const existing = state.tabs.find((tab) => tab.sessionId === sessionId);
      if (existing) {
        existing.label = tabLabel(session);
        existing.port = session.server_port;
      } else {
        state.tabs.push({
          sessionId,
          label: tabLabel(session),
          port: session.server_port,
          currentPath: '',
        });
      }
      state.activeTabId = sessionId;
      state.openSeq += 1;
    },

    closeTab(state, action: PayloadAction<string>) {
      const sessionId = action.payload;
      const index = state.tabs.findIndex((tab) => tab.sessionId === sessionId);
      if (index < 0) return;
      state.tabs.splice(index, 1);
      if (state.activeTabId !== sessionId) return;
      // Focus the neighbour that slid into this slot, else the new last tab, else
      // nothing — which collapses the sidebar.
      const next = state.tabs[index] || state.tabs[state.tabs.length - 1];
      state.activeTabId = next ? next.sessionId : null;
    },

    focusTab(state, action: PayloadAction<string>) {
      const sessionId = action.payload;
      if (state.tabs.some((tab) => tab.sessionId === sessionId)) {
        state.activeTabId = sessionId;
      }
    },

    setTabPath(state, action: PayloadAction<{ sessionId: string; path: string }>) {
      const tab = state.tabs.find((item) => item.sessionId === action.payload.sessionId);
      if (tab) tab.currentPath = normalizePath(action.payload.path);
    },
  },
});

export const { openTab, closeTab, focusTab, setTabPath } = previewTabsSlice.actions;

// Same-origin proxy URL for a tab. No ?pt= preview token (T11-UI-4): the hub
// authorizes this route from the user's session cookie, which the browser attaches
// automatically because the iframe is same-origin with the hub.
export function previewUrlFor(tab: PreviewTab): string {
  return `/api/v1/preview/${encodeURIComponent(tab.sessionId)}/${tab.currentPath}`;
}

export const selectPreviewTabs = (state: any): PreviewTab[] => state.previewTabs?.tabs ?? [];
export const selectActivePreviewTabId = (state: any): string | null => state.previewTabs?.activeTabId ?? null;
export const selectPreviewOpenSeq = (state: any): number => state.previewTabs?.openSeq ?? 0;

export default previewTabsSlice.reducer;
