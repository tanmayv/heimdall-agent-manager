/**
 * DEPRECATED shim — RuntimeChip now lives in `@ui`
 * (`components/ui/patterns/RuntimeChip.tsx`). This re-exports it so the existing
 * `runtimeStateFromStatus` import in ConversationThreadPage (an in-flight
 * search-v2 file) keeps working. Delete once that file imports from `@ui`.
 */
export {
  RuntimeChip as default,
  RuntimeChip,
  runtimeStateFromStatus,
  runtimeStateLabel,
  type RuntimeChipProps,
  type RuntimeState,
} from '../ui/patterns/RuntimeChip';
