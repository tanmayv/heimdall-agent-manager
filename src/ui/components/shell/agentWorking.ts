// H13: pure helper (no JSX/DOM) deciding whether an agent is actively WORKING.
// An agent is working only when its runtime is live AND its activity_status is
// active/busy/working (mirrors ConversationThreadPage / ChatWorkBanner). The
// sidebar status dot animates (animate-pulse) ONLY when this returns true; a
// live-but-idle agent renders a static dot. Kept in its own module so it can be
// unit-tested without importing the JSX-heavy AppShell tree.
export function isAgentWorking(state: string, activityStatus?: string): boolean {
  if (state !== 'live') return false;
  const a = String(activityStatus || '').toLowerCase();
  return a === 'active' || a === 'busy' || a === 'working';
}
