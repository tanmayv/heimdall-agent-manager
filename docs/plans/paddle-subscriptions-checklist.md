# Paddle account subscriptions checklist

Status: initial persistence and Paddle integration implemented; deployment configuration and subsequent phases pending. See [implementation and setup](../account-billing.md).

## Initial phase delivered

- [x] Persist account billing state, plan catalog defaults, effective user parameters, and separate account overrides.
- [x] Replace Account-page fixture data with authenticated hub data; scope UI cache to the current account.
- [x] Add server-created Paddle transaction checkout, account-bound customer portal sessions, and signature-verified subscription webhooks.
- [x] Preserve custom parameters through billing changes; handle duplicate/stale events atomically and payment grace expiry.
- [x] Test persistence across hub restart, account isolation, checkout/portal behavior, signature verification, and UI checkout handling.

Limit enforcement is intentionally deferred. Real Paddle account setup, a sandbox purchase, immutable identity migration, reconciliation, asynchronous webhook processing, and full operator audit/admin workflows remain pending. The checkboxes below describe the complete rollout, not just this initial phase.

## Authentik integration

Authentik remains responsible for authentication and login sessions. Paddle manages payments and subscription lifecycle. Heimdall stores account billing state and enforces entitlements; a subscription change does not revoke the user's ability to sign in.

- [ ] Reuse the hub's existing Authentik-backed authenticated account context for checkout, billing details, portal links, and enrollment approval. Do not introduce a second login system.
- [ ] Audit the current identity mapping before adding billing: map an immutable Authentik identity to a stable internal account ID. For OIDC, use issuer plus subject; for forward-auth, use the trusted immutable user identifier available from the configured provider. Do not key subscriptions by mutable username or email. If current ownership uses username, plan an explicit migration preserving existing bridge and data ownership.
- [ ] Accept forwarded identity headers only from the trusted authentication proxy, stripping externally supplied copies. Apply the existing session and CSRF protections to billing mutation endpoints.
- [ ] Link the internal account ID to the Paddle customer and subscription. Email may prefill checkout but must not automatically link or transfer paid access between accounts.
- [ ] Keep subscription tier resolution in the hub rather than depending on Authentik groups or claims that can remain stale in a session. Group synchronization, if desired later, is an optional projection of billing state.
- [ ] Make the Paddle webhook endpoint reachable without an Authentik login redirect, with an exception limited to that exact route and required method. Authenticate webhook deliveries using Paddle signature verification; keep checkout, portal, and account APIs behind normal authentication.
- [ ] Test Authentik username/email changes, logout/login, expired sessions, spoofed identity headers, and cross-account billing access. Renames must preserve billing and bridge ownership; downgrades must preserve login and Free access.

## Entitlements

| Account tier | Enrolled bridges | Streaming terminals |
| --- | --- | --- |
| Free | 1 | Disabled |
| Hobbyist | 2 | Enabled |

Limits belong to the authenticated account, across its projects and devices. Count enrolled, non-revoked bridges, including offline bridges. Reconnecting or re-enrolling the same bridge identity does not consume another slot. Revoking a bridge frees its slot. Runtime registry capacity limits remain separate infrastructure safeguards.

Streaming includes both shell and agent terminal panes, including interactive input and screen snapshots used by those panes. Free accounts retain ordinary agent/chat functionality. Paid streaming does not imply unlimited bandwidth, viewers, or terminal instances; existing safety limits remain.

## 1. Decide product settings

- [ ] Choose Hobbyist price, currency, and monthly/annual billing options.
- [ ] Decide whether to offer a trial; otherwise start with no trial.
- [ ] Approve payment-failure policy: suggested initial policy is a bounded, explicitly configured grace period for `past_due`, with a payment-update banner; after grace, revert entitlements to Free.
- [ ] Keep Hobbyist access through a scheduled cancellation until cancellation takes effect. Paused/canceled subscriptions revert to Free; active/trialing subscriptions receive Hobbyist access.
- [ ] Define migration policy for existing accounts with more bridges than their plan allows: require selecting permitted bridges or grant an explicit temporary exception. Preserve records and local running agents.
- [ ] Define scope for self-hosted hubs separately; do not accidentally require every private/local hub to purchase a hosted-service subscription.

## 2. Configure Paddle

- [ ] Use Paddle Billing sandbox first, separately from the live account.
- [ ] Create a Hobbyist product and recurring price(s). Free is an internal default tier and requires no checkout.
- [ ] Record sandbox/live product and price IDs in server configuration; map only approved price IDs to Hobbyist.
- [ ] Create a least-privilege server API key, browser client-side token, and webhook notification destination/secret. Keep API keys and webhook secrets out of the UI and repository.
- [ ] Configure checkout domain approval, default payment link, and required business/website settings for live activation.
- [ ] Configure subscription lifecycle webhooks and customer portal access.

## 3. Store account billing state

Architecture requirement: subscription identifiers and Paddle price mappings belong exclusively to billing resolution. All feature authorization consumes effective user-scoped parameters. Plan names are display metadata, never feature switches.

- [x] Define a central plan catalog mapping arbitrary plan IDs to parameter defaults, initially `max_bridges` and `terminal_streaming_enabled`. Adding a tier changes catalog configuration, not enrollment or streaming code.
- [x] Resolve effective parameters from plan defaults plus validated, audited per-account overrides. Explicit `false` and `0` overrides must be preserved. Support custom plans without a fixed Free/Hobbyist enum in consumers.
- [ ] Persist overrides separately from billing state so webhook updates do not erase custom agreements. Define override expiry, precedence, and which overrides survive cancellation.
- [x] Return plan display metadata, effective parameters, and eligible upgrade offers separately. UI actions use available offers; UI features and server enforcement use parameters.
- [x] Test a third plan, a custom account, overridden bridge counts, streaming disabled on a paid plan, and streaming enabled by an explicit custom grant. Verify no feature code compares tier names or Paddle price IDs.

- [x] Add durable account-to-Paddle-customer mapping, subscription ID, price ID, status, billing period dates, scheduled changes, payment-grace deadline, and last applied event timestamp.
- [x] Store successfully processed event IDs for deduplication without unnecessary payment/customer payloads. Durable acceptance and queued processing/retries remain pending below.
- [x] Implement one hub-owned entitlement resolver returning effective `max_bridges` and `terminal_streaming_enabled` from local durable billing state and account overrides, with plan metadata separate.
- [x] Expose authenticated account billing/entitlements and bridge usage to the UI. Never accept a client-supplied tier, account owner, or arbitrary price as authority.
- [ ] Support audited administrative exceptions without changing global capacity limits.

## 4. Checkout, webhooks, and portal

- [x] Add authenticated checkout initiation. Bind purchases to the authenticated internal account using a server-created transaction or securely validated correlation reference; do not grant access from browser checkout success alone.
- [x] Prevent accidental duplicate active subscriptions for the same account.
- [x] Verify `Paddle-Signature` against the original request bytes before parsing; apply request-size limits and reject invalid signatures.
- [ ] Durably accept verified events, acknowledge promptly, then process with retry support. Handle duplicate and out-of-order events transactionally; use event occurrence time and canonical Paddle lookup when needed.
- [x] Process subscription creation/update/activation, trial, payment past due, pause/resume, cancellation, and scheduled changes.
- [ ] Establish and implement an explicit policy for refunds/chargebacks.
- [ ] Add periodic reconciliation with Paddle to repair missed events; preserve known valid access during temporary Paddle outages rather than performing a Paddle API request on every terminal frame.
- [x] Add authenticated customer portal session creation; resolve customer ID from the account mapping and return account-specific links for payments, invoices, and cancellation.

## 5. Enforce bridge and streaming entitlements

- [ ] Enforce the user's effective `max_bridges` during enrollment approval/bridge creation in one atomic transaction, preventing concurrent enrollments from exceeding the limit (catalog defaults are one for Free and two for Hobbyist).
- [ ] Allow existing permitted bridges to reconnect without consuming a slot; ensure token renewal and re-enrollment cannot bypass identity counting.
- [ ] Return a stable limit error with current usage and explain how to revoke a bridge. Suggest an eligible offer only when its bridge allowance exceeds the current effective allowance.
- [ ] Gate shell and agent pane subscription, input, resize, screen/snapshot, and alternate HTTP/tunnel routes at the hub before forwarding commands or allocating viewers. Audit routes to distinguish terminal access from unrelated editor/preview tunnels.
- [ ] Replace entitlement reliance on the user-toggleable `streaming_terminal_pane` experiment. If retained for rollout, require both the entitlement and rollout flag; an experiment cannot grant paid access.
- [ ] On an effective downgrade, notify clients and terminate existing terminal viewer subscriptions using the established safe socket ownership rules. Prevent subsequent input and pane delivery, while preserving agent processes and conversation data.
- [ ] Invalidate cached entitlements after billing updates; account for multiple hub replicas if introduced. Check at session admission and entitlement changes, without querying Paddle for each streamed frame.

## 6. Account UI

- [ ] Add a compact Subscription section using existing theme and UI primitives: tier, billing state, bridge usage (`1 / 2`), and next renewal/cancellation date.
- [x] Render eligible upgrade offers and subscription-management actions supplied by the account billing response, without branching on tier names.
- [ ] Show a clear streaming upgrade prompt on Free accounts, with ordinary chat still usable.
- [x] Explain pending activation after checkout while awaiting verified billing state; refresh entitlements when confirmation arrives.
- [ ] Show actionable payment-failure/grace messages and scheduled cancellation details.
- [ ] Make bridge revocation discoverable from the bridge-limit message.

## 7. Acceptance tests and rollout

- [ ] Free: enroll one bridge successfully; reject a second, including simultaneous enrollment attempts; offline bridges still count.
- [ ] Reconnect/renew/re-enroll an existing bridge without using another slot; revoke one and enroll a replacement.
- [ ] Free: reject shell and agent streaming through UI and direct API/WS requests, including snapshots/input; user-controlled experiment settings cannot bypass the gate.
- [ ] Hobbyist: two bridges and working shell/agent pane rendering, colors, encryption, input, resize, and reconnect.
- [ ] Test sandbox purchase, renewal, trial expiry if offered, failed payment/grace expiry, recovery, scheduled cancellation, immediate cancellation, pause/resume, and selected refund policy.
- [ ] Verify duplicate/reordered webhooks, invalid signatures, unknown prices, forged account correlation, cross-account portal access, and reconciliation after missed events.
- [ ] Verify a downgrade closes existing viewers without stopping agents or deleting data; upgrades restore access without reinstalling bridges.
- [ ] Verify hub restart preserves billing state and expired grace periods cannot retain paid access indefinitely.
- [ ] Add metrics/alerts for webhook failures, reconciliation drift, checkout failures, and entitlement denials; avoid sensitive payment data in logs.
- [ ] Deploy hub migrations/backend and UI together. Existing bridge/ham-ctl releases should suffice if enforcement stays hub-side; confirm that route audit reveals no required protocol change.
- [ ] Configure live credentials, prices, notification endpoint, domain settings, and portal independently of sandbox; run a real purchase/cancel smoke test before opening paid signup.

## Paddle references

- [Provision access and subscription state](https://developer.paddle.com/build/subscriptions/provision-access-webhooks/): webhook-synchronized local state, status-based access, and customer portal flows.
- [Webhooks](https://developer.paddle.com/webhooks/): notification destinations, signature verification, and lifecycle events.
- [Billing quickstart](https://developer.paddle.com/get-started/quickstart/): sandbox integration and go-live setup.

The grace-period duration, pricing, trials, existing-account migration, and self-hosted policy remain product decisions. Complete-rollout items remain pending unless marked in the initial-phase section.
