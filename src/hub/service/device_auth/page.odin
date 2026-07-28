// Browser confirm page for the device-authorization flow (ELDA-2).
//
// GET /api/v1/device serves this single self-contained HTML document (inline
// CSS/JS, no external dependencies, no build step). It is NOT the Heimdall SPA
// shell — it is a tiny dedicated surface for entering a user_code, reviewing
// the requesting device's info, and approving or denying the grant.
//
// XSS safety: every server-controlled field rendered into the DOM
// (device_label, os, app_version, client, request_ip) is inserted via
// textContent / createElement, NEVER via innerHTML interpolation, so a crafted
// device_label cannot inject markup or script. The user_code typed by the user
// is likewise only ever read from the input and sent in the body, never
// rendered unsanitized.

package device_auth

// DEVICE_PAGE_HTML is served by GET /api/v1/device. The JS flow:
//   1. user enters the user_code shown by the device,
//   2. POST /api/v1/device/verify {user_code} -> show device info,
//   3. [Approve] / [Deny] -> POST /api/v1/device/approve {user_code, approve}.
// All fetches are same-origin (the browser reached this page through the
// trusted proxy, so the trusted-proxy identity headers ride on every request).
DEVICE_PAGE_HTML :: `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Heimdall — Authorize device</title>
<style>
  :root { color-scheme: light dark; }
  body { font-family: system-ui, -apple-system, Segoe UI, sans-serif; max-width: 520px;
         margin: 40px auto; padding: 0 16px; line-height: 1.5; color: #1f2937; background: #f8fafc; }
  @media (prefers-color-scheme: dark) { body { color: #e5e7eb; background: #0f172a; } }
  h1 { font-size: 1.25rem; margin: 0 0 4px; }
  p.sub { margin: 0 0 20px; color: #6b7280; font-size: 0.9rem; }
  section { background: #ffffff; border: 1px solid #e5e7eb; border-radius: 8px; padding: 16px; margin-bottom: 12px; }
  @media (prefers-color-scheme: dark) { section { background: #111827; border-color: #1f2937; } }
  label { font-size: 0.8rem; color: #6b7280; display: block; margin-bottom: 4px; }
  input { font: inherit; padding: 8px 10px; border: 1px solid #d1d5db; border-radius: 6px; width: 100%;
          box-sizing: border-box; background: #ffffff; color: inherit; letter-spacing: 0.1em; }
  @media (prefers-color-scheme: dark) { input { background: #0b1220; border-color: #374151; } }
  button { font: inherit; cursor: pointer; border-radius: 6px; padding: 8px 16px; border: 1px solid #d1d5db;
           background: #ffffff; color: inherit; margin-top: 12px; }
  @media (prefers-color-scheme: dark) { button { background: #1f2937; border-color: #374151; } }
  button.primary { background: #2563eb; color: #ffffff; border-color: #2563eb; }
  button.danger { color: #b91c1c; border-color: #fecaca; }
  button:disabled { opacity: 0.5; cursor: default; }
  dl { margin: 0; display: grid; grid-template-columns: auto 1fr; gap: 6px 12px; }
  dt { color: #6b7280; font-size: 0.8rem; }
  dd { margin: 0; word-break: break-all; font-weight: 500; }
  .err { color: #b91c1c; font-size: 0.85rem; min-height: 1em; }
  .ok { color: #047857; font-size: 0.85rem; }
  .hidden { display: none; }
</style>
</head>
<body>
<h1>Authorize a device</h1>
<p class="sub">Enter the code shown by the Heimdall app on your new device.</p>

<section>
  <label for="user_code">Device code</label>
  <input id="user_code" inputmode="text" autocomplete="off" placeholder="ABCD-2345" maxlength="9">
  <button id="verifyBtn" type="button" class="primary">Continue</button>
  <p class="err" id="err"></p>
</section>

<section id="deviceSection" class="hidden">
  <h2 style="font-size:1rem;margin:0 0 10px;">Confirm it's you signing in</h2>
  <dl>
    <dt>App</dt><dd id="d_client"></dd>
    <dt>Device</dt><dd id="d_device_label"></dd>
    <dt>OS</dt><dd id="d_os"></dd>
    <dt>Version</dt><dd id="d_app_version"></dd>
    <dt>From IP</dt><dd id="d_request_ip"></dd>
  </dl>
  <button id="approveBtn" type="button" class="primary">Approve</button>
  <button id="denyBtn" type="button" class="danger">Deny</button>
  <p class="ok" id="result"></p>
</section>

<script>
"use strict";
const errEl = document.getElementById("err");
const resultEl = document.getElementById("result");
const deviceSection = document.getElementById("deviceSection");
const verifyBtn = document.getElementById("verifyBtn");
const approveBtn = document.getElementById("approveBtn");
const denyBtn = document.getElementById("denyBtn");
const codeInput = document.getElementById("user_code");

function showErr(msg) { errEl.textContent = msg || ""; resultEl.textContent = ""; }
function clearErr() { errEl.textContent = ""; }

// Render one <dd> by id using textContent (XSS-safe; never innerHTML).
function setDD(id, value) {
  const el = document.getElementById(id);
  el.textContent = value || "—";
}

verifyBtn.addEventListener("click", async () => {
  clearErr();
  const user_code = codeInput.value.trim();
  if (!user_code) { showErr("Enter the code from your device."); return; }
  try {
    const res = await fetch("/api/v1/device/verify", {
      method: "POST", credentials: "same-origin",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ user_code }),
    });
    if (res.status === 410) { showErr("This code was already used."); return; }
    if (!res.ok) { showErr("Invalid or expired code."); return; }
    const payload = await res.json();
    const d = (payload && payload.data) || payload || {};
    setDD("d_client", d.client);
    setDD("d_device_label", d.device_label);
    setDD("d_os", d.os);
    setDD("d_app_version", d.app_version);
    setDD("d_request_ip", d.request_ip);
    deviceSection.classList.remove("hidden");
  } catch (e) {
    showErr("Network error: " + e);
  }
});

async function decide(approve) {
  clearErr();
  const user_code = codeInput.value.trim();
  try {
    const res = await fetch("/api/v1/device/approve", {
      method: "POST", credentials: "same-origin",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ user_code, approve }),
    });
    if (res.status === 409) { showErr("This code was already used."); return; }
    if (!res.ok) { showErr("Invalid or expired code."); return; }
    resultEl.textContent = approve ? "Approved — check your device." : "Denied.";
    approveBtn.disabled = true;
    denyBtn.disabled = true;
  } catch (e) {
    showErr("Network error: " + e);
  }
}

approveBtn.addEventListener("click", () => decide(true));
denyBtn.addEventListener("click", () => decide(false));
codeInput.addEventListener("keydown", (ev) => { if (ev.key === "Enter") verifyBtn.click(); });
</script>
</body>
</html>`
