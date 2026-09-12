# Migration Plan

Incremental, interruptible, and measurable. Old and new coexist; feature work never freezes. The
order stops the bleeding first (tokens + focus + the page shell), then the highest-traffic atoms,
then composites.

## 0. Per-page divergence matrix (why this is worth doing)

The user's #1 complaint — "every page feels different" — made concrete. Each page hand-builds these:

| Page | Title element | Eyebrow | Container width | Card radius | Empty state | Primary button |
|---|---|---|---|---|---|---|
| ProjectsSurface | `h1 text-2xl semibold` | yes (sky-300) | `max-w` none (full) | `2xl` | bare text | sky-400 `rounded-2xl font-black` |
| ActionsPanel | `h1 text-2xl bold` + border-b | no | full | `2xl`/`xl` | rich dashed card | sky-500 `rounded-xl font-semibold` |
| TaskChainsPage | `h1 text-2xl bold` | no | full | rich dashed card | sky-600 `rounded font-semibold` |
| ActionEditorPage | `h1 text-2xl semibold` in-card | no | full | — | sky-500 |
| TaskChainOverview | **`h2` (no h1!) text-lg/xl** | no | full | `lg` `#111111` | — | sky-600 `text-white` |
| SkillViewerPage | `h1 text-lg` + pill | pill | full | — | — |
| MemoryPage | eyebrow + `h1 text-2xl` | yes | none | `2xl` | 2nd `Empty` helper | sky-400 `rounded-full` |
| MemoryManagementPage | eyebrow + `h1 text-2xl` | yes | `max-w-[1600px]` | **`3xl`** | `Empty` helper | red-400 solid |
| Settings panels (×7) | `h2 text-xl` (semibold **or** bold) | no | `max-w-3xl/4xl/5xl` | `2xl` | dashed/bare mix | sky-400/sky-500 mix |
| BridgesPanel | **`h3` no size**, panel-in-card | no | (card) | `2xl` | dashed | sky-400 |

Six header dialects, ten container widths, two card radii, three empty-state styles, four primary
buttons — **on pages that are supposed to look like one product.** `PageShell` + `Panel` +
`SectionHeader` + `Button` collapse every row above into one.

## 1. Sequencing — order by (occurrences × risk reduction) ÷ effort

| Wave | Ship | Why first | Rough effort |
|---|---|---|---|
| **W0 Tokens** | `02-tokens.md` as CSS vars / Tailwind theme; **delete `odin.*`**; **define `--fd-surface-3`** (fixes live bug); pick the one accent. | Everything else references tokens. Zero UI risk (values map 1:1). | S |
| **W1 Focus + a11y baseline** | `Button`, `IconButton`, `Input`, `Textarea`, `Link` with built-in focus-visible ring; ban `outline-none`. | Fixes the #1 P0 (invisible focus) across ~800 controls the moment call sites migrate. Highest risk-reduction. | M |
| **W2 Page shell** | `PageShell`, `SectionHeader`, `Panel`, `Card`. Migrate pages one at a time. | Directly delivers the "consistent pages" goal; each page migrated is instantly on-model. | L (per-page, parallelizable) |
| **W3 Overlays** | `Modal`, `Menu`, `Drawer` (focus trap/Esc/aria). Wrap the 9 overlay families. | Fixes the #2 P0 (no focus management) once, everywhere. | M |
| **W4 Forms** | `Select`, `Combobox`, `Checkbox`, `Radio`, `Toggle`, `FormField`. Delete the gray `MemoryScopeSelector` shim. | Consolidates 3 input families + fixes labelling. | M |
| **W5 Status + feedback** | `Badge`, `StatusPill`, `StatusDot`, `Alert`, `EmptyState`, `Spinner`, `Toast`, `ProgressBar`, `Table`, `Pagination`. | Collapses the tone/opacity forks; adds `role=alert/status`; real table semantics. | M |
| **W6 Patterns + one-offs** | Merge `Composer`s; consolidate `AgentPicker*`; `ScopeField`; `ConnectionBadge` on primitives; wrap `ArtifactViewer` in `Modal`; add keyboard to `ChainEditor` canvas. | Lower traffic; depends on primitives above. | M |

Tokens land first, then the highest-traffic primitives (Button/Input), then the shell, then
composites — never the interesting components first.

## 2. Automation split (from `06-mapping.csv`)

- **Pure find-and-replace / codemod (~55%)**: single-class-signature atoms — `Button` (EL-001/2/5/6/7/8/10/11/17), `Input`/`Textarea` (EL-020/21/22/24/32/33), `Badge`/`Kbd`/`Avatar` (EL-047/49/51/52/53/54), `Text` overlines (EL-042), `Alert`/`Spinner` (EL-067/68/70/71/72), `Checkbox` (EL-028). A jscodeshift/ts-morph codemod matching the className signature → component. Write one codemod per primitive.
- **Codemod + human review (~25%)**: `SectionHeader`/`Panel` (EL-041/43/44), `Tabs`/`Accordion` (EL-061/62), `Pagination`, `ProgressBar` — structure is regular but slots need eyes.
- **Human judgement (~20%)**: intent mapping (`variant`/`tone`) for EL-009/012/013/048/050; page-shell refactors (EL-035–040); overlays (EL-055–060, focus/label wiring); options-data refactor for `Select`/`Combobox` (EL-025/26/27); icon labels (EL-014/15/18).

Estimate: a codemod pass clears roughly half the ~1,800 call sites mechanically; the rest is
per-file review, front-loaded on the ~10 page files.

## 3. Coexistence — old and new side by side

- New components live in `src/ui/components/ui/` (the design-system package). Import as
  `@ui/Button`. Everything else is "legacy" by definition of location.
- **Tell-at-a-glance:** new = imported from `@ui/*`; legacy = inline classes / local component. A repo
  badge in each migrated file's top comment (`// migrated: ui-audit W2`) tracks progress.
- **Deprecation markers:** wrap the retiring twins (`Composer.tsx`, `MemoryScopeSelector.tsx`,
  duplicate `Badge`/`Empty`/`ModalShell` helpers) with `/** @deprecated use @ui/… */` so editors flag
  new usages immediately.
- Tokens are global from W0, so legacy and new render the same colors during the transition — no
  visual "two apps" seam while migrating.

## 4. Guardrails (CI/lint — without these it re-fragments in two quarters)

1. **No raw hex/rgb outside the token file.** ESLint (`no-restricted-syntax` on color literals in
   JSX/`className`) + a stylelint rule on CSS. Exceptions allow-listed (Shiki/Mermaid).
2. **No arbitrary Tailwind values for tokenized dims** — ban `text-[NNpx]`, `rounded-[…]`,
   `bg-[#…]`, `z-[…]`, `duration-[…]` via `eslint-plugin-tailwindcss` `no-arbitrary-value` (scoped).
3. **No native `<button>`/`<input>`/`<select>` outside `@ui/*`.** Custom ESLint rule; the design-system
   files are the only place native elements are allowed.
4. **No emoji / text-glyph as icon** in JSX (enforces the AGENTS.md icons-not-emoji rule).
5. **No `outline-none` without a focus-visible replacement.** Lint rule.
6. **Sub-11px font ban** (`text-[8/9/10px]`) outside an allow-list.
7. **a11y CI**: `eslint-plugin-jsx-a11y` (clickable-has-role/key handlers) + an axe smoke test on key
   pages (catches modal focus-trap / missing labels regressions).

## 5. Rollback

- Components are additive and import-scoped, so **reverting one file's import** restores its prior
  behavior — no global rollback needed.
- Tokens map 1:1 to prior values (W0), so a bad token value is a one-line CSS-var revert affecting
  only color, not structure.
- Keep the deprecated twins in-tree until their last call site is migrated; if a new component proves
  wrong in production, flip the import back to the `@deprecated` original (still present) and iterate
  the component behind its stable API — call sites don't change.
- Each wave is independently shippable; a wave can be paused mid-flight (some pages migrated, some
  not) because coexistence is designed in.

## 6. Definition of done (ties to the quality bar)

- Every `01-inventory.csv` row is migrated, marked one-off, or deleted — no unexplained gaps.
- 0 raw hex / arbitrary tokenized values / native controls outside `@ui/*` (CI green).
- Every interactive component has a visible focus ring and documented keyboard behavior.
- One page-header dialect, one content-width ramp, one card radius across all routes.
