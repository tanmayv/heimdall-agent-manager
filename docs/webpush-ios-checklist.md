# iOS PWA background-notification checklist (on-device)

Audience: **you**, running the installed Heimdall PWA on an iPhone/iPad. This is
the on-device acceptance test for Level 2 Web Push — confirming Heimdall delivers
a banner when an agent messages you while the app is **fully backgrounded or
closed**. Web Push in the Hub, the browser subscribe flow, and the send path are
already unit-tested and verified against a real push service; this checklist is
the human-in-the-loop confirmation on actual iOS hardware.

For VAPID key generation and running the Hub, see [`webpush.md`](./webpush.md).

## Why iOS is special (read once)

- Apple only supports Web Push for a PWA **installed to the Home Screen** — not
  in a Safari tab. It requires **iOS/iPadOS 16.4 or later**.
- Push only works over a **secure context** (HTTPS). Production is
  `https://heimdall.mundus.in`; that's what you must install from.
- Subscriptions do **not** survive uninstalling/reinstalling the PWA. If you
  remove and re-add it to the Home Screen, re-enable notifications so the app
  re-subscribes.
- Every push **must** result in a visible notification. Heimdall always shows one
  (falling back to a generic "Heimdall — You have a new notification." if a
  payload is ever missing), because iOS revokes push permission from an app that
  receives a "silent" push.

## Preconditions

- [ ] iPhone/iPad on **iOS/iPadOS 16.4+** (Settings → General → About → Software
      Version).
- [ ] You can sign in to Heimdall at `https://heimdall.mundus.in` in Safari.
- [ ] A way to trigger an **agent → user chat message** to your account (e.g. an
      agent instance you can prompt, or ask the coordinator to send you one).
      Only **chat** and **attention** events push; routine resource changes do
      not, by design.

## Part A — Install the PWA to the Home Screen

1. [ ] Open **Safari** (not Chrome/Firefox — on iOS only Safari can install a
       push-capable PWA) and go to `https://heimdall.mundus.in`.
2. [ ] Sign in and confirm the app loads.
3. [ ] Tap the **Share** icon → **Add to Home Screen** → **Add**.
4. [ ] Close Safari. Launch **Heimdall from its Home Screen icon**. It should open
       full-screen (standalone), with no Safari address bar. This standalone
       launch is required — notifications will not work from the Safari tab.

## Part B — Enable notifications (grant permission + subscribe)

5. [ ] In the Home-Screen app, open **Settings → Notifications** (the Heimdall
       notifications panel).
6. [ ] Turn the **master notifications toggle ON**.
7. [ ] iOS shows a system prompt: **"Heimdall Would Like to Send You
       Notifications."** Tap **Allow**. (If you tap "Don't Allow", see
       Troubleshooting → *Permission was denied*.)
8. [ ] Confirm the toggle stays ON. Behind the scenes the app fetched the Hub's
       VAPID key and registered a push subscription. You can sanity-check the
       grant later in **iOS Settings → Notifications → Heimdall** (it should be
       listed with **Allow Notifications** ON).

## Part C — Background the app

9. [ ] Return to the Home Screen (swipe up / press Home). For a stronger test,
       **swipe the Heimdall app away** in the app switcher so it is fully closed,
       not just backgrounded. Background push should still arrive.
10. [ ] Lock the device (optional but realistic — banners should still appear on
        the Lock Screen).

## Part D — Trigger a push and confirm the banner

11. [ ] Cause an **agent → user chat message** to your account (prompt an agent to
        message you, or have the coordinator send one).
12. [ ] Within a few seconds, a **notification banner** should appear on the Lock
        Screen / as a banner, titled **Heimdall** (or the message title) with the
        message text. This is the pass condition: **a banner while the app is
        backgrounded/closed.**
13. [ ] **Tap the notification.** Heimdall should open (launching it if closed) and
        navigate to the relevant conversation/route.

If steps 12–13 pass, Level 2 Web Push is confirmed on your device. 🎉

## Troubleshooting

**No banner appears (steps 11–12):**
- Confirm you launched from the **Home-Screen icon**, not a Safari tab.
- Confirm **iOS Settings → Notifications → Heimdall → Allow Notifications** is ON,
  and that **Banners/Lock Screen** styles are enabled (not only "None").
- Check **Focus / Do Not Disturb** isn't silencing notifications.
- Re-open the app once (to let it re-subscribe), then background it and retry. On
  iOS a subscription can rotate; the app resubscribes on load when notifications
  are enabled.
- Make sure the event you triggered is actually a **chat or attention** event —
  other resource changes intentionally do not push.

**Permission was denied (step 7):**
- iOS will not re-prompt automatically. Go to **iOS Settings → Notifications →
  Heimdall** and enable **Allow Notifications**, then reopen the app and toggle
  notifications ON again so it subscribes. If Heimdall isn't listed, the grant was
  never made — remove and re-add the PWA (Part A) and grant on the prompt.

**"Add to Home Screen" is missing / app opens in Safari with an address bar:**
- You're likely in a private tab or a non-Safari browser. Use a normal Safari tab.
- Verify the site is `https://` (secure context) and loads the web app manifest.

**It worked before but stopped after reinstalling:**
- Expected — iOS drops the push subscription when the PWA is removed. Re-enable
  notifications (Part B) to resubscribe.

**Nothing works and you're below iOS 16.4:**
- Web Push for Home-Screen PWAs is unavailable before 16.4. Update iOS.

## What "pass" means

- A notification banner appears for an agent→user chat **while the Heimdall PWA is
  backgrounded or fully closed**, and tapping it opens the app at the right route.
- If you only see notifications while the app is open and focused, that's the
  older in-page path — not the background Web Push this checklist verifies.
