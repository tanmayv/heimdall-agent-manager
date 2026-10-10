/**
 * Pure settings route resolution and tab normalization logic.
 * Extracted to allow direct execution in native Node.js test runners without bundler alias overhead.
 */

export function resolveSettingsTab(path: string): string {
  const cleanPath = (path.startsWith('#') ? path.slice(1) : path).split('?')[0];
  if (!cleanPath.startsWith('/settings')) return 'appearance';
  const sub = cleanPath.slice('/settings'.length).replace(/^\//, '').split('/')[0] || '';
  if (!sub || sub === 'general') return 'appearance';
  return sub;
}

export function normalizeSettingsTab(tab?: string): string {
  if (!tab || tab === 'general') return 'appearance';
  if (tab === 'bridges') return 'workspace';
  if (tab === 'providers') return 'models';
  if (tab === 'labs') return 'experimental';
  if (tab === 'browser' || tab === 'shortcuts' || tab === 'feedback') return 'appearance';
  return tab;
}
