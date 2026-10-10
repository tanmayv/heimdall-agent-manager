-- Billing is account scoped. Catalog IDs are arbitrary strings; consumers use
-- effective parameters. Overrides are separate and survive webhook updates.
CREATE TABLE billing_plans (
    plan_id TEXT PRIMARY KEY,
    plan_label TEXT NOT NULL,
    price_id TEXT UNIQUE,
    max_bridges INTEGER NOT NULL CHECK (max_bridges >= 0),
    terminal_streaming_enabled INTEGER NOT NULL CHECK (terminal_streaming_enabled IN (0, 1))
);
INSERT INTO billing_plans VALUES ('free', 'Free', NULL, 2, 0), ('hobbyist', 'Hobbyist', NULL, 2, 1);
-- Preserve approved historical prices when the current checkout price changes.
CREATE TABLE billing_plan_prices (
    price_id TEXT PRIMARY KEY,
    plan_id TEXT NOT NULL REFERENCES billing_plans(plan_id)
);

CREATE TABLE account_billing (
    user_id TEXT PRIMARY KEY REFERENCES users(user_id),
    plan_id TEXT NOT NULL REFERENCES billing_plans(plan_id) DEFAULT 'free',
    status TEXT NOT NULL DEFAULT 'free',
    customer_id TEXT UNIQUE,
    subscription_id TEXT UNIQUE,
    price_id TEXT NOT NULL DEFAULT '',
    renews_at TEXT NOT NULL DEFAULT '',
    cancels_at TEXT NOT NULL DEFAULT '',
    grace_until TEXT NOT NULL DEFAULT '',
    last_event_ns INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
CREATE TABLE account_entitlements (
    user_id TEXT PRIMARY KEY REFERENCES account_billing(user_id),
    max_bridges INTEGER NOT NULL CHECK (max_bridges >= 0),
    terminal_streaming_enabled INTEGER NOT NULL CHECK (terminal_streaming_enabled IN (0, 1)),
    override_max_bridges INTEGER CHECK (override_max_bridges >= 0),
    override_terminal_streaming_enabled INTEGER CHECK (override_terminal_streaming_enabled IN (0, 1)),
    override_reason TEXT NOT NULL DEFAULT '',
    override_updated_by TEXT NOT NULL DEFAULT '',
    updated_at TEXT NOT NULL
);
INSERT INTO account_billing (user_id, created_at, updated_at) SELECT user_id, created_at, updated_at FROM users;
INSERT INTO account_entitlements (user_id, max_bridges, terminal_streaming_enabled, updated_at)
    SELECT user_id, 2, 0, updated_at FROM account_billing;

-- Provision defaults even if a new Authentik user never opens Account settings.
CREATE TRIGGER users_billing_defaults AFTER INSERT ON users BEGIN
    INSERT INTO account_billing (user_id, created_at, updated_at)
        VALUES (NEW.user_id, NEW.created_at, NEW.updated_at);
    INSERT INTO account_entitlements (user_id, max_bridges, terminal_streaming_enabled, updated_at)
        SELECT NEW.user_id, max_bridges, terminal_streaming_enabled, NEW.updated_at
        FROM billing_plans WHERE plan_id = 'free';
END;

CREATE TABLE billing_checkouts (
    reference TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES account_billing(user_id),
    plan_id TEXT NOT NULL REFERENCES billing_plans(plan_id),
    price_id TEXT NOT NULL,
    transaction_id TEXT NOT NULL DEFAULT '',
    expires_at TEXT NOT NULL
);
CREATE INDEX billing_checkouts_owner ON billing_checkouts(user_id, expires_at);
CREATE TABLE billing_events (
    event_id TEXT PRIMARY KEY,
    event_type TEXT NOT NULL,
    occurred_ns INTEGER NOT NULL,
    subscription_id TEXT NOT NULL,
    processed_at TEXT NOT NULL
);
-- Prevent accidentally processing sandbox events against live account mappings.
CREATE TABLE billing_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
