import React from 'react';

// Canonical neutral badge/pill. Extracted from the byte-identical `Badge` helpers
// that were duplicated in MemoryPage and MemoryDetailPage. Keep this the single
// source of truth for the neutral count/tag pill; add variants here rather than
// re-inlining a new pill at a call site.
export default function Badge({
  children,
  className = '',
  debugId,
}: {
  children: React.ReactNode;
  className?: string;
  debugId?: string;
}) {
  return (
    <span
      data-debug-id={debugId}
      className={`rounded-full border border-white/10 bg-white/5 px-2 py-0.5 text-[11px] text-zinc-300 ${className}`.trim()}
    >
      {children}
    </span>
  );
}
