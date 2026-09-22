/**
 * Hooks barrel — behaviour with no markup of its own, reused across the set.
 * Re-exported through the top-level `@ui` barrel (`../index.ts`).
 */

export { useInfiniteList } from './useInfiniteList';
export type {
  UseInfiniteList,
  UseInfiniteListOptions,
  InfiniteListPage,
  InfiniteListFetchArgs,
  InfiniteListStatus,
  RestoreOutcome,
} from './useInfiniteList';

export {
  useViewport,
  useIsMobile,
  useKeyboardInset,
  MOBILE_MAX,
  TABLET_MAX,
  TOUCH_TARGET_CLASS,
} from './useViewport';
export type { Viewport } from './useViewport';
