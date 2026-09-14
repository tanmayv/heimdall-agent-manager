# `@ui` — shared component library

The consolidated component set for the Heimdall dashboard. It replaces the six-slightly-
different-buttons situation with a small, token-driven set that has one clean, teachable API.

Design docs live in `docs/ui-audit/`:

- `02-tokens.md` — the design tokens (implemented as CSS vars in `src/ui/tokens.css` and
  exposed as Tailwind theme aliases in `tailwind.config.js`).
- `03-design-language.md` — the design language statement.
- `04-component-catalogue.md` — the per-component API specs to build against.
- `05-shared-vocabulary.md` — the shared prop vocabulary (encoded in `types.ts`).

## The `@ui` alias

Import from the library through the `@ui` alias, never by long relative paths:

```ts
import { Button } from '@ui';           // barrel (index.ts)
import type { Size, Tone } from '@ui/types';
```

The alias resolves in three places (keep them in sync):

- `tsconfig.renderer.json` → `compilerOptions.paths` (typecheck)
- `vite.config.js` → `resolve.alias` (dev + build)

`@ui` maps to `src/ui/components/ui`.

## Layering

Put a component in the folder that matches its layer. When in doubt, keep it lower
(more generic) only if it truly has no product knowledge.

| Folder | Layer | What belongs here | Examples |
|---|---|---|---|
| `primitives/` | Primitive | No product knowledge, highly reused. | `Button`, `Input`, `Text`, `Box`/`Stack`, `Icon`, `Badge`, `Checkbox`, `Radio`, `Select`, `Link` |
| `composites/` | Composite | Assembled from primitives, still product-agnostic. | `Modal`, `Table`, `Tabs`, `Card`, `FormField`, `Menu`, `Toast`, `Pagination` |
| `patterns/` | Pattern | Product-specific compositions worth naming. | `UserPickerField`, `BillingSummaryCard` |

Genuine one-offs stay local to their feature directory — do not force them in here.

## Rules of the road

- **Tokens only.** No raw hex, px, radii, z-index, or durations in a component — consume
  the tokens (`var(--color-*)`, `var(--radius-md)`, or the Tailwind aliases `bg-surface`,
  `text-muted`, `z-modal`, `shadow-panel`, `text-body`, `duration-base`, ...).
- **Shared vocabulary.** Reuse the prop names/types from `types.ts` (`variant`, `size`,
  `tone`, `emphasis`, `onChange`, `onOpenChange`, ...). Never introduce a synonym.
- **Accessibility is built in**, not a prop. Focus rings, roles, and keyboard handling ship
  with the component; only labels/descriptions come from the caller (and are required).
- **One escape hatch.** `className` passes through to the root only. No per-part class props.
- **Re-export from `index.ts`.** Add each component's export to the barrel as it lands so
  call sites keep importing from `@ui`.

## Status

Empty scaffold. The structure, the `@ui` alias, the shared-vocabulary `types.ts`, and the
token layer exist. Components are migrated in later per-component tasks; existing components
under `src/ui/components/` are untouched until then.
