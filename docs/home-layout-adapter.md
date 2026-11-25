# Home layout adapter (UI phase)

The dashboard persists a `HomeLayout` with `{version, widgets[]}` through `HomeLayoutAdapter` in `src/ui/components/home/homeLayout.ts`. Each widget has `id`, stored `width` (1 or 2), `hidden`, and optional `options`. Rows are derived greedily; auto-stretch never changes stored width. Hidden widgets retain their array position.

The UI-phase adapter uses browser localStorage at `heimdall:home-layout:<encoded user_id>`. It isolates accounts and survives reloads and other tabs in the same browser; synchronization across devices awaits T4. Unknown widget IDs and duplicates are dropped on read, malformed values fall back to defaults, and newly introduced known widgets are appended with their defaults.

Desktop order is the array order. Mobile excludes Activity and orders the other widgets by optional `options.mobile_order` ranks. Missing ranks use Uptime, Task chains, Fleet. Mobile reordering assigns ranks without changing desktop order, visibility, or widths. Reset layout restores default widgets, widths, visibility, and both orders.

`load(userId)` returns the accepted layout. `save(userId, layout, expectedVersion)` atomically checks the expected version and returns a layout with the next version. A stale version rejects with an error whose `status` is `409`. T4 can replace this adapter with GET/PUT `/api/v1/me/home-layout` and an `If-Match` header while keeping the session and view unchanged.

`HomeLayoutSession` debounces for 500 ms after the last edit, serializes writes, preserves edits made during a slow save, and flushes pending edits on navigation/account switching. A save failure rolls back to the last accepted layout, discards queued edits, and exposes a message with a reload action. A 409 has distinct conflict feedback; reloading obtains the latest accepted version before further edits. Anonymous fixture views do not write a shared account key.

LocalStorage checks run synchronously within one adapter write; the adapter is provisional and does not promise transactional writes between independently scheduled browser processes. Server-side If-Match in T4 provides authoritative cross-device conflict detection.

Focused tests: `tests/ui_home_layout_test.ts`. The real dashboard visual fixture is `tests/fixtures/home-widgets/index.html`; `capture.mjs <output-dir> [1440,390]` drives a headless Chromium CDP endpoint on port 9338 (override `HOME_CDP_PORT`) against Vite on port 5188 (override `HOME_FIXTURE_ORIGIN`). It captures normal, edit, Fleet-expanded and widget-empty states and verifies native keyboard reorder and reload persistence.
