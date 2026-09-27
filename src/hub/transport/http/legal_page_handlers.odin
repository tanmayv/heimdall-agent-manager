// Public legal pages required by the Google OAuth consent screen
// (REQ-LEGAL-1/2/3/6).
//
// GET /policy and GET /toc must be reachable by an anonymous browser with no
// credentials of any kind: Google's consent-screen verification fetches the
// privacy-policy and terms URLs logged-out. The handlers below are therefore
// deliberately UNAUTHENTICATED — they call no require_auth* proc and read no
// request headers at all (no Authorization, no cookies, no trusted-proxy
// identity headers such as X-Forwarded-For / X-authentik-*). The pages must
// render identically when every such header is absent, which is exactly the
// anonymous case that matters to the verifier. The wiring registers them with
// ctx = nil, which structurally guarantees they touch no graph or auth state.
//
// These are the ONLY non-/api/v1 paths the hub serves: router_dispatch consults
// PUBLIC_PAGE_PATHS with exact string matching when the /api/v1 prefix check
// fails, and every other non-/api/v1 path keeps 404ing. The two upgrade
// dispatchers' /api/v1 gates are not relaxed.
//
// HEAD is deliberately NOT registered (stated per the task): write_http_response
// always sends a response body, which would be incorrect for a HEAD response,
// no existing hub route registers HEAD, and Google's verification fetches with
// GET. HEAD on a public page therefore falls through route matching to 404.

package http

// PUBLIC_PAGE_PATHS is the CLOSED allowlist of non-/api/v1 paths that
// router_dispatch will serve. Consulted ONLY when the /api/v1 prefix check
// fails. Membership is exact string equality — no prefix matching, no
// wildcards, no trailing-slash tolerance, no case folding — so /policyx,
// /POLICY, and /policy/ all stay 404. Any addition to this list is a
// security-significant widening of the hub's unauthenticated surface.
PUBLIC_PAGE_PATHS :: []string{"/policy", "/toc"}

is_public_page_path :: proc(path: string) -> bool {
	for p in PUBLIC_PAGE_PATHS {
		if path == p do return true
	}
	return false
}

// LEGAL_PAGE_LAST_UPDATED is the single source of the "Last updated:" line on
// both pages (REQ-LEGAL-4 / AC3). Bump it in the same commit that changes the
// substance of either page's text — never on a purely cosmetic edit.
LEGAL_PAGE_LAST_UPDATED :: "2026-09-27"

// LEGAL_PAGE_HEAD / _FOOT wrap both page bodies so the two pages cannot drift
// apart stylistically. Self-contained like DEVICE_PAGE_HTML — inline CSS only,
// no external font, CDN, or asset fetch — so an anonymous reviewer loading
// these with everything else blocked still sees the full page (AC4). Styling
// uses the landing-page/DESIGN.md tokens (bg #0a0c10, surface #151922, accent
// #38bdf8, Inter with a real system fallback stack).
//
// Mobile readability (AC5): body copy is 17px (1.0625rem) and never smaller;
// `overflow-wrap: anywhere` plus a 20px-padded, max-width-720px column means no
// element can force horizontal page scroll at a 375px viewport, and a
// max-width:480px query trims the card padding so the text column stays wide.
@(private = "file")
LEGAL_PAGE_HEAD :: `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Heimdall — `

@(private = "file")
LEGAL_PAGE_STYLE :: `</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body { font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto,
         'Helvetica Neue', Arial, sans-serif;
         background: #0a0c10; color: #f1f5f9; margin: 0; line-height: 1.6;
         font-size: 1.0625rem; overflow-wrap: anywhere;
         -webkit-font-smoothing: antialiased; }
  main { max-width: 720px; margin: 0 auto; padding: 48px 20px 80px; }
  .card { background: #151922; border: 1px solid #1e2430; border-radius: 10px; padding: 28px; }
  .brand { font-size: 1rem; font-weight: 600; letter-spacing: 0.08em; text-transform: uppercase;
           color: #38bdf8; margin: 0 0 16px; }
  h1 { font-size: 1.5rem; line-height: 1.25; margin: 0 0 16px; }
  h2 { font-size: 1.125rem; line-height: 1.3; margin: 32px 0 10px; color: #f1f5f9; }
  p { color: #94a3b8; margin: 0 0 12px; font-size: 1.0625rem; }
  ul { color: #94a3b8; margin: 0 0 12px; padding-left: 22px; }
  li { margin: 0 0 8px; font-size: 1.0625rem; }
  strong { color: #e2e8f0; font-weight: 600; }
  code { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
         font-size: 0.95em; color: #38bdf8; background: #0a0c10;
         border: 1px solid #1e2430; border-radius: 4px; padding: 1px 5px; }
  a { color: #38bdf8; }
  .lede { color: #cbd5e1; }
  .updated { color: #94a3b8; font-size: 1rem; margin: 32px 0 0; padding-top: 16px;
              border-top: 1px solid #1e2430; }
  .updated a { margin-left: 4px; }
  @media (max-width: 480px) {
    main { padding: 28px 16px 56px; }
    .card { padding: 20px; }
  }
</style>
</head>
<body>
<main>
  <article class="card">
`

@(private = "file")
LEGAL_PAGE_FOOT :: `  </article>
</main>
</body>
</html>`

// POLICY_PAGE_HTML — REQ-LEGAL-4 / AC7. Every data-handling claim below is
// either a fact confirmed by the operator (entity name, product name, public
// host) or traced to source in the T2 handoff comment; no retention period,
// sub-processor, jurisdiction, or compliance claim is asserted that the system
// does not back. The three operator-supplied facts that no source file could
// answer (contact address, governing law, hosted-deployment collection) were
// supplied by the operator and substituted in Phase B; no token remains.
POLICY_PAGE_HTML :: LEGAL_PAGE_HEAD + "Privacy Policy" + LEGAL_PAGE_STYLE + `    <p class="brand">Heimdall</p>
    <h1>Privacy Policy</h1>
    <p class="lede">Heimdall is an agent orchestrator built by <strong>Broccoli Labs</strong>. This
      policy describes what data Heimdall handles. It applies both to Heimdall run on your own
      machine (self-hosted) and to the hosted deployment at
      <strong>https://heimdall.mundus.in</strong>, which Broccoli Labs operates.</p>

    <h2>In short</h2>
    <ul>
      <li>Heimdall keeps its data in a single database file on the machine that runs it. The
        default is the local file <code>hub.db</code>, and the server listens on
        <code>127.0.0.1</code> unless an operator changes it.</li>
      <li>No passwords are stored. Access tokens are stored only as a hash.</li>
      <li>No IP addresses, no user-agent strings, and no analytics or telemetry of any kind are
        stored or sent anywhere.</li>
      <li>The only data that leaves the machine is a push notification sent to a browser that
        asked for one, and it is encrypted before it leaves.</li>
    </ul>

    <h2>1. What Heimdall stores</h2>
    <ul>
      <li><strong>Your account:</strong> name, display name, email address, and account status.</li>
      <li><strong>Access tokens:</strong> a label, an optional device label, the creation,
        last-used, expiry and revocation times, and a <strong>hash</strong> of the token. The
        token value itself is never stored.</li>
      <li><strong>Encryption material, if you use client-side encryption:</strong> an encrypted
        key blob and the parameters needed to derive your key from your passphrase. Your raw
        keys and passphrases are never sent to Heimdall.</li>
      <li><strong>Your work:</strong> projects, task chains and tasks, task comments, agent
        memories, chat messages, artifacts, and records of the agent instances you run. Each
        record belongs to exactly one account.</li>
      <li><strong>Push subscriptions,</strong> only if you turn on notifications (section 3).</li>
      <li><strong>The machines and workspaces you connect:</strong> for each connected machine,
        its hostname, operating system and CPU architecture, and the label you give it; for your
        projects and agent sessions, <strong>filesystem paths</strong> on those machines — a
        project's directory, an agent's working directory, a shell session's working directory —
        and a project's repository URL.</li>
      <li><strong>Shell command records:</strong> for each command or shell session, the command
        text, its working directory, its status and exit code, and for a session its process id
        and any local port it serves. Command <strong>output</strong> is never sent to or stored
        by Heimdall — it stays on the machine that ran the command.</li>
    </ul>
    <p>Heimdall supports optional client-side encryption: your client can encrypt content before
      sending it, and Heimdall then stores only an opaque ciphertext it cannot read. This is
      optional and off unless you configure a key. <strong>With no key configured, the same
      content is stored as ordinary text</strong> in the database. We do not claim that the
      database is encrypted.</p>

    <h2>2. What Heimdall does not store</h2>
    <ul>
      <li><strong>No passwords.</strong> There is no password field anywhere in the database.</li>
      <li><strong>No IP addresses and no user-agent strings.</strong> Your IP address is
        necessarily visible to the server while it handles your request, and is held briefly in
        memory to rate-limit device-authorization attempts. It is not written to the database
        and it is not written to any log.</li>
      <li><strong>No analytics, telemetry, crash reporting, advertising, or tracking.</strong>
        Heimdall contains no such code and contacts no such service.</li>
      <li><strong>No command output</strong>, as described in section 1.</li>
    </ul>

    <h2>3. Third parties we contact</h2>
    <p>Heimdall contacts exactly one kind of external service, and only if you opt in: the web
      push service your own browser nominates, in order to deliver notifications.</p>
    <ul>
      <li><strong>Nothing is sent until your browser asks for it.</strong> A notification goes
        only to a browser that has created a push subscription, which yours does only when you
        allow notifications; if you never do, nothing is ever sent to you. Sending also requires
        a signing keypair configured by the operator — that keypair <strong>is</strong>
        configured on the hosted deployment at https://heimdall.mundus.in, so notifications are
        available there. A self-hosted install with no keypair configured cannot send at
        all.</li>
      <li><strong>We do not choose the recipient.</strong> The destination is whatever endpoint
        URL your browser hands us — in practice the push service of your browser's vendor, such
        as Google's or Apple's.</li>
      <li><strong>What is sent:</strong> a notification title, a short preview of the message
        that triggered it (truncated to 140 characters), and a link back into the app. Only chat
        messages and requests for your attention produce a notification.</li>
      <li><strong>It is encrypted for your browser before it leaves</strong> (the standard web
        push encryption, RFC 8291). The push service relays a ciphertext it cannot read.</li>
    </ul>
    <p>Beyond that, Heimdall sends your data to no third party.</p>

    <h2>4. Signing in with Google</h2>
    <p>As of the date at the foot of this page, Heimdall does <strong>not</strong> include a
      Google sign-in flow. If Google sign-in is enabled, Heimdall will receive from Google only
      the profile information you approve on Google's consent screen — your name and email
      address — and will store it as the account record described in section 1. It will never
      receive your Google password, and it will not use anything obtained through Google sign-in
      for any purpose other than identifying your Heimdall account.</p>

    <h2>5. Who can access your data</h2>
    <ul>
      <li>Every record belongs to one account. Ownership is set when the record is created and
        cannot be reassigned afterwards — the database itself rejects the attempt.</li>
      <li><strong>Self-hosted:</strong> your data is a file on your machine. Anyone who can read
        that machine or that file can read your data, and controlling that access is yours to
        do.</li>
      <li><strong>Hosted:</strong> access to https://heimdall.mundus.in is gated by an identity
        provider that sits in front of the application, so you must authenticate with it before
        any application page is served. We state only that this gate exists; that provider's own
        data handling is outside this policy.</li>
      <li>This page and the <a href="/toc">terms page</a> are the deliberate exception: they are
        served to anyone, with no credentials, and read no request headers at all — that is what
        lets Google's consent-screen verification fetch them logged-out.</li>
    </ul>

    <h2>6. The hosted deployment</h2>
    <p>The hosted deployment at https://heimdall.mundus.in is operated by Broccoli Labs. It
      stores the same records described in section 1, on infrastructure we run rather than on
      your own machine.</p>
    <p><strong>Your content — the text of your tasks, comments, memories, chat messages and
      artifacts — is encrypted before it reaches us only if you have enabled client-side
      encryption.</strong> Where you have, we hold an opaque ciphertext, the key is one we never
      receive, and we cannot read it. Where you have not, that same content is stored as
      ordinary text in the database and can be read by whoever administers the deployment. Which
      of those two applies is your choice, and we do not claim the first on your behalf.</p>
    <p>Alongside content, the deployment holds the operational metadata listed in section 1:
      your account record, token metadata (never the token itself), the agent instance, machine
      and shell command records — including the filesystem paths named there — push
      subscriptions, and the ownership and timestamps attached to every record. That metadata is
      not encrypted.</p>
    <p>The application is reached through a proxy and an identity provider that sit in front of
      it (section 5). Infrastructure of that kind commonly records request information, which
      may include IP addresses; that happens outside Heimdall, is not what section 2 describes,
      and this policy does not characterise it.</p>

    <h2>7. Keeping and deleting your data</h2>
    <p>Heimdall applies no automatic retention schedule: records stay in the database until they
      are deleted. The one exception is a push subscription, which is discarded once your
      browser's push service reports that it is no longer valid.</p>
    <ul>
      <li><strong>Self-hosted:</strong> you hold the data. Deleting a record in the app removes
        it from the database, and deleting the database file removes everything.</li>
      <li><strong>Hosted:</strong> to request deletion of your account and the records belonging
        to it, email 12tanmayvijay@gmail.com.</li>
    </ul>

    <h2>8. Changes to this policy</h2>
    <p>If this policy changes, the revised version is published on this page and the date at the
      foot of the page changes with it.</p>

    <h2>9. Contact</h2>
    <p>Questions about this policy, or a request about your data, go to
      12tanmayvijay@gmail.com.</p>

    <p class="updated">Last updated: ` + LEGAL_PAGE_LAST_UPDATED + ` · <a href="/toc">Terms of Service</a></p>
` + LEGAL_PAGE_FOOT

// TOC_PAGE_HTML — REQ-LEGAL-5 / AC7: license and permitted use, disclaimer of
// warranty, limitation of liability, governing law. The Apache-2.0 reference is
// the LICENSE file actually shipped in this repository; the jurisdiction is not
// derived from source — it is the operator-supplied fact recorded in T2.
TOC_PAGE_HTML :: LEGAL_PAGE_HEAD + "Terms of Service" + LEGAL_PAGE_STYLE + `    <p class="brand">Heimdall</p>
    <h1>Terms of Service</h1>
    <p class="lede">These terms govern your use of Heimdall (the <strong>Software</strong>) and of
      the hosted deployment at <strong>https://heimdall.mundus.in</strong> operated by
      <strong>Broccoli Labs</strong> (the <strong>Service</strong>). By using either, you accept
      these terms. If you do not accept them, do not use the Software or the Service.</p>

    <h2>1. License and permitted use</h2>
    <ul>
      <li><strong>The Software</strong> is distributed under the Apache License, Version 2.0. The
        <code>LICENSE</code> file included with the Software is the authoritative grant, and
        nothing on this page narrows the rights it gives you.</li>
      <li><strong>The Service</strong> is offered to you as a personal, non-exclusive,
        non-transferable and revocable right to use it for its intended purpose.</li>
      <li>You may not resell or sublicense access to the Service; attempt to reach another
        account's data; probe, disable, or work around its access controls; interfere with its
        availability for others; or use it for anything unlawful.</li>
    </ul>

    <h2>2. Your account and your credentials</h2>
    <p>You are responsible for keeping your access tokens secret and for activity carried out
      with them. Revoke a token as soon as you believe it may be compromised.</p>

    <h2>3. Autonomous agents and command execution</h2>
    <p>Read this section carefully, because it is the main risk in using Heimdall. Heimdall
      orchestrates autonomous AI coding agents. On your instruction, those agents
      <strong>read, write and delete files and execute shell commands</strong> on the machines
      you connect to it, with the privileges of the account Heimdall runs under. That can change
      or destroy data.</p>
    <p>You are solely responsible for what you authorize an agent to do, for the access you give
      it, for reviewing what it produces before relying on it, and for keeping your own backups.
      Broccoli Labs does not review, validate, or guarantee any agent's actions or output.</p>

    <h2>4. Third-party tools and services</h2>
    <p>Heimdall drives AI coding agents and developer tools that you choose, install and
      configure. Your use of those, and of any model provider they call, is governed by their own
      terms, not by these.</p>

    <h2>5. Disclaimer of warranty</h2>
    <p>The Software and the Service are provided <strong>"as is" and "as available", without
      warranty of any kind</strong>, whether express, implied or statutory, including but not
      limited to the implied warranties of merchantability, fitness for a particular purpose,
      title, and non-infringement. Broccoli Labs does not warrant that the Software or the
      Service will be uninterrupted, timely, secure or error-free, that any defect will be
      corrected, or that data will not be lost or corrupted. This section does not replace the
      disclaimer in the Apache License, Version 2.0, which continues to apply to the
      Software.</p>

    <h2>6. Limitation of liability</h2>
    <p>To the maximum extent permitted by applicable law, Broccoli Labs is not liable for any
      indirect, incidental, special, consequential, exemplary or punitive damages, nor for lost
      profits, lost or corrupted data, business interruption, or the cost of substitute
      services, arising out of or relating to your use of or inability to use the Software or
      the Service — including anything done by an autonomous agent under section 3 — even if
      Broccoli Labs has been advised of the possibility of such damages.</p>
    <p>Where liability cannot lawfully be excluded, the total liability of Broccoli Labs for all
      claims relating to the Software or the Service is limited to the total amount, if any, you
      have paid Broccoli Labs for the Service in the twelve months before the event giving rise
      to the claim. Nothing in these terms excludes or limits liability that cannot lawfully be
      excluded or limited.</p>

    <h2>7. Availability and changes</h2>
    <p>The Service carries no service-level commitment. Broccoli Labs may change, suspend or
      discontinue it, and may revise these terms — the revised terms are published on this page
      and the date at the foot of the page changes with them. Continuing to use the Service after
      a revision means you accept it.</p>

    <h2>8. Suspension and termination</h2>
    <p>You may stop using the Service at any time. Broccoli Labs may suspend or end your access
      to the Service if you breach these terms or where it is necessary to protect the Service or
      its other users. Your rights to the Software under the Apache License, Version 2.0, are not
      affected by the end of your access to the Service.</p>

    <h2>9. Governing law</h2>
    <p>These terms, and any dispute arising out of them or out of your use of the Software or the
      Service, are governed by the laws of India.</p>

    <h2>10. Contact</h2>
    <p>Questions about these terms go to 12tanmayvijay@gmail.com.</p>

    <p class="updated">Last updated: ` + LEGAL_PAGE_LAST_UPDATED + ` · <a href="/policy">Privacy Policy</a></p>
` + LEGAL_PAGE_FOOT

// policy_page_handler serves GET /policy. Unauthenticated and stateless: no
// auth service, no header reads, ctx ignored.
policy_page_handler :: proc(ctx: rawptr, req: Request) -> Response {
	_ = ctx
	_ = req
	return Response{status = 200, content_type = "text/html; charset=utf-8", body = POLICY_PAGE_HTML}
}

// toc_page_handler serves GET /toc. Unauthenticated and stateless, same as
// policy_page_handler.
toc_page_handler :: proc(ctx: rawptr, req: Request) -> Response {
	_ = ctx
	_ = req
	return Response{status = 200, content_type = "text/html; charset=utf-8", body = TOC_PAGE_HTML}
}
