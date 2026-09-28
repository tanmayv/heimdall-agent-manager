/**
 * Pure settings route resolution and tab normalization logic.
 * Extracted to allow direct execution in native Node.js test runners without bundler alias overhead.
 */

export function resolveSettingsTab(path: string): string {
  const cleanPath = (path.startsWith('#') ? path.slice(1) : path).split('?')[0];
  if (!cleanPath.startsWith('/settings')) return 'general';
  const sub = cleanPath.slice('/settings'.length).replace(/^\//, '').split('/')[0] || '';
  if (!sub) return 'general';
  return sub;
}

export function normalizeSettingsTab(tab?: string): string {
  if (!tab) return 'general';
  if (tab === 'bridges') return 'workspace';
  if (tab === 'providers') return 'models';
  if (tab === 'labs') return 'experimental';
  return tab;
}
