# Multi-Account Switcher (Webapp & Electron)

Status: Proposed (Step 1 Specification)

## 1. Goal & Scope

Support signing into multiple Heimdall accounts concurrently on the same browser or Electron desktop app and switching between them without re-authenticating at the OIDC provider:

1. **Multi-Account Session Ring (`__Host-heimdall_sessions`)**: Retain up to `MAX_BROWSER_ACCOUNTS = 5` concurrent server-side browser sessions in an HttpOnly cookie ring alongside the active `__Host-heimdall_session` cookie. Raw session tokens never reach JavaScript.
2. **Active-Account-Only WebSocket Connection**: Only the currently selected (active) account holds a WebSocket connection (`/api/v1/user-ws` and on-demand PTY/tool/LSP streams) and an unlocked `VaultKeyring` in memory. Deselected accounts hold **no** WebSocket connections and **no** in-memory vault keys.
3. **Non-Destructive Account Switching & Cross-Tab Sync**: Switching accounts unmounts the outgoing account's shell first (closing WebSockets, `mcpWorker`, and in-memory `VaultKeyring`) before mutating the active session cookie, resets Redux/RTK Query state while preserving `localStorage` state across switches, and synchronizes other open tabs via the `storage` event on `heimdall.lastSeenUserId`.
4. **Account Switcher UI & Electron OIDC Handoff**: Provide an interactive Account Switcher in the sidebar footer (`shell-sidebar-account`) and Settings `AccountPanel`, and route Electron "Add account" flows (`/api/v1/auth/login?add_account=1`) directly into the preload-free `openOidcWindow` popup without disrupting `mainWindow`.

---

## 2. Requirements

- **`REQ-ACCT-RING-1` (Session Cookie Ring)**:
  - Keep `__Host-heimdall_session` (`SESSION_COOKIE`) as the active account's opaque 32-byte base64url session token so all existing REST, WebSocket, and preview endpoints remain unchanged.
  - Add `__Host-heimdall_sessions` (`SESSIONS_RING_COOKIE`, `Path=/; Secure; HttpOnly; SameSite=Lax`) storing up to `MAX_BROWSER_ACCOUNTS = 5` raw session tokens joined by `.` in MRU order (active token first).
  - Deduplicate the ring by `user_id`: during callback merge (`GET /api/v1/auth/callback`), if the newly signed-in `user_id` already has a session in the ring, delete the old session row from `user_sessions` (and call `preview_end_for_parent`) and replace it with the new token.
  - If adding a new account in callback merge exceeds `MAX_BROWSER_ACCOUNTS = 5`, evict the oldest deselected token from the ring and delete its row from `user_sessions` (and `preview_end_for_parent`).
  - Raw session tokens must never appear in any JSON response body.
- **`REQ-ACCT-RING-2` (Add Account OIDC Prompt)**:
  - `GET /api/v1/auth/login` accepts optional query parameter `add_account=1` (or `prompt=login`).
  - When `add_account=1` or `prompt=login` is present, `web_login_begin` appends `{"prompt", "login"}` to the OIDC provider authorization URL query so the IdP prompts for credentials instead of reusing the current SSO session.
  - `GET /api/v1/auth/callback` merges the newly created session with any live sessions from the request's `__Host-heimdall_session` and `__Host-heimdall_sessions` cookies, sets `__Host-heimdall_session` to the new session, and sets `__Host-heimdall_sessions` to the merged MRU ring.
- **`REQ-ACCT-RING-3` (List, Switch, and Logout Endpoints)**:
  - `GET /api/v1/auth/sessions`: Read-only on `user_sessions` (never deletes rows from `user_sessions` on a `GET`, avoiding cross-tab races). Validates all tokens in `__Host-heimdall_session` + `__Host-heimdall_sessions` against `user_sessions`, prunes expired/revoked/duplicate/overflow tokens from its cookie view (emitting an updated `Set-Cookie: __Host-heimdall_sessions=...` when any token was pruned or when the ring cookie was absent for a valid `__Host-heimdall_session`), and returns `{ active_user_id, accounts: [{ user_id, name, display_name, email, active, expires_at_ms }] }`.
  - `POST /api/v1/auth/switch` (CSRF-checked via `csrf_decide`): Accepts `{"user_id": "usr_..."}`. Looks up the live session for `user_id` in `__Host-heimdall_session` + `__Host-heimdall_sessions`. Returns `400 validation_failed` if `user_id` is empty, or `404 not_found` if no live session for `user_id` exists in the ring. Otherwise touches `last_seen_at_ms`, promotes that token to `__Host-heimdall_session`, updates MRU order in `__Host-heimdall_sessions`, and returns `{ active_user_id, user, accounts }`.
  - `POST /api/v1/auth/logout` (CSRF-checked): Accepts optional JSON body `{"user_id"?: "usr_...", "all"?: bool}` (an empty or `{}` body defaults to signing out the active account):
    - If `all == true` or no other live accounts remain in the ring after removing the target session: deletes all target/ring sessions in `user_sessions`, calls `preview_end_for_parent` for each, expires both `__Host-heimdall_session` and `__Host-heimdall_sessions`, and returns `{ logout_url, active_user_id: "", switched_user: null, accounts: [] }`.
    - If signing out one account (`user_id` or the active account) while at least one other live account remains in the ring: deletes only that account's session from `user_sessions` and `preview_end_for_parent`, removes it from `__Host-heimdall_sessions`, promotes the next live token in the ring to `__Host-heimdall_session` if the active account was signed out, and returns `{ logout_url: "", active_user_id, switched_user, accounts }`.
- **`REQ-ACCT-WS-1` (Active-Account-Only WebSocket)**:
  - Only the active account opens `/api/v1/user-ws` (`useUserWebSocket`) and on-demand PTY/tool/LSP streams (`useShellStream`, `useAgentStream`, `useToolActivityStream`, `LspClient`).
  - Deselected accounts hold no WebSocket connection.
  - On account switch, `AuthGate` transitions to `status: 'switching'` **before** `POST /api/v1/auth/switch` executes, which unmounts the outgoing account's `AuthenticatedShell` first — immediately closing its `/api/v1/user-ws` socket, calling `setMcpWorkerEnabled(false)`, and closing any open stream sockets before the cookie changes or the newly selected account connects.
- **`REQ-ACCT-UI-1` (Client Persistence, Vault Isolation, State Transitions & Cross-Tab Sync)**:
  - Switching accounts in `AuthGate` (`src/ui/components/shell/AppShell.tsx`) must **not** call `removeAppOwnedClientStorage()`.
  - Explicit sign-out of a single account calls `removeUserClientStorage(userId)` (deleting `heimdall.user.<encodeURIComponent(userId)>.*` keys). Signing out when no accounts remain (or `all: true`) calls `removeAppOwnedClientStorage()`.
  - When a user initiates **"Add another account"** from the UI, record a short-lived local intent flag (`recordAddAccountIntent()`) so `deviceVault.ts` automatically acknowledges `otherPinnedAccounts` (`acknowledgeOtherAccount`) for the newly added account without blocking on a false-positive TOFU swap warning.
  - **Cross-tab synchronization**: `AuthGate` listens for `window` `'storage'` events where `event.key === LAST_SEEN_USER_ID_KEY` (`heimdall.lastSeenUserId`). When another tab switches accounts (updating `heimdall.lastSeenUserId`), the background tab immediately runs `refreshIdentity('storage')`, which detects `nextUserId !== previousUserId` and executes the same non-destructive switch path (`stopDeviceVault`, `clearPriorUserClientState`, `bootDeviceVault(nextUserId)`, remounting `AuthenticatedShell` with `key={nextUserId}`).
- **`REQ-ACCT-UI-2` (Account Switcher UI)**:
  - Render `AccountSwitcher` (`src/ui/components/shell/AccountSwitcher.tsx`) inside `shell-sidebar-account` in `src/ui/components/shell/AppShell.tsx` (preserving all existing sidebar debug IDs and adding the new `account-switcher-*` debug IDs) and render the signed-in accounts list in `src/ui/components/settings/AccountPanel.tsx`.
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
    - Reads `SESSION_COOKIE` (if present and valid length `32..=128`) first, then splits `cookie_value(headers, SESSIONS_RING_COOKIE)` on `'.'` and appends valid-length tokens.
    - Deduplicates identical raw token strings while preserving parse order (`SESSION_COOKIE` first), using `context.temp_allocator`.

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
  - **Read-only on `user_sessions`**: never calls `repo.delete_session`, so concurrent `GET /api/v1/auth/sessions` requests from multiple tabs are idempotent and race-free.
  - Iterates candidate raw tokens from `parse_sessions_ring(headers)`.
  - Validates each token via `resolve_session_auth(service, raw_token)`.
  - If a token is invalid/expired, sets `changed = true` and skips it.
  - If `ctx.user_id` is already present in `accounts` (duplicate token for the same user) or `len(accounts) >= MAX_BROWSER_ACCOUNTS`, sets `changed = true` and skips it in the returned view/cookie.
  - Otherwise appends `raw_token` to `raw_ring` and appends `Auth_Account_Entry` to `accounts`.
  - **Active-flag rule**: The first live token in parse order (`SESSION_COOKIE` first, or the first live token from `SESSIONS_RING_COOKIE` if `SESSION_COOKIE` was missing/expired) is the active account: `active = (len(accounts) == 0)` at insertion time (i.e. `accounts[0].active == true` and `accounts[i].active == false` for all `i > 0`), and `active_raw = raw_ring[0]`. If `SESSION_COOKIE` was missing/expired or `SESSIONS_RING_COOKIE` was missing/differed from `raw_ring`, `changed = true`.

#### OIDC Login Prompt & Callback Merge
- `web_login_begin(service: ^Auth_Service, return_to: string, client_ip := "", prompt_login := false) -> (redirect_url: string, login_cookie: string, ok: bool, err: domain.Domain_Error)`:
  - In `auth_login_handler` (`src/hub/transport/http/auth_session_handlers.odin:34-45`), compute `prompt_login := query_value(req.query, "add_account") == "1" || query_value(req.query, "prompt") == "login"`.
  - When `prompt_login` is true, include `{"prompt", "login"}` in `httpc.build_url` query params for `service.web.authorize_url`.
- `merge_session_into_ring(service: ^Auth_Service, headers: []contracts.HTTP_Header, new_raw_session: string) -> [dynamic]string`:
  - Called by `auth_callback_handler` (`src/hub/transport/http/auth_session_handlers.odin:48-74`) after `web_login_complete` creates `new_raw_session`.
  - Resolves `new_ctx` via `resolve_session_auth(service, new_raw_session)` and starts `ring` with `new_raw_session` at index 0.
  - Iterates existing candidate tokens from `parse_sessions_ring(headers)`:
    - If a candidate equals `new_raw_session`, skips it.
    - Looks up the candidate via `resolve_session_auth(service, candidate)`. If invalid/expired, skips it.
    - If `candidate_ctx.user_id == new_ctx.user_id` (same user re-authenticated) OR `len(ring) >= MAX_BROWSER_ACCOUNTS` (overflow beyond 5 accounts): deletes the old/evicted session row from `service.sessions` (`repo.delete_session(repo.ctx, sha256_hex(candidate))`) and calls `preview_end_for_parent(service, sha256_hex(candidate))`.
    - Otherwise appends `candidate` to `ring`.
  - `auth_callback_handler` emits `Set-Cookie` headers for `session_cookie_header(new_raw_session, ttl / 1000)`, `sessions_ring_cookie_header(ring[:], ttl / 1000)`, and `clear_login`.

#### Wire Endpoints (`src/hub/transport/http/auth_session_handlers.odin` & `wiring.odin`)
Register in `src/hub/app/wiring.odin`:
```odin
http.router_add(&graph.router, "GET", "/api/v1/auth/sessions", rawptr(&graph.user_handlers), http.auth_sessions_handler)
http.router_add(&graph.router, "POST", "/api/v1/auth/switch", rawptr(&graph.user_handlers), http.auth_switch_handler)
```

1. **`GET /api/v1/auth/sessions` (`auth_sessions_handler`)**:
   - Calls `resolve_session_ring(handlers.auth, req.headers)`.
   - Returns `200 OK`:
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
   - If `changed` is true, attaches `Set-Cookie` for `SESSION_COOKIE` (or expired cookie if `active_raw == ""`) and `SESSIONS_RING_COOKIE` plus `Cache-Control: no-store`.

2. **`POST /api/v1/auth/switch` (`auth_switch_handler`)**:
   - Request body: `{"user_id": "usr_2"}`.
   - If `user_id == ""` -> `400 validation_failed` (`"user_id is required"`).
   - Calls `web_switch_account(handlers.auth, req.headers, target_user_id)`:
     - Resolves the ring via `resolve_session_ring(handlers.auth, req.headers)`.
     - If no entry in `accounts` matches `target_user_id` -> `404 not_found` (`"account session not found or expired"`).
     - Moves `target_user_id`'s raw token and `Auth_Account_Entry` to index 0, touches its `last_seen_at_ms` in `service.sessions`, and sets `accounts[0].active = true` (and `active = false` for `i > 0`).
   - Emits `Set-Cookie` for `session_cookie_header(active_raw, ttl / 1000)` and `sessions_ring_cookie_header(raw_ring[:], ttl / 1000)` plus `Cache-Control: no-store`.
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
     - When `logout_all == true` or no other live accounts remain in the ring after removing the target session:
       - Deletes every session in `parse_sessions_ring(headers)` from `service.sessions` and calls `preview_end_for_parent`.
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
     - When signing out a single account (`target_user_id` or the active account when `target_user_id == ""`) and at least one other live session remains in the ring:
       - Deletes only the target session from `service.sessions` and calls `preview_end_for_parent`.
       - Keeps the remaining live sessions in `SESSIONS_RING_COOKIE`, with `raw_ring[0]` set as `SESSION_COOKIE` (`accounts[0].active = true`).
       - Returns `logout_url: ""`, `active_user_id: accounts[0].user_id`, `switched_user` (set to `accounts[0]`'s user object when the active account changed, or `null` when a deselected account was removed), and `accounts`.

---

### 3.2 Client Persistence, Vault, WebSocket Teardown & UI State Transitions (`src/ui/`)

#### `src/ui/auth/oidcSession.ts`
Add pure, unit-tested helpers:
- `export type AuthSessionAccount = { user_id: string; name: string; display_name: string; email: string; active: boolean; expires_at_ms: number };`
- `export function addAccountHref(location: LocationLike): string`:
  - Returns `${LOGIN_PATH}?add_account=1&return_to=${encodeURIComponent(currentReturnTo(location))}`.
- `export async function fetchAuthSessions(fetchImpl: typeof fetch, url = '/api/v1/auth/sessions'): Promise<{ activeUserId: string; accounts: AuthSessionAccount[] }>`
- `export async function postSwitchAccount(fetchImpl: typeof fetch, userId: string, url = '/api/v1/auth/switch'): Promise<{ activeUserId: string; user: AuthUserIdentity; accounts: AuthSessionAccount[] }>`
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
  - `export function resolveSwitchedUserRoute(nextUserId: string, currentHash: string): string`:
    - Returns `readUserLastRoute(nextUserId)` if non-empty; otherwise if `currentHash` points to an account-specific thread (`#/conversations/...`, `#/c/...`, `#/chains/...`), returns `'#/home'`; otherwise preserves `currentHash || '#/home'`.
  - `export const ADD_ACCOUNT_INTENT_KEY = 'heimdall:add-account-intent-at';`
  - `export const ADD_ACCOUNT_INTENT_TTL_MS = 10 * 60_000;`
  - `export function recordAddAccountIntent(now = Date.now()): void` and `export function consumeAddAccountIntent(now = Date.now()): boolean`.

#### `src/ui/services/deviceVault.ts`
- In `refuseUnacknowledgedAccount(c: Ctx)` (`src/ui/services/deviceVault.ts:636-642`):
  - If `consumeAddAccountIntent()` returns `true`, automatically call `await acknowledgeOtherAccount(d().kv, c.userId)` and return `false` so a user who explicitly clicked "Add another account" is not blocked on the `other-account` warning screen.

#### `AuthGate` State Machine & Switch Ordering (`src/ui/components/shell/AppShell.tsx`)
Extend `AuthStatus`:
```ts
type AuthStatus = 'checking' | 'authenticated' | 'switching' | 'unauthenticated' | 'forbidden' | 'unavailable' | 'error';
```
When `auth.status === 'switching'`, `AuthGate` renders `<AuthStatusScreen debugId="auth-switching" title="Switching account…" body="Updating your active Ninjy session." />`. Because `<AuthenticatedShell>` is **not** rendered while `auth.status === 'switching'`, the outgoing account's `useUserWebSocket` (`/api/v1/user-ws`), `mcpWorker`, and any open `useShellStream` / `useAgentStream` / `useToolActivityStream` / `LspClient` sockets are torn down **before** `POST /api/v1/auth/switch` rewrites `__Host-heimdall_session`.

| Transition | Trigger | Prior State | Ordered Actions | Next State |
|---|---|---|---|---|
| **Switch Account (Success)** | `switchAccount(B)` where `B !== A` | `authenticated(A)` | 1. `writeUserLastRoute(A, window.location.hash)`<br>2. `stopDeviceVault(dispatch)` (purges `A`'s keyring)<br>3. `setAuth({ status: 'switching', user: null, error: '' })` (unmounts `AuthenticatedShell(A)`, closing `A`'s `/api/v1/user-ws` & `mcpWorker`)<br>4. `res = await postSwitchAccount(fetch, B)`<br>5. `clearPriorUserClientState(dispatch, B)` (resets RTK Query & Redux state without calling `removeAppOwnedClientStorage()`)<br>6. `writeLastSeenUserId(B)`, `analytics.identify(B)`, `window.location.hash = resolveSwitchedUserRoute(B, window.location.hash)`<br>7. `void bootDeviceVault(B, dispatch)`, `setAccounts(res.accounts)` | `authenticated(B)` (mounts `<AuthenticatedShell key={B} />`, opening `B`'s `/api/v1/user-ws`) |
| **Switch Account (Error Rollback)** | `postSwitchAccount(B)` rejects (`404` / network) | `switching` (from `A`) | 1. Refresh ring via `fetchAuthSessions(fetch).catch(() => null)`<br>2. Re-boot `void bootDeviceVault(A, dispatch)`<br>3. Restore `setAuth({ status: 'authenticated', user: userA, error: '' })` and dispatch error toast | `authenticated(A)` |
| **Sign Out Deselected Account `B`** | `signOutAccount({ userId: B })` where `B !== A` | `authenticated(A)` | 1. `res = await postLogoutAccount(fetch, { userId: B })`<br>2. `removeUserClientStorage(B)`<br>3. `setAccounts(res.accounts)` (no unmount of `A`) | `authenticated(A)` |
| **Sign Out Active Account `A` (Remaining Account `B`)** | `signOutAccount({ userId: A })` when `B` remains in ring | `authenticated(A)` | 1. `stopDeviceVault(dispatch)`<br>2. `setAuth({ status: 'switching', user: null, error: '' })` (unmounts `AuthenticatedShell(A)`, closing `A`'s WS)<br>3. `res = await postLogoutAccount(fetch, { userId: A })`<br>4. `removeUserClientStorage(A)`<br>5. `clearPriorUserClientState(dispatch, B)`, `writeLastSeenUserId(B)`, `analytics.identify(B)`, `window.location.hash = resolveSwitchedUserRoute(B, window.location.hash)`<br>6. `void bootDeviceVault(B, dispatch)`, `setAccounts(res.accounts)` | `authenticated(B)` |
| **Sign Out Last Account or All Accounts** | `signOutAccount({ all: true })` or last account in ring | `authenticated(A)` | 1. `stopDeviceVault(dispatch)`<br>2. `setAuth({ status: 'switching', user: null, error: '' })` (closes `A`'s WS)<br>3. `res = await postLogoutAccount(fetch, opts)`<br>4. `removeAppOwnedClientStorage()`, `analytics.reset()`<br>5. `window.location.assign(res.logoutUrl || '/')` | Redirects to `res.logoutUrl` or `/` (`unauthenticated`) |
| **Cross-Tab Storage Sync** | `window` `'storage'` event with `key === LAST_SEEN_USER_ID_KEY` and `newValue === B !== A` | `authenticated(A)` | 1. `refreshIdentity('storage')` runs<br>2. Sees `nextUserId === B !== previousUserId (A)`<br>3. Runs `stopDeviceVault(dispatch)`, `clearPriorUserClientState(dispatch, B)`, `analytics.identify(B)`, `window.location.hash = resolveSwitchedUserRoute(B, window.location.hash)`, `void bootDeviceVault(B, dispatch)` | `authenticated(B)` |

---

### 3.3 Account Switcher UI (`src/ui/components/shell/AccountSwitcher.tsx` & `src/ui/components/settings/AccountPanel.tsx`)

#### Sidebar `AccountSwitcher.tsx`
- Rendered inside `shell-sidebar-account` in `src/ui/components/shell/AppShell.tsx` (`lines 2112-2130`).
- **Debug ID Contract**:
  - **Preserve all existing debug IDs** in `shell-sidebar-account` (verified against `tests/ui_sidebar_layout_test.ts` and `tests/e2e/sidebar_chains_browser.mjs`):
    - `data-debug-id="shell-sidebar-account"` (outer footer container)
    - `data-debug-id="shell-global-ownership-points"` (primary account row)
    - `data-debug-id="shell-user-ws-owner"` (user avatar / WS status indicator)
    - `data-debug-id="shell-open-account"` (button opening Account Settings)
    - `data-debug-id="shell-current-user-owner"` (active user's display name)
    - `data-debug-id="auth-logout-link"` (button signing out the active account)
    - `data-debug-id="shell-subscription-tier"` (subscription plan row when `planLabel` is non-empty)
  - **Add new Account Switcher debug IDs**:
    - `data-debug-id="account-switcher-toggle"` (button in `shell-global-ownership-points` that opens/closes the Account Switcher popover, showing a count badge when `accounts.length > 1`)
    - `data-debug-id="account-switcher-menu"` (popover container listing signed-in accounts and actions)
    - `data-debug-id="account-switcher-item-<user_id>"` (button/row for `<user_id>`; clicking a deselected account calls `switchAccount(user_id)`)
    - `data-debug-id="account-switcher-logout-<user_id>"` (button to sign out `<user_id>`)
    - `data-debug-id="account-switcher-add-account"` (button calling `addAccount()`, which records `recordAddAccountIntent()` and navigates to `addAccountHref(window.location)`)
    - `data-debug-id="account-switcher-logout-all"` (button calling `signOutAccount({ all: true })`, rendered when `accounts.length > 1`)

#### Settings `AccountPanel.tsx`
- Add a **Signed-in accounts** section (`data-debug-id="account-panel-sessions"`) listing all accounts in the session ring:
  - Active account row with `Active` badge.
  - Deselected account rows with **Switch** button (`data-debug-id="account-panel-switch-<user_id>"`) and **Sign out** button (`data-debug-id="account-panel-logout-<user_id>"`).
  - **Add another account** button (`data-debug-id="account-panel-add-account"`) and, when `accounts.length > 1`, **Sign out all accounts** button (`data-debug-id="account-panel-logout-all"`).

---

### 3.4 Electron OIDC Popup Handoff (`src/ui/electron/externalUrl.cts`, `src/ui/electron/main.cts`)

- In `src/ui/electron/externalUrl.cts`:
  - Add `isAddAccountAuthUrl(value: unknown, uiOrigin: string): boolean`:
    - Returns `true` when `url.origin === originOf(uiOrigin)`, `url.pathname.startsWith('/api/v1/auth/login')`, and `url.searchParams.get('add_account') === '1' || url.searchParams.get('prompt') === 'login'`.
  - In `classifyNavigation(value: unknown, context: NavigationContext): NavigationRoute`:
    - Before returning `'allow'` for `url.origin === originOf(context.uiOrigin)`, if `isAddAccountAuthUrl(url.href, context.uiOrigin)` is `true`, return `'auth'`.
- Effect in `src/ui/electron/main.cts`:
  - When `mainWindow` navigates to `/api/v1/auth/login?add_account=1&return_to=...`, `will-navigate` classifies the navigation as `'auth'`, calls `event.preventDefault()`, and invokes `openOidcWindow(url, win)`.
  - `mainWindow` stays on the current account (keeping its WebSocket alive while the popup is open).
  - `loginWindow` loads `/api/v1/auth/login?add_account=1...`, receives `__Host-heimdall_login` in `session.defaultSession`, redirects to the IdP with `prompt=login`, completes `/api/v1/auth/callback` (updating `__Host-heimdall_session` and `__Host-heimdall_sessions`), and commits navigation to `return_to` on `configuredUiOrigin()`, at which point `finishIfReturned` closes `loginWindow` and reloads `mainWindow` at `returnUrl`.

---

## 4. Verification Plan & Test Matrix

Every requirement has explicit automated test cases mapped by `REQ-*` ID and target test file:

| Requirement | Test File | Test Cases |
|---|---|---|
| **`REQ-ACCT-RING-1`** | `src/hub/transport/http/oidc_session_test.odin` | 1. **Ring merge & MRU order**: Logging in as `usr_1` then `usr_2` sets `__Host-heimdall_session` to `usr_2` and `__Host-heimdall_sessions` to `<raw_2>.<raw_1>`; neither raw token appears in any JSON response body.<br>2. **Same-user deduplication**: Re-authenticating as `usr_1` deletes `usr_1`'s prior row in `user_sessions` (and ends its preview sessions) and keeps at most one entry for `usr_1` in `__Host-heimdall_sessions`.<br>3. **Cap eviction (`MAX_BROWSER_ACCOUNTS = 5`)**: Logging in a 6th distinct user evicts the oldest deselected user (5th index) from `__Host-heimdall_sessions` and deletes its row from `user_sessions`. |
| **`REQ-ACCT-RING-2`** | `src/hub/transport/http/oidc_session_test.odin` | 4. **`add_account=1` -> `prompt=login`**: `GET /api/v1/auth/login?add_account=1&return_to=%2F%23%2Fhome` returns `302` whose `Location` query includes `prompt=login`, whereas plain `GET /api/v1/auth/login` omits `prompt`. |
| **`REQ-ACCT-RING-3`** | `src/hub/transport/http/oidc_session_test.odin` | 5. **`GET /api/v1/auth/sessions` read-only view & pruning**: Returns all live accounts in MRU order with `accounts[0].active == true` (`SESSION_COOKIE` first), prunes expired/revoked tokens via `Set-Cookie`, and never deletes live rows in `user_sessions`.<br>6. **`POST /api/v1/auth/switch` & CSRF**: Rejects cross-origin requests (`403 csrf_rejected`), empty `user_id` (`400`), and unknown/expired `user_id` (`404`); on valid `user_id`, promotes its token to `__Host-heimdall_session`, updates MRU `__Host-heimdall_sessions`, touches `last_seen_at_ms`, and returns `{ active_user_id, user, accounts }`.<br>7. **`POST /api/v1/auth/logout` single vs. all**: Logging out a deselected `user_id` deletes only that session and keeps `__Host-heimdall_session` unchanged; logging out the active account when another account remains promotes the next live account to `__Host-heimdall_session` and returns `logout_url: ""`; logging out with `{"all": true}` (or the last remaining account) deletes all ring sessions in `user_sessions`, expires both cookies, and returns the IdP `logout_url`. |
| **`REQ-ACCT-WS-1`** | `tests/ui_account_switch_test.ts` | 8. **Pre-POST WS & MCP teardown on switch**: Calling `switchAccount('usr_2')` transitions `AuthGate` to `'switching'` and unmounts `AuthenticatedShell('usr_1')` **before** `POST /api/v1/auth/switch` resolves — closing `usr_1`'s `/api/v1/user-ws` socket and calling `setMcpWorkerEnabled(false)` before `usr_2`'s `/api/v1/user-ws` socket is created. Deselected accounts never open a WebSocket. |
| **`REQ-ACCT-UI-1`** | `tests/ui_oidc_session_test.ts`, `tests/ui_workspace_persistence_test.ts`, `tests/ui_account_switch_test.ts` | 9. **Session client helpers (`tests/ui_oidc_session_test.ts`)**: `addAccountHref`, `fetchAuthSessions`, `postSwitchAccount`, and `postLogoutAccount` format requests and parse envelopes accurately while `postLogout` remains backwards-compatible.<br>10. **Non-destructive switch & scoped cleanup (`tests/ui_workspace_persistence_test.ts`, `tests/ui_account_switch_test.ts`)**: Switching `usr_1 -> usr_2` preserves `localStorage` keys (aux panes, composer drafts, `heimdall.user.usr_1.*`), saves `usr_1`'s route hash, restores `usr_2`'s route hash (or falls back from `#/conversations/...` / `#/chains/...` to `#/home`), calls `stopDeviceVault` (`clearKeyringSession`), resets RTK Query/Redux state, and boots `deviceVault` for `usr_2`. Signing out `usr_1` calls `removeUserClientStorage('usr_1')` without wiping `usr_2`'s keys; signing out the last account calls `removeAppOwnedClientStorage()`.<br>11. **Rollback on switch failure (`tests/ui_account_switch_test.ts`)**: When `postSwitchAccount` rejects (`404` / network error), `AuthGate` rolls back from `'switching'` to `'authenticated'` for `usr_1` and re-boots `usr_1`'s device vault.<br>12. **Add-account vault intent (`tests/ui_account_switch_test.ts`)**: `recordAddAccountIntent()` causes `deviceVault` (`refuseUnacknowledgedAccount`) to call `acknowledgeOtherAccount` and proceed instead of stopping at `status: 'other-account'`.<br>13. **Cross-tab `storage` sync (`tests/ui_account_switch_test.ts`)**: Dispatching a `storage` event for `LAST_SEEN_USER_ID_KEY` (`usr_1 -> usr_2`) triggers `refreshIdentity('storage')`, tearing down `usr_1`'s WS/vault and mounting `usr_2` without wiping `localStorage`. |
| **`REQ-ACCT-UI-2`** | `tests/ui_account_switch_test.ts` | 14. **`AccountSwitcher` & `AccountPanel` rendering and debug IDs**: Renders all preserved sidebar debug IDs (`shell-sidebar-account`, `shell-global-ownership-points`, `shell-user-ws-owner`, `shell-open-account`, `shell-current-user-owner`, `auth-logout-link`) plus `account-switcher-toggle`, `account-switcher-menu`, `account-switcher-item-<id>`, `account-switcher-logout-<id>`, `account-switcher-add-account`, `account-switcher-logout-all`, and the `account-panel-*` controls in `AccountPanel`. |
| **`REQ-ACCT-ELECTRON-1`** | `tests/ui_desktop_oidc_handoff_test.ts` | 15. **Electron add-account popup classification**: `classifyNavigation` returns `'auth'` for `https://web.ninjy.ai/api/v1/auth/login?add_account=1&return_to=%2F%23%2Fhome` (and `prompt=login`) so `will-navigate` opens `openOidcWindow` without navigating `mainWindow`, while keeping plain `/api/v1/auth/login` and UI routes as `'allow'`. |
