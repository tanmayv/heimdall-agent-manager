# Electron Debug API — Usage Guide

The Heimdall Electron app exposes a localhost-only HTTP debug API that lets an
operator (or Claude) drive the UI programmatically: list elements, click,
type, set selects/radios, inspect Redux state, and capture logs. This is the
same channel used for automated UI verification and bug repros.

Source: `src/ui/electron/debugServer.cts` (compiled into
`electron-dist/debugServer.cjs`).

## Discovering the port

Every running Electron instance registers itself in
`~/.local/share/heimdall/debug-instances.json`:

```bash
cat ~/.local/share/heimdall/debug-instances.json
# [{"pid":3637133,"port":45495,"startedAt":1782033258767,"daemonUrl":"http://127.0.0.1:49322"}]

PORT=$(jq -r '.[0].port' ~/.local/share/heimdall/debug-instances.json)
```

The port is chosen at startup (not fixed). All endpoints are bound to
`127.0.0.1` only.

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| GET  | `/info`            | pid, uptime, platform |
| GET  | `/state`           | Full Redux state snapshot |
| GET  | `/state/select?path=a.b.c` | Subset of state by dotted path |
| GET  | `/logs`            | Recent main-process logs |
| GET  | `/elements`        | Curated list of interactive elements (buttons/inputs/selects/links + anything with `data-debug-id`) |
| POST | `/query-selector`  | Run `document.querySelectorAll` and return matches |
| POST | `/click`           | Click an element |
| POST | `/type`            | Set value on `<input>`/`<textarea>` |
| POST | `/select`          | Set `<select>` value or check a radio/checkbox |
| POST | `/highlight`       | Draw a visual overlay on a selector (debug only) |

### POST bodies

All POST endpoints accept JSON. Common shape:

```json
{ "query": "css selector", "index": 0, "text"|"value"|"text_guard": "..." }
```

- `query` — required for `/click`, `/type`, `/select`, `/query-selector`.
- `index` — defaults to `0`; pick the Nth match when multiple exist.
- `text` (click): optional guard; if set, the element's text must equal it.
- `dry_run` (click): if true, locate but don't click.
- `clear` (type): defaults true; appends when false.

## Typical UI-driving recipes

Throughout: assume `PORT` set to the value above; the assistant uses `curl`.

### 1. Navigate

The sidebar nav buttons all carry stable `data-debug-id`s:

```bash
curl -s -X POST http://127.0.0.1:$PORT/click \
  -d '{"query":"[data-debug-id=\"nav-projects\"]"}'
```

Existing IDs (search source for current list):
`nav-chat`, `nav-tasks`, `nav-memory`, `nav-projects`, `nav-agents`,
`nav-settings`, `new-agent-btn`, `refresh-agents-btn`, `message-input`,
`send-message-btn`.

### 2. List interactive elements on the current page

```bash
curl -s http://127.0.0.1:$PORT/elements | jq '.[] | {tag, debugId, text: .text[:60]}'
```

Or filter to a tag:

```bash
curl -s -X POST http://127.0.0.1:$PORT/query-selector \
  -d '{"query":"button"}' | jq '.[] | .text'
```

The element index in the response is what you pass back as `index` to `/click`
when there's no debug-id selector.

### 3. Create a project (Projects page flow)

```bash
PORT=$(jq -r '.[0].port' ~/.local/share/heimdall/debug-instances.json)

curl -s -X POST http://127.0.0.1:$PORT/click \
  -d '{"query":"[data-debug-id=\"nav-projects\"]"}'

# Click "+ Project" — currently text-only, no debug-id
curl -s -X POST http://127.0.0.1:$PORT/click \
  -d '{"query":"button","text":"+ Project","index":9}'

curl -s -X POST http://127.0.0.1:$PORT/type \
  -d '{"query":"input[placeholder=\"Project name\"]","text":"PI Cheap Test"}'
curl -s -X POST http://127.0.0.1:$PORT/type \
  -d '{"query":"textarea[placeholder=\"Optional description\"]","text":"end-to-end test"}'

curl -s -X POST http://127.0.0.1:$PORT/click \
  -d '{"query":"button","text":"Create project","index":14}'
```

Verify via state:

```bash
curl -s "http://127.0.0.1:$PORT/state/select?path=projects" \
  | jq '.value | {ids: .projectIds, selected: .selectedProjectId}'
```

### 4. Start an agent (StartAgent page flow)

```bash
curl -s -X POST http://127.0.0.1:$PORT/click \
  -d '{"query":"[data-debug-id=\"new-agent-btn\"]"}'

# Selects on the form. Order today: 0=project, 1=template, 2=provider.
curl -s -X POST http://127.0.0.1:$PORT/select \
  -d '{"query":"select","index":0,"value":"project_1782033036288"}'
curl -s -X POST http://127.0.0.1:$PORT/select \
  -d '{"query":"select","index":1,"value":"coder"}'
curl -s -X POST http://127.0.0.1:$PORT/select \
  -d '{"query":"select","index":2,"value":"pi"}'

# Tier radios — target by value
curl -s -X POST http://127.0.0.1:$PORT/select \
  -d '{"query":"input[type=\"radio\"][value=\"cheap\"]"}'

curl -s -X POST http://127.0.0.1:$PORT/click \
  -d '{"query":"button","text":"Start agent","index":10}'
```

### 5. Send a chat to a selected agent

```bash
# Expand the project group in the sidebar (one click), then click the row.
# selectors are tricky here because rows have no data-debug-id today.

curl -s -X POST http://127.0.0.1:$PORT/type \
  -d '{"query":"[data-debug-id=\"message-input\"]","text":"Hello agent"}'
curl -s -X POST http://127.0.0.1:$PORT/click \
  -d '{"query":"[data-debug-id=\"send-message-btn\"]"}'

# Confirm it landed in Redux:
curl -s "http://127.0.0.1:$PORT/state" \
  | jq '.chat.chats[.chat.selectedAgentId] | .[].body'
```

### 6. Inspect state for verification

```bash
# Agent runtime view
curl -s "http://127.0.0.1:$PORT/state" \
  | jq '.chat.agents[] | {id,label,status,templateId,providerProfile,modelTier,projectId,projectName}'

# Test runs
curl -s "http://127.0.0.1:$PORT/state/select?path=chat.testRuns" \
  | jq '.value[] | {testRunId,status,provider,tier}'
```

## Gotchas observed in practice

- **Element indices shift between page transitions.** Re-run
  `/query-selector` after every click — don't cache indices across views.
- **The `text` guard on `/click` requires exact match including whitespace.**
  React often concatenates labels (`"PI Cheap Test1 known · 1 live▾"`).
  Use `dry_run: true` first to confirm the element you're about to click.
- **`<select>` is uncontrolled in some React paths.** The `/select` endpoint
  sets `.value` via the native descriptor and dispatches both `input` and
  `change` events, which works for the current StartAgent and ProjectsPage
  forms. If a select doesn't update visually, check that the option `value`
  attribute actually equals what you passed (not just the visible label).
- **Radio inputs render as visually-hidden `<input type="radio">` siblings**
  of styled labels. `/select` calls `el.click()` after setting `.checked` so
  React's onChange fires, but if a form swallows clicks, target the
  surrounding `<label>` with `/click` instead.
- **The UI cache (`~/.config/heimdall/{Cache,Local Storage,…}`) survives
  restarts.** A wipe is needed when testing first-run flows; see the
  troubleshooting section.
- **Restarting the UI changes the debug port.** Always re-read
  `debug-instances.json` instead of hardcoding.

## Suggested improvements

These would make the API significantly more useful for unattended UI tests:

1. **Stable `data-debug-id` on every interactive element**, especially:
   - "+ Project", "Create project", "Save project" buttons on ProjectsPage
   - Project / template / provider selects on StartAgent (e.g.
     `start-agent-project-select`, `…-template-select`, `…-provider-select`)
   - Tier radios (`tier-cheap`, `tier-normal`, `tier-smart`)
   - Agent rows in the sidebar (`agent-row-<instanceId>`)
   - Project group toggles (`project-group-<projectId>`)
   - "Start agent", "Cancel" buttons

   Rule of thumb: any element a user clicks more than once during normal use
   deserves a debug-id. Cost is one attribute; benefit is selector stability
   across refactors.

2. **`/wait_for` endpoint** that polls for either a selector to appear or a
   state path to satisfy a JSON predicate. Today every recipe ends with
   `sleep 1; <check>` — racy and slow.

3. **Return Redux state diffs in event-stream form** (SSE on `/events`) so a
   driver can react to `chat_event` / `agent_lifecycle_changed` without
   polling `/state`.

4. **`/dispatch` endpoint** that fires arbitrary Redux actions from outside.
   Bypasses UI affordances entirely for setup steps where you just want the
   state to be a certain way (e.g. "select this agent" without simulating the
   click chain).

5. **`/screenshot` endpoint** that returns a PNG of the current view. Useful
   for bug repros where the textual state isn't enough.

6. **`text_contains` instead of `text` guard.** Exact-match guards break on
   React-concatenated text (badges, counters). A contains-match would catch
   the right element when the test author only knows part of the label.

7. **Document the endpoint list in `/info`.** Today `/info` returns
   `{pid,uptime,platform}`; adding `endpoints: [...]` makes the API
   self-describing for new drivers.

8. **Drop the broken text guard or make it a separate `assert_text` field**:
   right now `{"text":""}` is treated as "must equal empty", which silently
   rejects all matches.

## Quick troubleshooting

| Symptom | Cause / fix |
|---|---|
| `invalid client token` from daemon | UI cache is stale; wipe `~/.config/heimdall/{Local Storage,Session Storage,Cookies,Cache,...}` and restart UI |
| `/click` says `text guard failed` | The element's textContent doesn't match — drop `text` or use a more specific selector |
| `/select` says `unsupported tag` | Element isn't `<select>`/radio/checkbox — use `/click` for buttons, `/type` for text inputs |
| Element appears in `/elements` but not in `/query-selector` | `/elements` walks a curated set including `[data-debug-id]`; `/query-selector` uses raw CSS — pass the actual selector string |
| State path returns `{ok:false, message:"not found"}` | Path didn't exist at that key — `curl /state` to inspect the live shape |
