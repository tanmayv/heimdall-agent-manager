import { createSlice, type PayloadAction } from '@reduxjs/toolkit';

export interface SearchItem {
  id: string;
  type: 'chain' | 'conversation';
  rawTitle: string;
  decryptedTitle: string;
  projectId?: string;
  status?: string;
  updatedAt?: string;
}

export interface SearchTitleState {
  chains: Record<string, SearchItem>;
  conversations: Record<string, SearchItem>;
  isInitialized: boolean;
}

export type UpsertSearchItemPayload = {
  id: string;
  rawTitle: string;
  decryptedTitle?: string;
  type?: 'chain' | 'conversation';
  projectId?: string;
  status?: string;
  updatedAt?: string;
};

const initialState: SearchTitleState = {
  chains: {},
  conversations: {},
  isInitialized: false,
};

export const searchTitleSlice = createSlice({
  name: 'searchTitle',
  initialState,
  reducers: {
    upsertChainTitle(state, action: PayloadAction<UpsertSearchItemPayload>) {
      const item = action.payload;
      if (!item?.id) return;
      const existing: Partial<SearchItem> = state.chains[item.id] || {};
      const rawTitle = item.rawTitle ?? existing.rawTitle ?? '';
      let decryptedTitle = item.decryptedTitle;
      if (decryptedTitle === undefined) {
        if (existing.decryptedTitle && rawTitle === existing.rawTitle) {
          decryptedTitle = existing.decryptedTitle;
        } else {
          decryptedTitle = rawTitle;
        }
      }
      state.chains[item.id] = {
        ...existing,
        ...item,
        id: item.id,
        type: 'chain',
        rawTitle,
        decryptedTitle,
      };
    },

    upsertConversationTitle(state, action: PayloadAction<UpsertSearchItemPayload>) {
      const item = action.payload;
      if (!item?.id) return;
      const existing: Partial<SearchItem> = state.conversations[item.id] || {};
      const rawTitle = item.rawTitle ?? existing.rawTitle ?? '';
      let decryptedTitle = item.decryptedTitle;
      if (decryptedTitle === undefined) {
        if (existing.decryptedTitle && rawTitle === existing.rawTitle) {
          decryptedTitle = existing.decryptedTitle;
        } else {
          decryptedTitle = rawTitle;
        }
      }
      state.conversations[item.id] = {
        ...existing,
        ...item,
        id: item.id,
        type: 'conversation',
        rawTitle,
        decryptedTitle,
      };
    },

    setBulkChainTitles(state, action: PayloadAction<SearchItem[] | Record<string, SearchItem>>) {
      if (Array.isArray(action.payload)) {
        for (const item of action.payload) {
          if (!item?.id) continue;
          const existing: Partial<SearchItem> = state.chains[item.id] || {};
          const rawTitle = item.rawTitle ?? existing.rawTitle ?? '';
          state.chains[item.id] = {
            ...existing,
            ...item,
            id: item.id,
            type: 'chain',
            rawTitle,
            decryptedTitle: item.decryptedTitle ?? existing.decryptedTitle ?? rawTitle,
          };
        }
      } else if (action.payload && typeof action.payload === 'object') {
        for (const [id, item] of Object.entries(action.payload)) {
          if (!item) continue;
          const existing: Partial<SearchItem> = state.chains[id] || {};
          const rawTitle = item.rawTitle ?? existing.rawTitle ?? '';
          state.chains[id] = {
            ...existing,
            ...item,
            id,
            type: 'chain',
            rawTitle,
            decryptedTitle: item.decryptedTitle ?? existing.decryptedTitle ?? rawTitle,
          };
        }
      }
      state.isInitialized = true;
    },

    setBulkConversationTitles(state, action: PayloadAction<SearchItem[] | Record<string, SearchItem>>) {
      if (Array.isArray(action.payload)) {
        for (const item of action.payload) {
          if (!item?.id) continue;
          const existing: Partial<SearchItem> = state.conversations[item.id] || {};
          const rawTitle = item.rawTitle ?? existing.rawTitle ?? '';
          state.conversations[item.id] = {
            ...existing,
            ...item,
            id: item.id,
            type: 'conversation',
            rawTitle,
            decryptedTitle: item.decryptedTitle ?? existing.decryptedTitle ?? rawTitle,
          };
        }
      } else if (action.payload && typeof action.payload === 'object') {
        for (const [id, item] of Object.entries(action.payload)) {
          if (!item) continue;
          const existing: Partial<SearchItem> = state.conversations[id] || {};
          const rawTitle = item.rawTitle ?? existing.rawTitle ?? '';
          state.conversations[id] = {
            ...existing,
            ...item,
            id,
            type: 'conversation',
            rawTitle,
            decryptedTitle: item.decryptedTitle ?? existing.decryptedTitle ?? rawTitle,
          };
        }
      }
      state.isInitialized = true;
    },

    clearSearchTitles(state) {
      state.chains = {};
      state.conversations = {};
      state.isInitialized = false;
    },

    setSearchTitlesInitialized(state, action: PayloadAction<boolean>) {
      state.isInitialized = action.payload;
    },
  },
});

export const {
  upsertChainTitle,
  upsertConversationTitle,
  setBulkChainTitles,
  setBulkConversationTitles,
  clearSearchTitles,
  setSearchTitlesInitialized,
} = searchTitleSlice.actions;

export const selectSearchTitleState = (state: { searchTitle: SearchTitleState }) => state.searchTitle;
export const selectSearchChains = (state: { searchTitle: SearchTitleState }) => state.searchTitle?.chains || {};
export const selectSearchConversations = (state: { searchTitle: SearchTitleState }) => state.searchTitle?.conversations || {};
export const selectIsSearchTitlesInitialized = (state: { searchTitle: SearchTitleState }) => Boolean(state.searchTitle?.isInitialized);
export const selectAllSearchItems = (state: { searchTitle: SearchTitleState }): SearchItem[] => [
  ...Object.values(state.searchTitle?.chains || {}),
  ...Object.values(state.searchTitle?.conversations || {}),
];

export default searchTitleSlice.reducer;
