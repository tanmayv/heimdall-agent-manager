// Shared helpers for turning a search hit into a navigation target and for
// rendering its matched-text preview. Extracted from CommandPalette so the
// command palette and the conversation-scoped header search render and navigate
// identically — one source of truth for search-hit routing (a divergence here
// would send the two search surfaces to different places for the same hit).

import React from 'react';
import type { SearchHit } from '../api/endpoints/search';

// hitRoute maps a search hit to its in-app route (hash path). Message hits carry
// the conversation route but the hit id is the MESSAGE id, so thread it as
// `?msg=<message_id>` (parsed by AppShell into a scroll-to focus target).
export function hitRoute(hit: SearchHit): string {
  const type = String(hit.type || '').toLowerCase();
  const id = hit.id;
  if (type === 'message') {
    const base = hit.route || (hit.parent?.id ? `/conversations/${hit.parent.id}` : '');
    if (!base) return '';
    if (!id) return base;
    const sep = base.includes('?') ? '&' : '?';
    return base.includes('msg=') ? base : `${base}${sep}msg=${encodeURIComponent(id)}`;
  }
  // Prefer the backend-provided route; fall back to type-based routes.
  if (hit.route) return hit.route;
  switch (type) {
    case 'conversation':
      return `/conversations/${id}`;
    case 'agent':
    case 'agent_instance':
      return `/agents/${id}`;
    case 'task-chain':
    case 'chain':
      return `/chains/${id}`;
    case 'task':
      return `/chains`;
    case 'skill':
      return `/skills/${id}`;
    case 'project':
      return `/library`;
    case 'artifact':
      return `/library`;
    // Comments always carry a backend route (to their task); no id-only fallback.
    default:
      return '';
  }
}

// renderPreview highlights the matched token, which the backend brackets as
// "…text [match] text…". Falls back to the plain string if no bracket is present.
export function renderPreview(preview: string) {
  const open = preview.indexOf('[');
  const close = open >= 0 ? preview.indexOf(']', open + 1) : -1;
  if (open < 0 || close < 0) return preview;
  return (
    <>
      {preview.slice(0, open)}
      <span className="rounded bg-warning-soft px-0.5 text-warning">{preview.slice(open + 1, close)}</span>
      {preview.slice(close + 1)}
    </>
  );
}
