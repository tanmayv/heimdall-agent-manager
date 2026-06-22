# Electron UI Performance Debugging & Suggestions

Based on the analysis and Duckie's guidance, the sluggish animations and slow rendering in the Electron application are likely caused by a combination of CSS rendering bottlenecks, state management overhead, and logging blocking the UI thread.

## 1. Excessive Layout Thrashing via `transition-all`
**Problem:** In many components (`AgentListItem.tsx`, `AuditCard.tsx`, `MessageBubble.tsx`, `TaskBoard.tsx`), the `transition-all` class is widely used. `transition-all` forces the browser to animate layout properties (like `width`, `height`, `margin`), which triggers expensive **Layout and Reflow** calculations on every frame instead of just Composition.
**Fixes:**
- Replace `transition-all` with targeted transitions like `transition-transform` or `transition-opacity`.
- If scaling or moving elements, only animate `transform` properties (`scale`, `translate`), which are GPU accelerated.
- Example in `AgentListItem.tsx`: Change `transition-all duration-300` to `transition-[transform,opacity,background-color] duration-300`.

## 2. Redux State & Excessive Re-renders
**Problem:** The app uses Redux (`store.ts` with `chatSlice`, `taskSlice`, etc.). If state updates occur too frequently (e.g. streaming IPC data or tracking rapid changes), it will trigger top-down re-renders. 
**Fixes:**
- Ensure components like `MessageBubble.tsx` or `TaskBoard.tsx` list items are wrapped in `React.memo()` so they only re-render when their specific props change.
- Batch frequent IPC messages or throttle Redux updates if they arrive at a high rate.

## 3. Synchronous Console Logging in Redux
**Problem:** `store.ts` implements a custom `actionLogger` middleware that runs `console.log` on every dispatched Redux action.
**Fixes:**
- Console logging in the Electron renderer is synchronous and can block the UI thread during high-frequency events. Disable `actionLogger` in production or wrap it in a debounce/dev-only flag.

## 4. IPC Overhead
**Problem:** If the main process sends massive payloads (e.g., entire message history on every keystroke) over IPC, serialization/deserialization will block the renderer.
**Fixes:**
- Only send the delta (the changed fields) over IPC, not the whole state object.
