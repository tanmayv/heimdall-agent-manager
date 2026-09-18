import { createSlice, PayloadAction } from '@reduxjs/toolkit';
import { useCallback } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import {
  DEFAULT_THEME_ID,
  getTheme,
  isThemeId,
  ThemeDefinition,
  THEMES,
} from '../theme/registry';

const STORAGE_KEY = 'heimdall-theme';

export function applyThemeToDocument(themeId: string): ThemeDefinition {
  const theme = getTheme(themeId);
  if (typeof document !== 'undefined') {
    document.documentElement.dataset.theme = theme.id;
    document.documentElement.style.colorScheme = theme.appearance;
  }
  return theme;
}

function getInitialThemeId(): string {
  if (typeof window !== 'undefined' && typeof localStorage !== 'undefined') {
    try {
      const saved = localStorage.getItem(STORAGE_KEY);
      if (saved && isThemeId(saved)) {
        return saved;
      }
    } catch (e) {
      // Ignore localStorage access errors
    }
  }
  return DEFAULT_THEME_ID;
}

// Immediately apply the theme on script evaluation to avoid flash of wrong theme
const initialThemeId = getInitialThemeId();
applyThemeToDocument(initialThemeId);

export interface ThemeState {
  activeThemeId: string;
}

const initialState: ThemeState = {
  activeThemeId: initialThemeId,
};

export const themeSlice = createSlice({
  name: 'theme',
  initialState,
  reducers: {
    setTheme(state, action: PayloadAction<string>) {
      const id = action.payload;
      if (isThemeId(id)) {
        state.activeThemeId = id;
        try {
          if (typeof localStorage !== 'undefined') {
            localStorage.setItem(STORAGE_KEY, id);
          }
        } catch (e) {
          // Ignore localStorage errors
        }
        applyThemeToDocument(id);
      }
    },
  },
});

export const { setTheme } = themeSlice.actions;

export const selectActiveThemeId = (state: { theme?: ThemeState }) =>
  state.theme?.activeThemeId || DEFAULT_THEME_ID;

export const selectActiveTheme = (state: { theme?: ThemeState }) =>
  getTheme(selectActiveThemeId(state));

export function useTheme() {
  const dispatch = useDispatch();
  const themeId = useSelector(selectActiveThemeId);
  const theme = useSelector(selectActiveTheme);

  const changeTheme = useCallback(
    (id: string) => {
      dispatch(setTheme(id));
    },
    [dispatch],
  );

  return {
    theme,
    themeId,
    setTheme: changeTheme,
    themes: THEMES,
  };
}

export default themeSlice.reducer;
