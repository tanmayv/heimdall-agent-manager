/**
 * DEPRECATED shim — the Icon primitive now lives in `@ui`
 * (`components/ui/primitives/Icon.tsx`). This file re-exports it so existing
 * `import Icon from '../Icon'` call sites keep working while imports migrate to
 * `@ui`. It holds NO implementation of its own (not a parallel copy) and is a
 * temporary coexistence bridge — delete it once every call site imports from
 * `@ui` (tracked as a migration follow-up; in-flight search-v2 files still use
 * this path).
 */
export { Icon as default, Icon, type IconName, type IconSize, type IconProps } from './ui/primitives/Icon';
