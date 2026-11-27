---
name: credential-and-browser-use
description: Reuse the bridge's shared Chromium profile and request confidential form values without exposing them to agent tools.
---

# Browser and confidential input

Use the shared Chromium only for the requested account and site. Agents on the
same registration run as the same OS user and share authenticated access. This
is a trusted bridge convention, not isolation between agents.

## Attach first

1. Require `HEIMDALL_BROWSER_PROFILE_DIR` and `HEIMDALL_BROWSER_CDP_PORT`.
   Probe `http://127.0.0.1:$HEIMDALL_BROWSER_CDP_PORT/json/version`.
   Connect to the browser socket on that same loopback port and call
   `Browser.getBrowserCommandLine`. Require exactly one
   `--user-data-dir` equal to the bridge-provided path. Do not attach if the
   listener responds but identity is missing or wrong. Do not log its command
   line or switch to a different port or profile.
2. If there is no listener, launch installed Chromium headless by default
   with these flags. Use the same profile and original OS cookie store.
   If a step requires direct desktop interaction, report **display required**
   and coordinate with the owner. If the original OS cookie store is
   unavailable, report **session unavailable**.

   ```bash
   chromium --headless=new --enable-automation --remote-debugging-address=127.0.0.1 \
     --remote-debugging-port="$HEIMDALL_BROWSER_CDP_PORT" \
     --user-data-dir="$HEIMDALL_BROWSER_PROFILE_DIR" about:blank
   ```
3. If launch hands off or the profile is busy, re-probe the configured port
   and attach only after the same profile check. If verification fails, stop
   and report **browser busy** or **browser identity unverified**. Never
   delete native locks or kill, restart or close the shared browser.
4. Configure the agent's Playwright MCP server to run the following command
   with the bridge's actual port expanded in the config arguments. No global
   install, launcher helper or browser controller is needed.

   ```bash
   npx -y @playwright/mcp@0.0.86 --cdp-endpoint "http://127.0.0.1:$HEIMDALL_BROWSER_CDP_PORT"
   ```

   Create a tab for this operation and use only that tab. Check the active
   account before acting. Do not read or save cookies, share screenshots of
   confidential inputs, or use MCP type/fill/evaluate tools for secrets. Do
   not snapshot the page while secret inputs are populated.

## Request values privately

Prepare a public form JSON and trusted Bash script at an absolute path. There
is no manifest. The form displays and signs the script path and purpose. Only
public text belongs in the schema, command, chat, or script source. Treat every
submitted field as confidential.

```json
{"version":1,"purpose":"Sign in to the requested service in the shared browser.","fields":[{"id":"password","label":"Password","type":"password"}]}
```

```bash
ham-ctl secure-form run --form form.json --script /absolute/path/login.sh \
  --timeout 180 --execution-timeout 60
```

As soon as the command prints the owner link, post it in chat with one line explaining what the form is for. The link requires the owner’s Hub session and is not a bearer token. Share only the link and context, never form values or raw command output.

The Bridge runs `bash <script>` in its parent directory with the agent's usual
environment, supplying one versioned JSON object on private stdin. Do not put
values in files, environment, arguments or diagnostics. Never enable tracing or
print values. Both bounded stdout and stderr are returned to the agent, even
on script failure.

After a confirmed terminal failure, check the destination for side effects
before retrying. If appropriate, edit the script in place and explicitly run:

```bash
ham-ctl secure-form retry --request REQUEST_ID --after-attempt ATTEMPT
```

The same instance and task can retry the same path and purpose for five minutes
from original answer receipt. Retries do not extend the window, prompt again,
or replay automatically. After expiry, ask for fresh input with a new form.
Do not automatically retry an uncertain outcome. Stop and report passkey or
CAPTCHA challenges for the owner to complete on the shared browser.

| Fixed CLI code | Meaning |
| --- | --- |
| 0 | Success |
| 20 | Invalid request or unauthorized |
| 21 | Declined |
| 22 | Form response expired |
| 23 | Cancelled |
| 24 | Not delivered |
| 25 | Stdin delivery failed |
| 26 | Script failed |
| 27 | Script execution timed out |
| 28 | Outcome unknown or prior attempt unresolved |
| 29 | Retention expired, request fresh input |

The CLI reports the child's numeric exit separately when available. Codes
25–28 can leave external effects. Generic CLI startup errors 1 and 2 do not
establish whether a script ran.

## Fill only the verified tab

This Bash example requires Node with the built-in WebSocket API. Before
requesting values create a public `login-target.json` next to the script with `origin` and
`target_id` set to the exact origin and CDP target ID of the tab you created. Adapt the reviewed
form selectors and field mapping to the intended page. Require HTTPS outside
an isolated loopback test. Keep the script on the bridge and do not forward
the CDP endpoint.

```bash secure-form-fill
#!/usr/bin/env bash
node --input-type=module - 3<&0 <<'NODE'
import { readFileSync } from 'node:fs';

// Public values only. Replace these with the intended site and owned tab.
let EXPECTED_ORIGIN, TARGET_ID;
const port = process.env.HEIMDALL_BROWSER_CDP_PORT;
const profile = process.env.HEIMDALL_BROWSER_PROFILE_DIR;
let socket;
const pending = new Map();
const contextIds = new Map();
let id = 0;

function cdp(method, params = {}, sessionId) {
  return new Promise((resolve, reject) => {
    const call = ++id;
    pending.set(call, { resolve, reject });
    socket.send(JSON.stringify({ id: call, method, params, sessionId }));
  });
}

try {
  ({ origin: EXPECTED_ORIGIN, target_id: TARGET_ID } = JSON.parse(readFileSync('login-target.json', 'utf8')));
  if (!/^\d{1,5}$/.test(port ?? '') || +port < 1 || +port > 65535 ||
      !profile || !/^[\w-]+$/.test(TARGET_ID ?? '')) throw Error();
  const endpoint = `127.0.0.1:${port}`;
  const response = await fetch(`http://${endpoint}/json/version`, { redirect: 'error' });
  if (!response.ok) throw Error();
  const { webSocketDebuggerUrl } = await response.json();
  const path = new URL(webSocketDebuggerUrl).pathname;
  if (!/^\/devtools\/browser\/[\w-]+$/.test(path)) throw Error();
  socket = new WebSocket(`ws://${endpoint}${path}`);
  socket.addEventListener('message', ({ data }) => {
    const reply = JSON.parse(data);
    if (reply.method === 'Runtime.executionContextCreated') {
      const { id, uniqueId } = reply.params.context;
      contextIds.set(id, uniqueId);
    } else if (reply.method === 'Runtime.executionContextsCleared') {
      contextIds.clear();
    } else if (reply.method === 'Runtime.executionContextDestroyed') {
      contextIds.delete(reply.params.executionContextId);
    }
    const call = pending.get(reply.id);
    if (!call) return;
    pending.delete(reply.id);
    if (reply.error) call.reject(Error());
    else call.resolve(reply.result);
  });
  socket.addEventListener('close', () => {
    for (const call of pending.values()) call.reject(Error());
    pending.clear();
  });
  await new Promise((resolve, reject) => {
    socket.addEventListener('open', resolve, { once: true });
    socket.addEventListener('error', reject, { once: true });
  });
  const { arguments: argv } = await cdp('Browser.getBrowserCommandLine');
  const profiles = argv.filter(arg => /^--user-data-dir(?:=|$)/.test(arg));
  if (profiles.length !== 1 || profiles[0] !== `--user-data-dir=${profile}`) throw Error();
  const { sessionId } = await cdp('Target.attachToTarget', { targetId: TARGET_ID, flatten: true });
  await cdp('Runtime.enable', {}, sessionId);
  const { frameTree } = await cdp('Page.getFrameTree', {}, sessionId);
  if (new URL(frameTree.frame.url).origin !== EXPECTED_ORIGIN) throw Error();
  const { executionContextId } = await cdp('Page.createIsolatedWorld', {
    frameId: frameTree.frame.id, worldName: 'heimdall-secure-form'
  }, sessionId);
  // Use the unique context identity rather than a numeric ID that Chromium can recycle.
  const context = contextIds.get(executionContextId);
  if (!context) throw Error();
  const { version, values } = JSON.parse(readFileSync(3, 'utf8'));
  if (version !== 1 || typeof values?.password !== 'string' || !values.password) throw Error();
  const result = await cdp('Runtime.evaluate', {
    uniqueContextId: context,
    expression: `(${((expected, password) => {
      if (location.origin !== expected) return false;
      const form = document.querySelector('form#login');
      const input = form?.querySelector('input[type=password][name=password]');
      const submit = form?.querySelector('button[type=submit]');
      if (!input || !submit || submit.form !== form || input.form !== form ||
          input.disabled || input.readOnly || submit.disabled ||
          (submit.hasAttribute('formmethod') ? submit.formMethod : form.method) !== 'post' ||
          !['', '_self'].includes(submit.hasAttribute('formtarget') ? submit.formTarget : form.target) ||
          new URL(submit.hasAttribute('formaction') ? submit.formAction : form.action).origin !== expected) return false;
      input.value = password;
      form.requestSubmit(submit);
      return true;
    }).toString()})(${JSON.stringify(EXPECTED_ORIGIN)}, ${JSON.stringify(values.password)})`,
    returnByValue: true
  }, sessionId);
  if (result.exceptionDetails || result.result?.value !== true) throw Error();
} catch {
  // Never print rejected CDP responses, exceptions, page content or values.
  process.exitCode = 1;
} finally {
  socket?.close();
}
NODE
```

A zero script exit means the submission was initiated. Separately verify the
expected signed-in state without reading the secret values.

## Share a live, watch-only tab

Share the tab when the owner wants to follow what you are doing. Confirm that
the target is the tab you are working in, not another agent's tab in the shared
Chromium profile.

```sh
ham-ctl stream list --sources tabs
ham-ctl stream share --tab <cdp-target-id>
```

Send the exact link printed by `stream share` to the owner in Heimdall chat.
The link is not a credential. Only the signed-in Heimdall owner can open it.
The viewer is watch-only and shows the page, not browser chrome or OS dialogs.

Anything visible on the page is visible to the owner while they watch,
including account details and codes. A secure form does not pause the stream.
Do not put unmasked secret values on screen or share a tab whose visible
content the owner should not see. The Hub relays the capture without recording
frames or storing stream metadata.

Capture starts when the first viewer opens the link and stops when the last
viewer leaves. The link can be reopened until it expires (normally after two
hours) or the tab closes. To end the share sooner, run
`ham-ctl stream stop <stream-id>` with the ID at the end of the link.
