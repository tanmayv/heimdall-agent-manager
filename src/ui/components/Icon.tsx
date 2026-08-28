// Shared icon set for the conversations-first UI rework.
//
// Project rule (see docs/plans/ui-rework-conversations-first.md and AGENTS.md):
// the UI must use icons, NOT emojis. Reference every glyph by a stable name via
// <Icon name="..." />. This wraps `lucide-react` (already a project dependency) so
// we get a consistent, tree-shakeable, monochrome (currentColor) icon set without
// maintaining raw SVG paths.

import {
  Plus,
  Settings,
  MessageSquare,
  LayoutGrid,
  ListChecks,
  ChevronLeft,
  ChevronRight,
  ChevronDown,
  ArrowUp,
  ArrowRight,
  X,
  Square,
  Play,
  Search,
  MonitorSmartphone,
  type LucideProps,
} from 'lucide-react';
import type { ComponentType } from 'react';

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
  | 'device';

const ICONS: Record<IconName, ComponentType<LucideProps>> = {
  plus: Plus,
  gear: Settings,
  chat: MessageSquare,
  grid: LayoutGrid,
  tasks: ListChecks,
  'chevron-left': ChevronLeft,
  'chevron-right': ChevronRight,
  'chevron-down': ChevronDown,
  'arrow-up': ArrowUp,
  'arrow-right': ArrowRight,
  close: X,
  stop: Square,
  play: Play,
  search: Search,
  device: MonitorSmartphone,
};

export default function Icon({
  name,
  size = 16,
  className = '',
  title,
  strokeWidth = 2,
}: {
  name: IconName;
  size?: number | string;
  className?: string;
  title?: string;
  strokeWidth?: number;
}) {
  const Cmp = ICONS[name];
  return (
    <Cmp
      size={size}
      className={className}
      strokeWidth={strokeWidth}
      aria-hidden={title ? undefined : true}
      aria-label={title}
      role={title ? 'img' : undefined}
      focusable="false"
    />
  );
}
