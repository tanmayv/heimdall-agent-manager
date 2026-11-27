import { buildRouteHash } from './appLocation.ts';

type NavigationEntry = { index: number; sameDocument: boolean };
type ViewerNavigation = {
  currentEntry: NavigationEntry | null;
  entries: () => NavigationEntry[];
};

export function closeViewer(fallback = buildRouteHash('/home', '')): void {
  const nav = (window as Window & { navigation?: ViewerNavigation }).navigation;
  const previous = nav?.entries()[(nav.currentEntry?.index ?? 0) - 1];
  // history.length includes unrelated sites and forward entries.
  if (previous?.sameDocument) {
    window.history.back();
    return;
  }
  window.history.replaceState(null, '', fallback);
  window.dispatchEvent(new window.PopStateEvent('popstate'));
}
