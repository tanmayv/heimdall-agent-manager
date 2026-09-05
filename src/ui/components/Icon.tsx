// Shared icon set for the conversations-first UI rework.
//
// Project rule (see docs/plans/ui-rework-conversations-first.md and AGENTS.md):
// the UI must use icons, NOT emojis. Reference every glyph by a stable name via
// <Icon name="..." />.
//
// NOTE: we deliberately hand-roll inline SVGs instead of using `lucide-react` — the
// version pinned in this repo (1.21.0) ships a broken package (its `module` entry
// points at a missing .mjs, so Vite fails to resolve it). Keeping icons local means
// zero external dependency and no build breakage. Icons are monochrome
// (currentColor) on a 0 0 24 24 viewBox.

import type { CSSProperties, ReactElement } from 'react';

export type IconName =
  | 'plus'
  | 'gear'
  | 'chat'
  | 'grid'
  | 'tasks'
  | 'chevron-left'
  | 'chevron-right'
  | 'chevron-down'
  | 'arrow-up'
  | 'arrow-right'
  | 'close'
  | 'stop'
  | 'play'
  | 'search'
  | 'device'
  | 'menu'
  | 'refresh'
  | 'pencil'
  | 'folder'
  | 'file'
  | 'download'
  | 'clock'
  | 'calendar'
  | 'trash'
  | 'zap'
  | 'check'
  | 'alert'
  | 'info'
  | 'more'
  | 'panel-right'
  | 'panel-left'
  | 'terminal'
  | 'lock'
  | 'spark'
  | 'rocket';

const PATHS: Record<IconName, ReactElement> = {
  plus: <path d="M12 5v14M5 12h14" fill="none" stroke="currentColor" strokeWidth={2.2} strokeLinecap="round" />,
  pencil: <path d="M12 20h9M16.5 3.5a2.121 2.121 0 0 1 3 3L7 19l-4 1 1-4L16.5 3.5z" fill="none" stroke="currentColor" strokeWidth={1.8} strokeLinecap="round" strokeLinejoin="round" />,
  gear: (
    <g fill="none" stroke="currentColor" strokeWidth={1.8}>
      <circle cx={12} cy={12} r={3.2} />
      <path d="M12 2.5v2.4M12 19.1v2.4M4.2 7l2 1.2M17.8 15.8l2 1.2M4.2 17l2-1.2M17.8 8.2l2-1.2" strokeLinecap="round" />
    </g>
  ),
  chat: <path d="M4 5.5h16v11H9l-4 3.5v-3.5H4z" fill="none" stroke="currentColor" strokeWidth={1.8} strokeLinejoin="round" />,
  grid: (
    <g fill="none" stroke="currentColor" strokeWidth={1.8}>
      <rect x={4} y={4} width={6.5} height={6.5} rx={1.2} />
      <rect x={13.5} y={4} width={6.5} height={6.5} rx={1.2} />
      <rect x={4} y={13.5} width={6.5} height={6.5} rx={1.2} />
      <rect x={13.5} y={13.5} width={6.5} height={6.5} rx={1.2} />
    </g>
  ),
  tasks: (
    <g fill="none" stroke="currentColor" strokeWidth={1.8} strokeLinecap="round" strokeLinejoin="round">
      <path d="M4 6.5l1.6 1.6L8.5 5" />
      <path d="M4 15.5l1.6 1.6L8.5 14" />
      <path d="M11.5 7h8.5M11.5 16h8.5" />
    </g>
  ),
  'chevron-left': <path d="M14.5 6l-6 6 6 6" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" />,
  'chevron-right': <path d="M9.5 6l6 6-6 6" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" />,
  'chevron-down': <path d="M6 9.5l6 6 6-6" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" />,
  'arrow-up': <path d="M12 19V5M6 11l6-6 6 6" fill="none" stroke="currentColor" strokeWidth={2.1} strokeLinecap="round" strokeLinejoin="round" />,
  'arrow-right': <path d="M5 12h14M13 6l6 6-6 6" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" />,
  close: <path d="M6 6l12 12M18 6L6 18" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" />,
  stop: <rect x={6.5} y={6.5} width={11} height={11} rx={2} fill="currentColor" />,
  play: <path d="M8 5.5v13l11-6.5z" fill="currentColor" />,
  search: (
    <g fill="none" stroke="currentColor" strokeWidth={1.9} strokeLinecap="round">
      <circle cx={10.5} cy={10.5} r={6} />
      <path d="M15 15l4.5 4.5" />
    </g>
  ),
  device: (
    <g fill="none" stroke="currentColor" strokeWidth={1.8}>
      <rect x={4} y={5} width={16} height={11} rx={1.6} />
      <path d="M9 20h6M12 16v4" strokeLinecap="round" />
    </g>
  ),
  menu: <path d="M4 7h16M4 12h16M4 17h16" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" />,
  refresh: (
    <g fill="none" stroke="currentColor" strokeWidth={1.9} strokeLinecap="round" strokeLinejoin="round">
      <path d="M20 11a8 8 0 0 0-14.5-4.5L3 9" />
      <path d="M3 4v5h5" />
      <path d="M4 13a8 8 0 0 0 14.5 4.5L21 15" />
      <path d="M21 20v-5h-5" />
    </g>
  ),
  folder: <path d="M3 7a1 1 0 0 1 1-1h5l2 2h8a1 1 0 0 1 1 1v8a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1z" fill="none" stroke="currentColor" strokeWidth={1.7} strokeLinejoin="round" />,
  file: (
    <g fill="none" stroke="currentColor" strokeWidth={1.7} strokeLinecap="round" strokeLinejoin="round">
      <path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z" />
      <path d="M14 3v5h5" />
    </g>
  ),
  download: (
    <g fill="none" stroke="currentColor" strokeWidth={1.8} strokeLinecap="round" strokeLinejoin="round">
      <path d="M12 3v12M7 10l5 5 5-5" />
      <path d="M4 19h16" />
    </g>
  ),
  clock: (
    <g fill="none" stroke="currentColor" strokeWidth={1.8} strokeLinecap="round" strokeLinejoin="round">
      <circle cx={12} cy={12} r={9} />
      <path d="M12 7v5l3 3" />
    </g>
  ),
  calendar: (
    <g fill="none" stroke="currentColor" strokeWidth={1.8} strokeLinecap="round" strokeLinejoin="round">
      <rect x={3} y={4} width={18} height={18} rx={2} />
      <path d="M16 2v4M8 2v4M3 10h18" />
    </g>
  ),
  trash: (
    <g fill="none" stroke="currentColor" strokeWidth={1.8} strokeLinecap="round" strokeLinejoin="round">
      <path d="M3 6h18M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2" />
      <path d="M10 11v6M14 11v6" />
    </g>
  ),
  zap: <polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2" fill="none" stroke="currentColor" strokeWidth={1.8} strokeLinecap="round" strokeLinejoin="round" />,
  check: <path d="M20 6L9 17l-5-5" fill="none" stroke="currentColor" strokeWidth={2.2} strokeLinecap="round" strokeLinejoin="round" />,
  alert: (
    <g fill="none" stroke="currentColor" strokeWidth={1.9} strokeLinecap="round" strokeLinejoin="round">
      <path d="M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z" />
      <path d="M12 9v4M12 17h.01" />
    </g>
  ),
  info: (
    <g fill="none" stroke="currentColor" strokeWidth={1.8} strokeLinecap="round" strokeLinejoin="round">
      <circle cx={12} cy={12} r={9} />
      <path d="M12 11v5M12 8h.01" />
    </g>
  ),
  more: (
    <g fill="currentColor">
      <circle cx={5} cy={12} r={1.8} />
      <circle cx={12} cy={12} r={1.8} />
      <circle cx={19} cy={12} r={1.8} />
    </g>
  ),
  'panel-right': (
    <g fill="none" stroke="currentColor" strokeWidth={1.8}>
      <rect x={3.5} y={4.5} width={17} height={15} rx={2.2} />
      <path d="M14.5 4.5v15" strokeLinecap="round" />
    </g>
  ),
  'panel-left': (
    <g fill="none" stroke="currentColor" strokeWidth={1.8}>
      <rect x={3.5} y={4.5} width={17} height={15} rx={2.2} />
      <path d="M9.5 4.5v15" strokeLinecap="round" />
    </g>
  ),
  terminal: (
    <g fill="none" stroke="currentColor" strokeWidth={1.8} strokeLinecap="round" strokeLinejoin="round">
      <rect x={3} y={4.5} width={18} height={15} rx={2} />
      <path d="M7 9.5l3 2.5-3 2.5M12.5 15h4" />
    </g>
  ),
  lock: (
    <g fill="none" stroke="currentColor" strokeWidth={1.9}>
      <rect x={5} y={10.5} width={14} height={9} rx={2} />
      <path d="M8 10.5V8a4 4 0 0 1 8 0v2.5" strokeLinecap="round" />
    </g>
  ),
  spark: <path d="M12 3l2 6 6 2-6 2-2 6-2-6-6-2 6-2z" fill="none" stroke="currentColor" strokeWidth={1.6} strokeLinejoin="round" />,
  rocket: (
    <g fill="none" stroke="currentColor" strokeWidth={1.6} strokeLinecap="round" strokeLinejoin="round">
      <path d="M5 15c-1 1-1.5 4-1.5 4s3-.5 4-1.5M14 4c3 0 6 3 6 6-2 5-7 8-9 9l-6-6c1-2 4-7 9-9z" />
      <circle cx={14.5} cy={9.5} r={1.5} />
    </g>
  ),
};

export default function Icon({
  name,
  size = 16,
  className = '',
  style,
  title,
}: {
  name: IconName;
  size?: number | string;
  className?: string;
  style?: CSSProperties;
  title?: string;
}) {
  return (
    <svg
      viewBox="0 0 24 24"
      width={size}
      height={size}
      className={className}
      style={{ display: 'inline-block', verticalAlign: '-0.13em', flex: 'none', ...style }}
      role={title ? 'img' : undefined}
      aria-hidden={title ? undefined : true}
      aria-label={title}
      focusable="false"
    >
      {title ? <title>{title}</title> : null}
      {PATHS[name]}
    </svg>
  );
}
