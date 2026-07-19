import type { ReactNode } from 'react';

export default function ChatSidebar({
  debugId,
  className = 'min-h-0 overflow-y-auto border-l border-[#262626] bg-[#0f0f0f] outline-none',
  children,
}: {
  debugId: string;
  className?: string;
  children: ReactNode;
}) {
  return <aside data-debug-id={debugId} className={className}>{children}</aside>;
}
