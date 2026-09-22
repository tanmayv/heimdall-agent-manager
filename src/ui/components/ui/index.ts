/**
 * Public barrel for the shared UI component library (`@ui`).
 *
 * Import everything from here or via the `@ui` alias, e.g.
 *   import { Button, type Size } from '@ui';
 *   import type { Tone } from '@ui/types';
 *
 * The library is layered (see README.md):
 *   - primitives/  no product knowledge, highly reused (Button, Input, Text, ...)
 *   - composites/  assembled from primitives, still product-agnostic (Modal, Table, ...)
 *   - patterns/    product-specific compositions worth naming (UserPickerField, ...)
 *   - hooks/       behaviour with no markup of its own (useInfiniteList, useViewport)
 *
 * The shared prop vocabulary lives in `./types`.
 *
 * Add each component's re-export below as it lands. Keeping the exports here (rather
 * than deep-importing files) is what lets call sites use `@ui` stably.
 */

export * from './types';

export * from './primitives';
export * from './composites';
export * from './patterns';
export * from './hooks';
