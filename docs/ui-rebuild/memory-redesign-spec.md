# Memory redesign spec — VERBATIM from the user

> Authoritative for the Memory list and detail views. Where it conflicts with
> docs/ui-rebuild/memory.md, THIS wins. The user closed with: "Use the above as
> reference but with selected colorscheme colors" — so the literal hex values below
> are a REFERENCE for intent; use the existing design tokens (tokens.css / Tailwind
> aliases), never raw hex. The @ui tokens-only rule still holds.

## SUPERSEDED CLAUSES — read this before implementing anything below

**The text below is preserved verbatim and is NOT edited**, because it is the user's own words
and the record of what they asked for. But they have since changed their mind about several
things *in conversation*, and a later instruction beats an earlier one. Where this table and the
body disagree, **this table wins**; `memory.md` Amendment 2 is the description of what exists.

| The spec below says | What the user later said | Where it is recorded |
|---|---|---|
| Rows are title + a **one-line** body snippet + one meta line | Four lines: title + `…` / body over **two** lines / pills left + time right — *"ensure body can span two lines and not truncate just on one"* | A2.1 |
| Proposals rows carry **inline Approve / Reject**, revealed on hover | Rows carry **only** a `…` menu — *"Lets remove the button all together from the entries"*, *"hide the hover to show button"* | A2.3, A2.10 |
| Mobile: **swipe** right approves, left rejects | No swipe — *"remove the slide for actions feature it doesn't work well on mobile"* | A2.7, A2.10 |
| Toolbar carries a **Select** button; "Move Select into the toolbar" | No Select toggle at all; checkboxes are persistent — *"no selecttoggel."* | A2.2 |
| Tabs carry **count badges** | Dropped — no totals exist in the API (F10) | A2.6 |
| Detail `…` menu = Edit, Archive, **Delete** | There is no delete anywhere in this UI; Archive is the permanent answer | A2.5 |
| Details section lists **Created** and **Source agent**; meta line carries an **Agent badge** | All three dropped — `created_at` is not serialised (F12) and a memory has no author field | A2.5 |
| Evidence `file:line` refs are **links** | Not auto-linked — a heuristic link that lies about its destination is worse than honest plain text | A2.5 |
| After approve/reject, **decrement the tab count** | Moot: there are no tab counts. Auto-advance still ships | A2.6 |

---

Rebuild the Memory list (#/memory) and Memory detail (#/memory/:id)
views. Keep existing routes, data, and API calls. Reuse existing
design tokens/components; only add what's listed. Dark theme.

TOKENS
- Bg #0A0A0A, surface #161616, surface-hover #1E1E1E,
  border #262626, text #FAFAFA, muted #A1A1A1, accent #4C9AFF,
  pending amber #F5A524 on rgba(245,165,36,.12).
- Radius: 10px controls, 14px cards, 999px chips.
- Spacing on a 4px grid. Page padding 16px mobile, 32px desktop.
- H1 28/34 mobile, 32/40 desktop, weight 650, tracking -0.01em
  (no tighter). Body 15/22. Meta 13/18 muted.
- One line-icon set everywhere (e.g. Lucide). No emoji icons.
- Breakpoint: <768 mobile, >=768 desktop.

LIST VIEW
Header: single H1 "Memory" (remove breadcrumb duplicate), one-line
muted description. "New memory" primary button right-aligned in the
header row on desktop; on mobile it's an icon+label button on the
same row as the H1. Move "Select" into the toolbar.

Toolbar (one row, 12px below header): search input (flex 1),
Filters button with active-count badge, Select button. On mobile
Filters and Select become icon buttons. Filters opens a popover on
desktop, bottom sheet on mobile. Put the "Scope filters show
memories that apply to the selection, including global" helper
text inside that panel, not on the page. Show active filters as
removable chips under the toolbar.

Tabs: Proposals / Active / Archived with count badges. 16px gap
below tabs before content.

Rows: strip the "Agent proposed:" prefix from display titles;
show source as a small "Agent" badge with icon instead. Row =
title (1 line, truncate), body snippet (1 line muted, truncate),
meta line: type chip · status chip · relative time · scope.
Scope: if all four dimensions are empty show one "Global" chip;
otherwise show up to 2 specific chips then "+N".
In Proposals tab each row has inline Approve (accent, small) and
Reject (ghost) buttons on desktop, visible on hover/focus and
always visible at >=1024. On mobile: swipe right = approve, swipe
left = reject, with a 5s Undo toast; keep "…" menu as the
accessible fallback. Row tap opens detail. Rows 72px min height,
divider borders, hover surface.

Desktop layout: two-pane master/detail at >=1024. List max-width
420px on the left, detail on the right, selected row highlighted.
Between 768-1023 use single column, max-width 720px centered.
Support j/k to move, a approve, r reject, / focus search.

States: skeleton rows while loading; empty state per tab
("No pending proposals. Agents will suggest memories here.");
error state with Retry.

DETAIL VIEW
Header: back link "← Memory" on mobile; breadcrumb "Memory / Proposals"
on desktop (never repeat the item title in the breadcrumb). H1 =
title without prefix. Under it one meta line: Agent badge · type
chip · status chip · "Updated 1h ago" (absolute date in title attr,
format "21 Sep 2026, 19:58").
Actions: desktop = Approve (primary), Reject (secondary), "…"
menu (Edit, Archive, Delete) right-aligned in the header. Mobile =
sticky bottom action bar above the tab nav with Reject and Approve
at 50/50 width, 48px tall; "…" stays in the header.

Sections, each a surface card with 16px padding, 12px gap:
1. Body: label + helper "The text your agents receive." Text
   inside the card. Copy icon button top-right of the card,
   inline with the label (no separate row).
2. Evidence: monospace 13px, each item a row; file:line refs
   are links. Copy icon inline right. No empty padding above.
3. Scope: merge the current Scope and Linked resources sections.
   A 4-row key/value list (Projects, Agents, Bridges, Templates);
   value is chips or muted "All". If all four are empty show a
   single "Global: applies everywhere" line plus an "Edit scope"
   link. Keep the "ALL four dimensions must match" rule as an
   info tooltip.
4. Details: only Created, Updated, Source agent, Memory ID
   (monospace, copy icon button). Remove Type and Status, since
   they're in the header.
Desktop: sections 1-2 in a main column, 3-4 in a 320px right
rail when the pane is >=900px wide; otherwise stacked.

GLOBAL FIXES
- Scroll container gets padding-bottom = nav height + action bar
  height + env(safe-area-inset-bottom) so nothing is clipped.
- Bottom nav gets padding-bottom env(safe-area-inset-bottom) and
  a solid background (no content bleeding through blur).
- All touch targets >=44px; visible focus rings; aria-labels on
  icon buttons; chips aren't color-only (keep text labels).
- After approve/reject, auto-advance to the next proposal and
  decrement the tab count optimistically.

Deliver: both views at 390px and 1440px, with screenshots of the
list, detail, filter panel, empty, and loading states.
 Use the above as reference buth with selected solorscheme colors