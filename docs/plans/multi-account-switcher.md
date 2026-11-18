# Multi-Account Switcher (Webapp & Electron)

Status: Proposed (Step 1 Specification)

## 1. Goal & Scope

Support signing into multiple Heimdall accounts concurrently on the same browser or Electron desktop app and switching between them without re-authenticating at the OIDC provider:

1. **Multi-Account Session Ring (`__Host-heimdall_sessions`)**: Retain up to `MAX_BROWSER_ACCOUNTS = 5` concurrent server-side browser sessions in an HttpOnly cookie ring alongside the active `__Host-heimdall_session` cookie. Raw session tokens never reach JavaScript.
2. **Active-Account-Only WebSocket Connection**: Only the currently selected (active) account holds a WebSocket connection (`/api/v1/user-ws` and on-demand PTY/tool/LSP streams) and an unlocked `VaultKeyring` in memory. Deselected accounts hold **no** WebSocket connections and **no** in-memory vault keys.
3. **Non-Destructive Account Switching**: Switching accounts tears down the outgoing account's WebSockets, `mcpWorker`, in-memory `VaultKeyring`, and Redux/RTK Query state while preserving `localStorage` state across switches.
4. **Account Switcher UI & Electron OIDC Handoff**: Provide an interactive Account Switcher in the sidebar footer (`shell-sidebar-account`) and Settings `AccountPanel`, and route Electron "Add account" flows (`/api/v1/auth/login?add_account=1`) directly into the preload-free `openOidcWindow` popup without disrupting `mainWindow`.

---

## 2. Requirements

- **`REQ-ACCT-RING-1` (Session Cookie Ring)**:
  - Keep `__Host-heimdall_session` (`SESSION_COOKIE`) as the active account's opaque 32-byte base64url session token so all existing REST, WebSocket, and preview endpoints remain unchanged.
  - Add `__Host-heimdall_sessions` (`SESSIONS_RING_COOKIE`, `Path=/; Secure; HttpOnly; SameSite=Lax`) storing up to `MAX_BROWSER_ACCOUNTS = 5` raw session tokens joined by `.` in MRU order (active token first).
  - Deduplicate the ring by `user_id`: if a user signs in to an account that already has a session in the ring, delete the old session row from `user_sessions` (and call `preview_end_for_parent`) and replace it with the new token.
  - If adding a new account exceeds `MAX_BROWSER_ACCOUNTS = 5`, evict the oldest deselected token from the ring and delete its row from `user_sessions` (and `preview_end_for_parent`).
  - Raw session tokens must never appear in any JSON response body.
- **`REQ-ACCT-RING-2` (Add Account OIDC Prompt)**:
  - `GET /api/v1/auth/login` accepts optional query parameter `add_account=1` (or `prompt=login`).
  - When `add_account=1` or `prompt=login` is present, `web_login_begin` appends `{"prompt", "login"}` to the OIDC provider authorization URL query so the IdP prompts for credentials instead of reusing the current SSO session.
  - `GET /api/v1/auth/callback` merges the newly created session with any live sessions from the request's `__Host-heimdall_session` and `__Host-heimdall_sessions` cookies, sets `__Host-heimdall_session` to the new session, and sets `__Host-heimdall_sessions` to the merged MRU ring.
- **`REQ-ACCT-RING-3` (List, Switch, and Logout Endpoints)**:
  - `GET /api/v1/auth/sessions`: Validates all tokens in `__Host-heimdall_session` + `__Host-heimdall_sessions` against `user_sessions`, prunes expired/revoked/inactive-user tokens (emitting an updated `Set-Cookie: __Host-heimdall_sessions=...` when any token was pruned or when the ring cookie was absent for a valid `__Host-heimdall_session`), and returns `{ active_user_id, accounts: [{ user_id, name, display_name, email, active, expires_at_ms }] }`.
  - `POST /api/v1/auth/switch` (CSRF-checked via `csrf_decide`): Accepts `{"user_id": "usr_..."}`. Looks up the live session for `user_id` in `__Host-heimdall_session` + `__Host-heimdall_sessions`. Returns `400 validation_failed` if `user_id` is empty, or `404 not_found` if no live session for `user_id` exists in the ring. Otherwise touches `last_seen_at_ms`, promotes that token to `__Host-heimdall_session`, updates MRU order in `__Host-heimdall_sessions`, and returns `{ active_user_id, user, accounts }`.
  - `POST /api/v1/auth/logout` (CSRF-checked): Accepts optional JSON body `{"user_id"?: "usr_...", "all"?: bool}` (an empty or `{}` body defaults to signing out the active account):
    - If `all == true` or no other live accounts remain in the ring after removing the target session: deletes all target/ring sessions in `user_sessions`, calls `preview_end_for_parent` for each, expires both `__Host-heimdall_session` and `__Host-heimdall_sessions`, and returns `{ logout_url, active_user_id: "", switched_user: null, accounts: [] }`.
    - If signing out one account (`user_id` or the active account) while at least one other live account remains in the ring: deletes only that account's session from `user_sessions` and `preview_end_for_parent`, removes it from `__Host-heimdall_sessions`, promotes the next live token in the ring to `__Host-heimdall_session` if the active account was signed out, and returns `{ logout_url: "", active_user_id, switched_user, accounts }`.
- **`REQ-ACCT-WS-1` (Active-Account-Only WebSocket)**:
  - Only the active account opens `/api/v1/user-ws` (`useUserWebSocket`) and on-demand PTY/tool/LSP streams (`useShellStream`, `useAgentStream`, `useToolActivityStream`, `LspClient`).
  - Deselected accounts hold no WebSocket connection.
  - On account switch, the outgoing account's `AuthenticatedShell` unmounts (or resets by `key={activeUserId}`), immediately closing its `/api/v1/user-ws` socket, calling `setMcpWorkerEnabled(false)`, and closing any open stream sockets before the newly selected account connects.
- **`REQ-ACCT-UI-1` (Client Persistence & Vault Isolation on Switch)**:
  - Switching accounts in `AuthGate` (`src/ui/components/shell/AppShell.tsx`) must **not** call `removeAppOwnedClientStorage()`.
  - Instead, switching accounts:
    1. Saves the outgoing user's current route hash via `writeUserLastRoute(previousUserId, currentRoute)`.
    2. Calls `stopDeviceVault(dispatch)` to zero and purge the outgoing user's in-memory `VaultKeyring` and search key (`clearKeyringSession()`).
    3. Resets in-memory RTK Query and Redux state (`dispatch(heimdallApi.util.resetApiState())`, `dispatch(priorUserClientStateCleared())`, `dispatch(clearUserClientState({ userId: nextUserId }))`).
    4. Updates `writeLastSeenUserId(nextUserId)`, restores `readUserLastRoute(nextUserId)` (defaulting to `/home` if the current route is a user-specific `/conversations/...` or `/chains/...` route from the previous account), and calls `bootDeviceVault(nextUserId, dispatch)`.
  - Explicit sign-out of a single account calls `removeUserClientStorage(userId)` (deleting `heimdall.user.<encodeURIComponent(userId)>.*` keys). Signing out when no accounts remain (or `all: true`) calls `removeAppOwnedClientStorage()`.
  - When a user initiates **"Add another account"** from the UI, record a short-lived local intent flag (`recordAddAccountIntent()`) so `deviceVault.ts` can automatically acknowledge `otherPinnedAccounts` (`acknowledgeOtherAccount`) for the newly added account without blocking on a false-positive TOFU swap warning.
- **`REQ-ACCT-UI-2` (Account Switcher UI)**:
  - Replace the static footer row in `src/ui/components/shell/AppShell.tsx` (`shell-sidebar-account`) with `AccountSwitcher` (`src/ui/components/shell/AccountSwitcher.tsx`), supporting both expanded and collapsed sidebar states and mobile drawer mode.
  - Render all signed-in accounts in `AccountSwitcher` and in `src/ui/components/settings/AccountPanel.tsx` with interactive controls and required `data-debug-id` attributes.
- **`REQ-ACCT-ELECTRON-1` (Electron Add-Account Popup Handoff)**:
  - In `src/ui/electron/externalUrl.cts` and `src/ui/electron/main.cts`, classify a navigation to `/api/v1/auth/login` that carries `add_account=1` (or `prompt=login`) as `'auth'` on `will-navigate` so `mainWindow` calls `event.preventDefault()` and opens `openOidcWindow(url, win)` directly without navigating `mainWindow` away from the active account while the login popup is open.

---

## 3. Detailed Design & Wire Contracts

### 3.1 Hub Auth & Session Ring (`src/hub/service/auth/session.odin`, `src/hub/transport/http/auth_session_handlers.odin`, `src/hub/transport/http/user_handlers.odin`, `src/hub/app/wiring.odin`)

#### Constants & Types (`src/hub/service/auth/session.odin`)
```odin
SESSION_COOKIE :: "__Host-heimdall_session"
SESSIONS_RING_COOKIE :: "__Host-heimdall_sessions"
MAX_BROWSER_ACCOUNTS :: 5
```

- **Ring Cookie Encoding**:
  - Value format: `<raw_token_1>.<raw_token_2>...` where each `<raw_token_i>` is a 32-byte unpadded base64url session token (`32..=128` ASCII characters, no `.` or `;`).
  - `sessions_ring_cookie_header(raw_sessions: []string, max_age_seconds: i64) -> string`:
    - If `len(raw_sessions) == 0`, returns `expired_cookie_header(SESSIONS_RING_COOKIE)`.
    - Otherwise joins `raw_sessions` with `"."` and formats:
      `__Host-heimdall_sessions=<joined>; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=<max_age_seconds>`.
  - `parse_sessions_ring(headers: []contracts.HTTP_Header) -> [dynamic]string`:
    - Reads `SESSION_COOKIE` (if present and valid length) first, then splits `cookie_value(headers, SESSIONS_RING_COOKIE)` on `'.'`.
    - Deduplicates raw token strings while preserving order, using `context.temp_allocator`.

#### Resolved Ring Entry (`src/hub/service/auth/session.odin`)
```odin
Auth_Account_Entry :: struct {
	user_id:       string,
	name:          string,
	display_name:  string,
	email:         string,
	active:        bool,
	expires_at_ms: i64,
}
```
- `resolve_session_ring(service: ^Auth_Service, headers: []contracts.HTTP_Header) -> (active_raw: string, raw_ring: [dynamic]string, accounts: [dynamic]Auth_Account_Entry, changed: bool)`:
  - Iterates candidate raw tokens from `SESSION_COOKIE` + `SESSIONS_RING_COOKIE`.
  - Validates each via `resolve_session_auth(service, raw_token)`.
  - If invalid/expired, marks `changed = true` and skips it.
  - If valid, checks if `ctx.user_id` is already in `accounts`:
    - If already present (duplicate session for same user), deletes the duplicate session row in `service.sessions`, calls `preview_end_for_parent`, marks `changed = true`, and keeps the earlier (more recent) one.
    - If `len(accounts) == MAX_BROWSER_ACCOUNTS`, deletes the overflow session row in `service.sessions`, calls `preview_end_for_parent`, and marks `changed = true`.
    - Otherwise appends to `raw_ring` and `accounts` (`active = (len(accounts) == 0)` when `SESSION_COOKIE` matched, or promotes the first live session if `SESSION_COOKIE` was missing/expired).

#### OIDC Login Prompt & Callback Merge
- `web_login_begin(service: ^Auth_Service, return_to: string, client_ip := "", prompt_login := false) -> (redirect_url: string, login_cookie: string, ok: bool, err: domain.Domain_Error)`:
  - In `auth_login_handler` (`src/hub/transport/http/auth_session_handlers.odin:34-45`), check `query_value(req.query, "add_account") == "1" || query_value(req.query, "prompt") == "login"`.
  - When `prompt_login` is true, include `{"prompt", "login"}` in `httpc.build_url` query params for `service.web.authorize_url`.
- `auth_callback_handler` (`src/hub/transport/http/auth_session_handlers.odin:48-74`):
  - After `web_login_complete` returns `raw_session` and `return_to`:
  - Call `merge_session_into_ring(handlers.auth, req.headers, raw_session)`, which:
    - Resolves existing live tokens from `req.headers`.
    - If any existing token in the ring belongs to the same `user_id` as `raw_session`, deletes that old session from `service.sessions` and `preview_end_for_parent`.
    - Places `raw_session` at index 0, followed by up to `MAX_BROWSER_ACCOUNTS - 1` remaining live tokens (deleting any evicted 6th session from `service.sessions` and `preview_end_for_parent`).
  - Emits `Set-Cookie` headers for `session_cookie_header(raw_session, ttl / 1000)`, `sessions_ring_cookie_header(ring, ttl / 1000)`, and `clear_login`.

#### Wire Endpoints (`src/hub/transport/http/auth_session_handlers.odin` & `wiring.odin`)
Register in `src/hub/app/wiring.odin`:
```odin
http.router_add(&graph.router, "GET", "/api/v1/auth/sessions", rawptr(&graph.user_handlers), http.auth_sessions_handler)
http.router_add(&graph.router, "POST", "/api/v1/auth/switch", rawptr(&graph.user_handlers), http.auth_switch_handler)
```

1. **`GET /api/v1/auth/sessions` (`auth_sessions_handler`)**:
   - Calls `resolve_session_ring(handlers.auth, req.headers)`.
   - Returns `200 OK` (even when `accounts` is empty so the UI can inspect the ring cleanly without a 401 console error, or when authenticated):
     ```json
     {
       "data": {
         "active_user_id": "usr_1",
         "accounts": [
           {
             "user_id": "usr_1",
             "name": "alice",
             "display_name": "Alice",
             "email": "alice@example.com",
             "active": true,
             "expires_at_ms": 1760000000000
           }
         ]
       }
     }
     ```
   - If `changed` is true (e.g. an expired token was pruned or active session was promoted), attaches `Set-Cookie` for `SESSION_COOKIE` and `SESSIONS_RING_COOKIE`.

2. **`POST /api/v1/auth/switch` (`auth_switch_handler`)**:
   - Request body: `{"user_id": "usr_2"}` (parsed via `json.unmarshal_string` or `jsonx`).
   - If `user_id == ""` -> `400 validation_failed` (`"user_id is required"`).
   - Calls `web_switch_account(handlers.auth, req.headers, target_user_id)`:
     - Resolves the ring from `req.headers`.
     - If no live session in the ring matches `target_user_id` -> `404 not_found` (`"account session not found or expired"`).
     - Moves `target_user_id`'s raw token to index 0 of the ring, touches its `last_seen_at_ms`, and marks its `Auth_Account_Entry.active = true` (others `false`).
   - Emits `Set-Cookie` for `session_cookie_header(active_raw, ttl / 1000)` and `sessions_ring_cookie_header(ring, ttl / 1000)` plus `Cache-Control: no-store`.
   - Response `200 OK`:
     ```json
     {
       "data": {
         "active_user_id": "usr_2",
         "user": {
           "user_id": "usr_2",
           "name": "bob",
           "display_name": "Bob",
           "email": "bob@example.com"
         },
         "accounts": [ ... ]
       }
     }
     ```

3. **`POST /api/v1/auth/logout` (`auth_logout_handler`)**:
   - Optional JSON body: `{"user_id"?: "usr_...", "all"?: bool}`.
   - Calls `web_logout_ring(handlers.auth, req.headers, target_user_id, logout_all)`:
     - When `logout_all == true` or only one account (the target/active one) is in the ring:
       - Deletes every removed session from `service.sessions` and `preview_end_for_parent`.
       - Builds `logout_url` (with `id_token_hint` from the active/target session when `service.web.end_session_url != ""`, else `"/"`).
       - Expires both `SESSION_COOKIE` and `SESSIONS_RING_COOKIE`.
       - Returns:
         ```json
         {
           "data": {
             "logout_url": "https://...",
             "active_user_id": "",
             "switched_user": null,
             "accounts": []
           }
         }
         ```
     - When signing out a single account (`target_user_id` or active account) and at least one other live session remains in the ring:
       - Deletes only the target session from `service.sessions` and `preview_end_for_parent`.
       - Keeps the remaining live sessions in `SESSIONS_RING_COOKIE`, with `ring[0]` set as `SESSION_COOKIE`.
       - Returns `logout_url: ""` (so the browser stays in-app on the remaining account instead of redirecting to the IdP end-session page!) along with `active_user_id`, `switched_user`, and `accounts`.

---

### 3.2 Client Persistence, Vault & WebSocket Teardown (`src/ui/`)

#### `src/ui/auth/oidcSession.ts`
Add pure, unit-tested helpers:
- `export type AuthSessionAccount = { user_id: string; name: string; display_name: string; email: string; active: boolean; expires_at_ms: number };`
- `export function addAccountHref(location: LocationLike): string`:
  - Returns `${LOGIN_PATH}?add_account=1&return_to=${encodeURIComponent(currentReturnTo(location))}`.
- `export async function fetchAuthSessions(fetchImpl: typeof fetch, url = '/api/v1/auth/sessions'): Promise<{ activeUserId: string; accounts: AuthSessionAccount[] }>`
- `export async function postSwitchAccount(fetchImpl: typeof fetch, userId: string, url = '/api/v1/auth/switch'): Promise<{ activeUserId: string; user: AuthUserIdentity | null; accounts: AuthSessionAccount[] }>`
- `export async function postLogoutAccount(fetchImpl: typeof fetch, opts?: { userId?: string; all?: boolean }, url = LOGOUT_PATH): Promise<{ logoutUrl: string; activeUserId: string; switchedUser: AuthUserIdentity | null; accounts: AuthSessionAccount[] }>`
  - Keep existing `postLogout(fetchImpl, url)` signature returning `Promise<string>` (`logout_url || '/'`) for backwards compatibility with `tests/ui_oidc_session_test.ts`.

#### `src/ui/utils/clientPersistence.ts`
- Add per-user storage cleanup and route/add-account intent helpers:
  - `export function removeUserClientStorage(userId: string): void`:
    - Removes keys starting with `heimdall.user.${encodeURIComponent(userId)}.` from `localStorage` and `sessionStorage`.
  - `export function readUserLastRoute(userId: string): string`:
    - Reads `userScopedStorageKey('lastRoute', userId)` from `localStorage`.
  - `export function writeUserLastRoute(userId: string, routeHash: string): void`:
    - Writes `userScopedStorageKey('lastRoute', userId)` to `localStorage`.
  - `export const ADD_ACCOUNT_INTENT_KEY = 'heimdall:add-account-intent-at';`
  - `export const ADD_ACCOUNT_INTENT_TTL_MS = 10 * 60_000;`
  - `export function recordAddAccountIntent(now = Date.now()): void` and `export function consumeAddAccountIntent(now = Date.now()): boolean`.

#### `src/ui/services/deviceVault.ts`
- In `refuseUnacknowledgedAccount(c: Ctx)` (`src/ui/services/deviceVault.ts:636-642`):
  - If `consumeAddAccountIntent()` returns `true`, automatically call `await acknowledgeOtherAccount(d().kv, c.userId)` and return `false` so a user who explicitly clicked "Add another account" is not blocked on the `other-account` warning screen.

#### `src/ui/components/shell/AppShell.tsx`
- Update `clearPriorUserClientState(dispatch: any, nextUserId: string)`:
  - Do **not** call `removeAppOwnedClientStorage()` on account switch.
  - Call `stopDeviceVault(dispatch)`, `dispatch(heimdallApi.util.resetApiState())`, `dispatch(priorUserClientStateCleared())`, and `dispatch(clearUserClientState({ userId: nextUserId }))`.
- In `AuthGate`:
  - Track `accounts: AuthSessionAccount[]` alongside `auth: AuthState`.
  - Fetch `/api/v1/auth/sessions` during `refreshIdentity` (after `/api/v1/me` succeeds) to populate `accounts`.
  - Provide an `AuthAccountsContext` (or pass via `AuthUserContext` / props) exposing:
    - `accounts: AuthSessionAccount[]`
    - `switchAccount: (targetUserId: string) => Promise<void>`
    - `addAccount: () => void`
    - `signOutAccount: (opts?: { userId?: string; all?: boolean }) => Promise<void>`
  - When `switchAccount(targetUserId)` runs:
    1. Save current route hash for `currentUserId` via `writeUserLastRoute(currentUserId, window.location.hash)`.
    2. Call `postSwitchAccount(fetch, targetUserId)`.
    3. Call `clearPriorUserClientState(dispatch, targetUserId)` and `analytics.identify(targetUserId)`.
    4. Write `writeLastSeenUserId(targetUserId)` and update `lastSeenUserRef.current = targetUserId`.
    5. Navigate `window.location.hash` to `readUserLastRoute(targetUserId) || '#/home'`.
    6. Call `void bootDeviceVault(targetUserId, dispatch)` and update `auth` + `accounts` state, which remounts `<AuthenticatedShell key={targetUserId} />` (tearing down the previous account's `/api/v1/user-ws` and opening the new account's `/api/v1/user-ws`).
  - When `signOutAccount({ userId, all })` runs:
    - If signing out a specific account while other accounts remain:
      - Call `removeUserClientStorage(targetUserId)`.
      - If `switchedUser` is returned (the active account was signed out), transition in-place to `switchedUser` using the same state reset + `bootDeviceVault` flow.
      - If a deselected account was signed out, simply update `accounts` state in place.
    - If no accounts remain (or `all: true`):
      - Call `stopDeviceVault(dispatch)`, `removeAppOwnedClientStorage()`, `analytics.reset()`, and `window.location.assign(logoutUrl || '/')`.

---

### 3.3 Account Switcher UI (`src/ui/components/shell/AccountSwitcher.tsx` & `src/ui/components/settings/AccountPanel.tsx`)

#### Sidebar `AccountSwitcher.tsx`
- Replaces the bottom account block inside `shell-sidebar-account` in `AppShell.tsx`.
- **Debug IDs**:
  - Trigger button: `data-debug-id="shell-open-account"` (or `data-debug-id="account-switcher-trigger"` while preserving `shell-open-account` inside the menu or on the trigger as appropriate — check existing tests!).
  - Wait — let's preserve existing `data-debug-id`s in `shell-sidebar-account` (`shell-global-ownership-points`, `shell-user-ws-owner`, `shell-open-account`, `shell-current-user-owner`, `auth-logout-link`, `shell-subscription-tier`) so no existing sidebar test breaks, and add:
    - `data-debug-id="account-switcher-toggle"` (button to open/close the account switcher popover)
    - `data-debug-id="account-switcher-menu"` (popover container)
    - `data-debug-id="account-switcher-item-<user_id>"` (row to switch to `<user_id>`)
    - `data-debug-id="account-switcher-logout-<user_id>"` (button to sign out `<user_id>`)
    - `data-debug-id="account-switcher-add-account"` (button to add another account)
    - `data-debug-id="account-switcher-logout-all"` (button to sign out all accounts when `accounts.length > 1`)
- **Settings `AccountPanel.tsx`**:
  - Add a **Signed-in accounts** section (`data-debug-id="account-panel-sessions"`) listing all accounts in the session ring with **Active** badge on the current account, **Switch** button (`data-debug-id="account-panel-switch-<user_id>"`) and **Sign out** button (`data-debug-id="account-panel-logout-<user_id>"`) on deselected accounts, plus **Add another account** (`data-debug-id="account-panel-add-account"`) and **Sign out all accounts** (`data-debug-id="account-panel-logout-all"`).

---

### 3.4 Electron OIDC Popup Handoff (`src/ui/electron/externalUrl.cts`, `src/ui/electron/main.cts`)

- In `src/ui/electron/externalUrl.cts`:
  - Add `isAddAccountAuthUrl(value: unknown, uiOrigin: string): boolean`:
    - Returns `true` when `url.origin === originOf(uiOrigin)`, `url.pathname.startsWith('/api/v1/auth/login')`, and `url.searchParams.get('add_account') === '1' || url.searchParams.get('prompt') === 'login'`.
  - In `classifyNavigation(value: unknown, context: NavigationContext): NavigationRoute`:
    - Before returning `'allow'` for `url.origin === originOf(context.uiOrigin)`, if `isAddAccountAuthUrl(url.href, context.uiOrigin)` is `true`, return `'auth'`.
  - Effect in `src/ui/electron/main.cts`:
    - When the renderer in `mainWindow` navigates to `/api/v1/auth/login?add_account=1&return_to=...`, `will-navigate` classifies the route as `'auth'`, calls `event.preventDefault()`, and invokes `openOidcWindow(url, win)`.
    - `mainWindow` remains on the current account (keeping its WebSocket alive unless/until the popup finishes login).
    - `loginWindow` loads `/api/v1/auth/login?add_account=1...`, receives `__Host-heimdall_login` in the shared `session.defaultSession` cookie jar, redirects to the IdP with `prompt=login`, completes `/api/v1/auth/callback` (updating `__Host-heimdall_session` and `__Host-heimdall_sessions`), and commits navigation to `return_to` on `configuredUiOrigin()`, at which point `finishIfReturned` closes `loginWindow` and reloads `mainWindow` at `returnUrl`.

---

## 4. Verification Plan

1. **Hub Unit Tests (`src/hub/transport/http/oidc_session_test.odin`)**:
   - Logging in with `add_account=1` includes `prompt=login` in the redirect Location header and merges the new session into `__Host-heimdall_sessions` while keeping the first account's session live.
   - Re-logging into an already-present account replaces its old session in `user_sessions` without duplicating the user in `__Host-heimdall_sessions`.
   - Adding a 6th account evicts the oldest deselected session and deletes it from `user_sessions`.
   - `GET /api/v1/auth/sessions` returns all live accounts in MRU order and prunes expired/deleted sessions.
   - `POST /api/v1/auth/switch` enforces CSRF, switches `__Host-heimdall_session` to the requested `user_id`, and rejects unknown/expired `user_id`s.
   - `POST /api/v1/auth/logout` with a single `user_id` deletes only that session and promotes the next account in the ring without expiring the remaining sessions; `all: true` deletes all sessions in the ring and expires both cookies.
2. **UI & Electron Unit Tests (`tests/ui_oidc_session_test.ts`, `tests/ui_desktop_oidc_handoff_test.ts`, `tests/ui_workspace_persistence_test.ts`)**:
   - `addAccountHref`, `fetchAuthSessions`, `postSwitchAccount`, and `postLogoutAccount` unit tests.
   - `removeUserClientStorage`, `readUserLastRoute`, `writeUserLastRoute`, and `recordAddAccountIntent` / `consumeAddAccountIntent` unit tests.
   - `classifyNavigation` routes `/api/v1/auth/login?add_account=1&return_to=%2F%23%2Fhome` on `uiOrigin` to `'auth'` (opening `openOidcWindow`), while keeping normal `/api/v1/auth/login` and UI routes as `'allow'`.
   - `npm run typecheck` and `npm test` pass.
