# Favorite-agent conversation launch

Status: implemented in the working tree; local manual testing is ready. No new test code.

## Behavior

Replace the existing new-conversation form with favorite agent cards above the
shared conversation composer. Seeded coordinator and worker remain pinned
favorites; other favorites belong to the authenticated user and reference durable
agent IDs. A pencil opens management to favorite an existing identity, create a
new identity already favorited, or remove an unpinned favorite.

The page remembers its selected favorite agent, project and bridge immediately in
Hub user preferences. This is selection history, not successful-launch history.
Other launch surfaces do not modify it. A project supplied by the task-chain plus
entry takes precedence over the remembered project, and is stored as this page's
current selection. Missing or archived choices cannot silently launch a different
agent/project. Offline/disconnected bridges and unsupported provider/model pairs
block Send with an actionable explanation.

Sending a nonempty first message (or uploaded attachments) creates a fresh agent
instance for the selected durable agent and project through the existing chat
launch endpoint, stores the first message and opens the instance conversation.
Selection alone never creates an instance. Project paths remain optional context.

## Contracts and implementation

1. Add durable, owner-scoped launch preferences and favorite records in SQLite.
   GET/PATCH /me/conversation-launch exposes selections and favorite IDs. PATCH
   updates only supplied selection fields, validates ownership and validates that
   a selected agent is a favorite. PUT /agents/:id/favorite adds/removes a favorite;
   coordinator/worker removal is rejected by the Hub. POST /agents supports
   favorite=true so creation from the management dialog favorites the new identity.
2. Extract shared composer input/actions and bridge/provider/model settings into
   components used by both the launch page and conversation thread. Retain mobile
   input/send/more layout, three-line growth, uploads and debug IDs. Thread-only
   runtime/pane controls stay conditional; launch has no runtime to stop yet.
3. Replace ConversationLaunchComposer with NewConversationPage; remove its old
   empty-launch form and dead post-launch settings code. Add favorite management,
   project picker and inline project creation modal using existing APIs.
4. Route task-chain plus buttons to /conversations/new?project_id=... . Preserve
   other chain-management routes. Handle parameter changes while the page is open.
5. Keep drafts through selection changes and failures, serialize preference writes
   per field, show persistence errors, and disable duplicate submission.

## Validation

Run TypeScript checks and native Hub build, inspect ownership/pinned-agent guards,
verify local preferences persist across reload and inspect both local bridges.
Manual checks: fresh first Send; favorite add/create/remove; pinned removal denial;
preselected project; remembered selection isolation; invalid selection handling;
mobile input/settings; upload and failed launch retaining draft. Do not add new
test code before the requested manual testing gate. Delete only the replaced page,
not agent/project management pages still used elsewhere.

## Implementation evidence

- Hub preferences persist favorites plus the three launch selection fields.
  Seeded pins are persisted independently of editable names; removal returned
  HTTP 409 for Coordinator and Worker during local checks. Trusted-proxy browser
  sessions and user API tokens are accepted; agent/bridge credentials are rejected.
- Shared input, actions and settings are used by both pages. The old launch form
  and its replaced chain-creation modal are deleted, with no source imports left.
- Browser checks saved Worker selection through the page without creating an
  instance. Reload restoration, pencil management, protected controls and the
  project plus entry were exercised. Preselection is consumed once so reload
  restores later user choices; repeated plus clicks work on the already-open page.
- Mobile browser inspection confirmed one-row input, Send and More, and no page
  overflow. Favorite cards use a fixed six-slot 3-by-2 grid. UI/Electron production build,
  TypeScript checks, native Hub build and whitespace checks passed.
- Local Hub and both Bridges are connected at http://127.0.0.1:5193. Actual first
  Send, new favorite identity, new project and upload remain user manual checks.
  The fresh browser's locked vault correctly prevented sending.

Favorite management uses an outline/filled star icon instead of text buttons.
Pinned stars remain selected and disabled. Coordinator cards/list rows show
“Multi-agent workflow”; Worker cards/list rows show “Single-agent workflow”.

Favorites are capped at six including both pinned agents, displayed in a fixed
3-column / 2-row grid with empty slots opening favorite management. The pencil
sits outside the six slots. Hub enforcement serializes create-and-favorite with
other favorite changes and checks capacity before creating an identity. At full
capacity, additions and create-and-favorite are disabled; removals remain usable.
The composer shows its selected bridge as a button opening the same Agent settings
modal for bridge/provider/model changes.

The launch heading uses a multilingual greeting chosen once per page mount plus
the authenticated user's display name (fallback to username). Subtitle: “Start a
conversation”. Bridge chips on the launch page and conversation thread open Agent
settings, where bridge/provider/model can be changed.

Shared dialog, menu, popover and selector panels use the active theme's surface
and text tokens; backdrops have a separate dimming token. Overlay surface tokens
now follow the theme surface, removing the default blue cast. The favorite grid
has 32px spacing before the composer on mobile and 40px on desktop.

Final local refinements validated: greeting includes the authenticated display
name; the six-slot grid has three columns and 40px desktop separation from the
composer. The composer bridge chip opens Agent settings. Dialog and project
selector surfaces matched theme tokens in all five built-in themes. An isolated
local user verified six favorites are allowed, a seventh favorite is rejected,
create-and-favorite at capacity creates no identity, and removing a favorite
unlocks another addition. Native Hub and UI/Electron production builds passed.

## Home integration

Home now embeds the same greeting/favorites/project/composer launch surface,
replacing its old Home heading/description/tab bar. Three large activity buttons
show Recent tasks, Recent issues and Pending actions, each with a description and
a count from the same queries used by the existing panels. Selection is exclusive
and optional; default is none. Selection shows one existing panel and smoothly
scrolls its buttons to the top. Deselecting smoothly returns Home to the top; the
outgoing panel remains mounted until that scroll finishes to prevent scroll-height
clamping. Home uses the shell's scrolling layout, while activity panels retain
a bounded height for their existing internal lists. Existing tab deep links and
browser navigation remain supported. Home launch choices share the same Hub
preferences; ordinary launches elsewhere still do not update them.

Home validation: local desktop and 390px mobile browser checks confirmed exclusive
activity selection, switching panels, smooth scrolling with cards aligned 16px
from the scroll container top, and deselection returning scrollTop to zero before
removing the panel. Panel height reserves enough content below the controls for
empty panels to align correctly. Typecheck, UI/Electron production build and
whitespace checks passed. Both local bridges are online with runtime command
connections. No new repository tests were written; first-message launches and
uploads remain for user manual testing with the vault unlocked.

Layout refinement: the shared launch surface uses three vertical regions for the
centered greeting/favorites, composer, and Home activity buttons. All regions use
the same centered maximum width; activity cards are equal thirds. The greeting and subtitle are left-aligned. Activity content is anchored 20px
below the controls without changing the launch grid's tracks or spacing. A
separate scroll-space reservation supports the panel while preserving the
composer and agent positions through selection and deselection. Local desktop/mobile geometry checks confirmed equal widths,
no horizontal overflow, and preserved select/deselect scrolling.

Send transition: animate the launch dock to the visible main area's bottom over
420ms while the launch request runs, then navigate after both finish. Respect
reduced-motion settings, prevent duplicate sends through the transition, and
cancel/reset the animation on launch failure while retaining draft/attachments.
The actual agent launch transition remains a user manual check.
