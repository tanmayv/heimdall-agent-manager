import { createSlice, PayloadAction } from '@reduxjs/toolkit';

export interface CardsState {
  selectedCardIds: string[];
  statusFilter: string;
  scopeFilter: string;
  searchQuery: string;
}

const initialState: CardsState = {
  selectedCardIds: [],
  statusFilter: 'pending',
  scopeFilter: '',
  searchQuery: '',
};

export const cardsSlice = createSlice({
  name: 'cards',
  initialState,
  reducers: {
    toggleCardSelected(state, action: PayloadAction<string>) {
      const id = action.payload;
      if (state.selectedCardIds.includes(id)) {
        state.selectedCardIds = state.selectedCardIds.filter((item) => item !== id);
      } else {
        state.selectedCardIds.push(id);
      }
    },
    selectCards(state, action: PayloadAction<string[]>) {
      state.selectedCardIds = Array.from(new Set([...state.selectedCardIds, ...action.payload]));
    },
    deselectCards(state, action: PayloadAction<string[]>) {
      const toRemove = new Set(action.payload);
      state.selectedCardIds = state.selectedCardIds.filter((id) => !toRemove.has(id));
    },
    clearSelectedCards(state) {
      state.selectedCardIds = [];
    },
    setStatusFilter(state, action: PayloadAction<string>) {
      state.statusFilter = action.payload;
    },
    setScopeFilter(state, action: PayloadAction<string>) {
      state.scopeFilter = action.payload;
    },
    setSearchQuery(state, action: PayloadAction<string>) {
      state.searchQuery = action.payload;
    },
  },
});

export const {
  toggleCardSelected,
  selectCards,
  deselectCards,
  clearSelectedCards,
  setStatusFilter,
  setScopeFilter,
  setSearchQuery,
} = cardsSlice.actions;

export default cardsSlice.reducer;
