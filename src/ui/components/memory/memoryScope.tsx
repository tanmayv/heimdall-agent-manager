/**
 * DEPRECATED shim — the scope selector now lives in `@ui`
 * (`components/ui/patterns/ScopeField.tsx`, EL-023). This re-exports it so the
 * existing `./memoryScope` imports in MemoryPage / MemoryDetailPage keep working.
 * Prefer importing `ScopeField` (or `ScopeEditor`/`ScopeChips`/`Targeting`/…) from
 * `@ui`. Delete this once those pages import from `@ui`.
 */
export * from '../ui/patterns/ScopeField';
