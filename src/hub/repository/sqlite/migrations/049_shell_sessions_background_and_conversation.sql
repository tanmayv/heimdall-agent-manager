-- REQ-SHELL-2: two columns the explicit-backgrounding model needs on the row.
--
-- background. REQ-SHELL-2 deletes the implicit 15s auto-background rule and makes
-- backgrounding EXPLICIT, which turns it into a property of the session rather
-- than an accident of how long it happened to run. It has to live on the row, not
-- only on the bridge, for two reasons: ONLY background runs notify (REQ-SHELL-5
-- reads this to decide whether to deliver a completion message at all), and a
-- user can flip a live foreground run to background from the UI (REQ-SHELL-6),
-- which is a hub-side write that must survive a bridge restart.
--
-- It is one-way. A run starts foreground or background and can only ever move
-- foreground -> background; nothing sets it back to 0. That is what makes the
-- blocked caller's release unambiguous -- there is no second waiter to race, and
-- no state in which a run has notified and then stopped being notifiable.
--
-- Only kind='run' uses it. A `shell` is an interactive terminal with no caller to
-- block, and a `server` is long-running by definition -- neither has a foreground
-- form, so both leave this 0 rather than carrying a flag that describes nothing.
ALTER TABLE shell_sessions ADD COLUMN background INTEGER NOT NULL DEFAULT 0;

-- conversation_id. The conversation that TRIGGERED the session. REQ-SHELL-2 §5
-- requires it on the row because REQ-SHELL-5 scopes the completion marker message
-- to the triggering conversation ONLY -- a run must not fan out to a chain-wide or
-- user-wide feed -- and REQ-SHELL-6 filters the UI on it. A run with this empty
-- cannot be rendered against the conversation that asked for it.
--
-- This is NOT a scope column. Scope is defined once, in
-- domain.SHELL_SESSION_SCOPE_RULES, and run is AGENT scoped (keyed by
-- agent_instance_id). conversation_id is an ANNOTATION in the same sense
-- project_id is: it says where to deliver, not who owns. Adding it to the scope
-- rules would be a second spelling of ownership, which is exactly the drift those
-- rules exist to prevent.
ALTER TABLE shell_sessions ADD COLUMN conversation_id TEXT NOT NULL DEFAULT '';

-- The delivery lookup REQ-SHELL-5/6 make: "the runs triggered by this
-- conversation". Owner-qualified like every other index on this table, so it
-- serves the owner-scoped read the service actually issues.
CREATE INDEX IF NOT EXISTS shell_sessions_conversation ON shell_sessions(owner_user_id, conversation_id);
