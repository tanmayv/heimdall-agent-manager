import React from 'react';

// Canonical empty-state block: a dashed, centered placeholder for "nothing here
// yet" / "no matches" / "loading" surfaces. Extracted from the `Empty` helper
// that lived in MemoryPage (its twin was removed with MemoryManagementPage).
export default function EmptyState({
  text,
  children,
  className = '',
  debugId = 'empty-state',
}: {
  text?: string;
  children?: React.ReactNode;
  className?: string;
  debugId?: string;
}) {
  return (
    <div
      data-debug-id={debugId}
      className={`rounded-2xl border border-dashed border-white/10 bg-white/[0.02] py-12 text-center text-sm text-zinc-500 ${className}`.trim()}
    >
      {children ?? text}
    </div>
  );
}
