import { createSlice, PayloadAction } from '@reduxjs/toolkit';

export type ToastKind = 'success' | 'error' | 'info' | 'progress';

export type Toast = {
  id: string;
  kind: ToastKind;
  title: string;
  message?: string;
  createdAt: number;
  autoDismissMs?: number;
};

const initialState = {
  toasts: [] as Toast[],
};

const toastSlice = createSlice({
  name: 'toasts',
  initialState,
  reducers: {
    showToast: {
      reducer(state, action: PayloadAction<Toast>) {
        state.toasts = [...state.toasts.filter((t) => t.id !== action.payload.id).slice(-4), action.payload];
      },
      prepare(payload: { id?: string; kind: ToastKind; title: string; message?: string; autoDismissMs?: number }) {
        const id = payload.id || `toast_${Date.now()}_${Math.random().toString(36).slice(2, 6)}`;
        return {
          payload: {
            id,
            kind: payload.kind,
            title: payload.title,
            message: payload.message,
            createdAt: Date.now(),
            autoDismissMs: payload.autoDismissMs ?? (payload.kind === 'error' ? 8000 : 3200),
          } as Toast,
        };
      },
    },
    dismissToast(state, action: PayloadAction<string>) {
      state.toasts = state.toasts.filter((t) => t.id !== action.payload);
    },
    clearToasts(state) {
      state.toasts = [];
    },
  },
});

export const { showToast, dismissToast, clearToasts } = toastSlice.actions;
export default toastSlice.reducer;
