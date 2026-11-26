# Live Home Task chains and coordinator chat

Replace the Home Task chains widget's fixture data with the existing authenticated task-chain APIs. Opening a chain should open its current coordinator conversation through the existing chain-addressed route. Preserve the approved widget design, three-card pagination, and mobile edit controls.

This is a proposed plan for user review. Implementation starts only after approval. Source inspection confidence: 95%; live integration evidence will be gathered during implementation.

## Verified baseline

Baseline: `0a9bf9610d6b1b907055a52ffd4f623118f56e49`, following approved T7/T8 and the mobile Home follow-up. Planning task: `task_18eb47b81980b910`. User request: `msg_18eb47911be77198`.

| Existing seam | Verified behavior |
| --- | --- |
| `src/ui/components/home/TaskChainsWidget.tsx` | Uses fixture-backed Home list/detail hooks; title currently links to the chain page. |
| `src/ui/api/endpoints/home.ts` | `getHomeTaskChains` and `getHomeChainDetail` call fixtures. Their route comments describe a proposed shape, not the current server contract. |
| `src/ui/api/endpoints/tasks.ts:562` | `fetchHomeTaskChains` already reads the complete owner-scoped flat list through cookie authentication, validates rows, normalizes metadata and supports vault decryption. |
| `src/hub/transport/http/taskchain_handlers.odin:803` | `GET /api/v1/task-chains?flat=1` returns the complete ungrouped visible list when no paging parameters are supplied. Default responses are project-grouped. |
| `src/hub/transport/http/taskchain_handlers.odin:1034` | List enrichment includes project, coordinator, total/completed task counts and user-validation count; it excludes archived chains/projects by default. Public chain statuses are active/completed/cancelled/archived. |
| `src/ui/api/endpoints/tasks.ts:719` | `fetchTaskChainDetail` reads real tasks/members and normalizes their names and fields. It provides `Chain` and `ChainTasks` cache tags. |
| `src/ui/utils/chainConversation.ts` | Existing coordinator resolver handles missing list IDs via detail membership. Chain links use chain identity, not a captured instance ID. |
| `src/ui/utils/paneTarget.ts` | Existing `chainConversationRoute` produces the route for the chain's coordinator chat. The conversation pane resolves the current coordinator through `GET /task-chains/{id}/conversation`. |
| `src/ui/components/home/HomeChainSearch.tsx:138`, `src/ui/components/shell/SidebarTaskChains.tsx:99` | Existing navigation examples open coordinator chat and fall back to chain details when no coordinator exists. |
| `src/ui/api/wsInvalidation.ts:1010` | Task events refresh the shared list; chain events refresh list/detail tags. Visible widget progress must also respond to task-state changes without polling. |

## Requirements

- **REQ-HCHAIN-1 — Real data.** Production Home uses `tasksApi.fetchHomeTaskChains` and the existing real detail endpoint. Remove the two production Home chain fixture endpoints or all their production consumers. Fixtures remain explicit test/visual inputs only. Errors never fall back to sample chains.
- **REQ-HCHAIN-2 — Active list and pages.** Show active chains returned by the existing owner-scoped API, newest `updated_at` first with chain ID as deterministic tie-breaker. Derive the active total before slicing three cards per page. Exclude terminal chains; retain active zero-ticket chains as a truthful zero-progress state. Clamp the page synchronously when refresh removes rows, including an empty result. Preserve All chains and New conversation links.
- **REQ-HCHAIN-3 — Honest metadata and progress.** Render actual project, coordinator and bridge names through the existing vault-safe presentation. Fetch details only for visible cards, sharing RTK cache entries. Count actual done/in-review/in-progress tasks; use the same task set for denominator and segments. An unavailable detail shows progress unavailable/retry, not fabricated zeros. User-validation attention yields Needs review; otherwise active yields Running. An agent-only review still appears in the review progress segment. Preserve existing task-count semantics rather than inventing a new work-scope denominator.
- **REQ-HCHAIN-4 — Coordinator chat.** The chain title/card's primary link opens `chainConversationRoute(chainId)` through the existing shell navigation. Reuse existing resolution when the list lacks a coordinator ID. Preserve native link behavior, keyboard activation and modifier/open-in-new-tab behavior. Chain-addressed navigation must follow coordinator replacement and preserve the conversation/Tasks context. A genuinely missing coordinator falls back to the chain page. Resolution errors must not be presented as proof that a coordinator does not exist; keep a usable chain link and retry/error feedback.
- **REQ-HCHAIN-5 — Live changes.** Reuse the existing user WebSocket/cache invalidation path for task transitions, chain creation/closure, title changes and coordinator replacement. Ensure visible progress detail refreshes when its tasks change, with existing coalescing and request deduplication. No new polling loop, per-chain instance list, or aggregate Home API. Account changes must not display the previous owner's cached rows.
- **REQ-HCHAIN-6 — Preserve approved UI.** Keep current tokens, headings, badges, progress legend, three-row pager, independent loading/error/empty states and debug IDs. Preserve desktop drag/layout and mobile Add widget sheet/up/down controls. Whole-card activation, if used, must avoid nesting pager or edit controls inside a link.

## API choice and bounded work

Reuse the existing complete flat-list query and page that snapshot locally. This is a proposed adjustment to the original Home spec's future `status=active&limit=3&cursor=` contract: the current server does not return that documented Home page shape or its total, whereas the existing flat endpoint already supports the information needed for an accurate total and local pages. Do not send unsupported filters and assume they were honored.

Use at most three mounted card-detail subscriptions for the visible page. Do not load every chain's tasks or add per-member runtime requests. Reuse normalized detail members for coordinator metadata; use an existing bridge query/cache only if a bridge label is unavailable. The full list remains the existing endpoint's cost, not a new backend data model. If measured account size makes this unsuitable, report the evidence and propose a separate paginated contract rather than silently adding backend scope.

This increment covers Task chains only. Activity history, bridge uptime, persisted layout, Fleet implementation and release/deployment retain their existing plans. No migration, new endpoint, new CLI command, or live restart is required here.

## Delegated implementation and review

After plan approval, create one focused implementation ticket, assigned to reusable worker `agt_18dbb3d25b612dcd`, independently reviewed by `agt_18e5281575868be4`.

The ticket depends on this planning task and Fleet UI task `task_18eb3f33bc842e1b`. The dependency serializes shared edits to `home.ts`, Home components and widget tests; it does not alter Fleet's requirements or block Fleet verification. Use the actual approved F3 head as the implementation baseline and retain mobile head `0a9bf9610` in its ancestry. If F3 changes these seams, reconcile them before editing.

Primary files:

- `src/ui/components/home/TaskChainsWidget.tsx`: real hooks, normalized data, navigation, visible detail states.
- `src/ui/components/home/widgetData.ts`: active filtering, pagination and progress helpers where needed.
- `src/ui/api/endpoints/home.ts`: retire the two chain fixture seams while preserving other widgets' current state.
- `src/ui/api/endpoints/tasks.ts`: reuse normalized list/detail endpoints; make only justified additive shared changes.
- `src/ui/utils/chainConversation.ts`, `src/ui/utils/paneTarget.ts`: reuse the existing navigation contract; any helper change must preserve other callers.
- `src/ui/api/wsInvalidation.ts`: narrow reuse/addition needed to refresh visible chain progress without duplicate requests.
- `src/ui/components/home/HomePage.css`: only if needed to preserve accessible card/link presentation.
- `tests/ui_home_widgets_test.ts`, `tests/ui_home_chain_search_test.ts`, `tests/ui_vault_home_decryption_test.ts`, and a focused widget integration test if appropriate; `tests/fixtures/home-widgets/{main.tsx,capture.mjs}` for explicitly supplied visual data.

Do not implement backend changes under this ticket. Any discovered missing contract gets a concrete finding and a separately scoped decision.

## Acceptance and evidence

The worker chooses checks and submits early after committing and requesting the designated Test Runner (`inst_18eb3898cd87d012`). Existing suites run only through that Runner. The independent reviewer judges source, exact-head results and visual/navigation evidence.

Required behavioral evidence:

1. Real wire-shaped API responses, no fixture import in the production chain path; cookie auth, owner isolation/cache reset and malformed/error responses covered.
2. More than three active chains across projects: correct total/order/pages, zero tasks, terminal/archived exclusion, page shrink to fewer/zero rows, and retry after list/detail failures.
3. Real task-state transitions update progress and attention without reloading the page or polling; hidden pages cause no new detail requests. Requests remain bounded and deduplicated during a WebSocket event burst.
4. Coordinator click works by mouse, keyboard and native link navigation. A list row without an ID resolves membership; replacing the coordinator still opens the same chain-addressed chat. No coordinator and failed resolution are handled distinctly.
5. Vault locked/unlocked titles, project names and member display names remain safe; no ciphertext leaks into labels. Switching accounts clears the previous account's view.
6. Desktop 1440px and mobile 390px browser evidence with zero horizontal overflow or console errors; approved sheet, arrows, edit controls, links and layout remain usable. Detail unavailability does not break other widgets.
7. Exact final commit UI/typecheck/build evidence, relevant existing navigation/vault/layout regression results, and independent approval. No claim of live deployment or backend runtime verification from a fixture capture.

## Risks and decisions

| Risk | Planned handling |
| --- | --- |
| Mock Home types differ from normalized live detail | Consume the existing normalized `tasksApi` shape; do not cast raw fixture shape to live list/detail types. |
| List counts and detail arrive at different times | Render pending/unavailable states truthfully; calculate progress from one coherent task snapshot. |
| Global task events refresh list but not visible details | Extend existing narrow tags/coalescing as needed; verify both progress freshness and duplicate-request limits. |
| Missing or stale coordinator ID | Use chain-addressed routing and existing resolution; avoid pinning the link to an ephemeral instance. |
| Full flat list grows large | Reuse the existing snapshot now; escalate with measured evidence before a separate paginated API change. |
| Concurrent Fleet edits | Implement after approved F3, then reconcile its actual head. |

Approval of this plan authorizes the described delegated source changes and review, with implementation completion reported after independent approval. Pushing, deploying or releasing remains a separate user decision.
