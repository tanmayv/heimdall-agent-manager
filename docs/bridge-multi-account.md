# Several Ninjy accounts on one machine

Several Ninjy accounts can use one machine and one OS user, on the same hub or on
different hubs. Each account gets its own bridge **profile**: one bridge service,
one bridge on the hub, and its own binaries, ports, state and secrets. Installing,
updating or uninstalling one account's profile never replaces, stops or breaks
another's.

## What each account owns, and what is shared

| | per account (profile) | shared by every profile of the OS user |
|---|---|---|
| service | `heimdall-bridge-<hub>[_<profile>]` (systemd user unit, launchd agent, runit service) | |
| state | `~/.config/heimdall/bridges/<service>/` (config, credential, ports) | |
| data, binaries | `~/.local/share/heimdall/bridges/<service>/` including `bin/ham-bridge`, `bin/ham-ctl` | |
| ports | `ports.json`; a pair another profile has recorded is never taken | |
| provider profiles | `<data dir>/bridge/provider_profiles.json` (binary, config dir, model) | |
| coding-agent CLIs | | `claude`, `codex`, ... from the machine's `PATH` (the default) |
| provider extensions | | `~/.local/share/heimdall/bridges/.shared-extensions/<version>/extensions` |

On Windows the same split applies under `%APPDATA%` and `%LOCALAPPDATA%`.

## Installing a second account

The profile is chosen by `--hub` and `--profile`. A profile belongs to the account
that enrolled it. To add another account:

```bash
# Pick the profile name yourself
ham-bridge setup --hub https://hub.example.com --profile work

# Or let setup pick one: the requested profile when nobody enrolled it yet,
# otherwise the first free account-2, account-3, ...
ham-bridge setup --hub https://hub.example.com --separate-account
curl -fsSL install.ninjy.ai | bash -s -- --hub https://hub.example.com --separate-account
```

`install.sh` passes `--separate-account` through to `ham-bridge setup`, so the
Ninjy desktop flow (`install.sh --interactive`) uses it when the signed-in user
chose to add an account rather than replace the machine's bridge. Setup records
the chosen profile, so `ham-bridge update` keeps updating that profile.

A setup run on a terminal that would re-enroll a profile another bridge already
holds (`--new-bridge`, `--reenroll`, `--reuse-bridge` of another bridge) asks
whether this is a different account and, on yes, installs a separate profile.
Updates of an enrolled profile never ask. `--headless` and `--json-progress`
runs never prompt: one that would enroll a new bridge into an enrolled profile
(`--new-bridge`, `--reuse-bridge` of another bridge) installs a separate profile
instead, leaving the enrolled one's service, ports and credential untouched.
`--reenroll` re-pairs the profile's own bridge in place.

The Ninjy desktop app (Settings > Bridges > This machine) matches the profiles in
`ham-bridge list --json` against the signed-in account's bridges on the Hub. It
shows only profiles linked to the signed-in account by default. **Show other
local profiles** reveals other accounts' and unenrolled slots for this Hub, but
never adds controls to manage another account's Bridge. Switching accounts
resets this toggle. Setup still discovers every profile internally to avoid
replacing or stopping another account's service. An empty list
is shown as "No Bridge profiles installed". The unnamed default profile is a
valid slot, distinct from having no available profile. The first-time wizard
lets you select an unenrolled profile or create a named one; Retry keeps that
selection. Profile names use 1-31 lowercase letters, digits or dashes, starting
with a letter or digit. Without one, it runs setup
with `--separate-account`, even for the first bridge, so a second account's
install never stops, replaces or reconfigures the first account's running
bridge. Replacing is offered only as an explicit choice after an enrollment
refusal. The first-launch setup (before sign-in) runs only when no bridge is
installed for the Hub.

Replacing the account that owns a profile is still explicit:
`--replace-other-account` (mutually exclusive with `--separate-account`) revokes
the old account's bridge and wipes its secrets before the new account's
credential is written.

## Managing each account's install

`ham-bridge list` shows every profile. `status`, `service start|stop|restart`,
`update` and `uninstall` act on one profile, named with `--hub URL [--profile P]`
or `--service NAME`; with several profiles installed they refuse to guess.

```bash
ham-bridge list
ham-bridge status --hub https://hub.example.com --profile account-2
ham-bridge uninstall --hub https://hub.example.com --profile account-2
```

## Provider extensions

Every profile publishes its bundled extensions once per release to the shared
root and registers the `heimdall` / `heimdall-codex` marketplaces from the newest
release there; hooks call each agent's own `$HEIMDALL_CTL_BIN`, so one
registration serves every account. A registration that points at a profile's own
copy or an older shared release moves to the shared root; a strictly newer one,
from a profile already updated, is left alone. Older shared releases are pruned
once every provider uses the newest.

A per-account provider profile (its own config dir) is not shared, so its
extension registers from that profile's own `<data dir>/extensions` copy. That
path stays the same across updates and no other profile's prune touches it.

Codex agents of the default provider config run their own bridge's extension,
not the newest shared one. Each profile also registers a copy of its
`<data dir>/extensions/codex` (under `<data dir>/codex-marketplace`) as the
marketplace `heimdall-codex-<service>`, saved in the user's `config.toml` with
`enabled = false`. That way the user's own Codex sessions and other bridges'
agents don't load it. Agents launch with
`-c plugins.heimdall@heimdall-codex.enabled=false -c plugins.heimdall@heimdall-codex-<service>.enabled=true`,
so exactly one Heimdall plugin loads, with the shared `CODEX_HOME` and login.
Without that registration (for example when the copy is missing), the launch
adds no override and uses the shared release. Removing the extension from the
hub, or `ham-bridge uninstall` (with or without `--purge`), removes only that
profile's own marketplace, plugin table and install cache, before its
`codex-marketplace` copy is deleted. Every ensure also drops any
`heimdall-codex-*` marketplace whose source directory is gone (a bridge removed
by hand), because Codex fails every `codex plugin list` while one is
registered. These `config.toml` edits change only the bridge's own two tables
and keep every other byte, comments included; when the file has a line that
cannot be read for certain (an escaped quote in a table name, or invalid TOML),
the bridge leaves the file unchanged and reports it. Uninstall makes its edit
under the same per-OS-user lock as the bridges' extension installs. Hook trust is per plugin: the own plugin is a different plugin id
from `heimdall@heimdall-codex`, so hook trust granted to the shared plugin in
the Codex TUI does not carry over. Claude keeps the shared registration.

Uninstalling a profile removes only that profile's own copy; the shared root and
the provider registration stay. Removing a provider's extension from the hub
(Settings) is left undone, with a message, while another profile of this OS user
is installed. Uninstalling any account, in any order, leaves the others' agents
working.

## Choosing a bridge release

In **Settings → Bridges**, open a bridge and choose **Update**. The version
selector shows prereleases newer than the running version and the latest stable
release. Prereleases are labeled; a stable release older than the running version
is labeled **Downgrade** and requires a separate confirmation checkbox. Changing
the selected version or reopening the dialog clears that confirmation. The
desktop **This machine → Update** action opens the same selector.

Releases without this machine's bundle or `SHA256SUMS` are visible but disabled.
The Hub refreshes release metadata in the background every 30 minutes, including
paginated release lists. A failed refresh keeps the last complete list. Before
metadata is loaded, the manifest/operator target remains the fallback.

The request carries the exact selected `target_version`; older targets require
`allow_downgrade: true`, independently of force/drain settings. The Hub resolves
that release's SHA-256 digest before dispatch. The bridge verifies the downloaded
bundle and checks its reported version before stopping agents, then uses the
existing `ham-bridge update --bundle` transaction and health-checked rollback.
Downgrades use the current updater to run the older bundle's setup command.
This manual path stages a verified bundle; the CLI's `update --version` resolves
and stages a release locally before reaching the same setup transaction.

## Automatic bridge updates

Installed profiles check for promoted releases about every six hours, with 10%
jitter, even when the desktop app is closed. Each profile checks its Hub catalog
first and falls back to GitHub if the catalog is unavailable. Downloads use the
existing SHA-256 verified release updater. Equal and older versions are skipped.

Automatic updates wait for a full minute with no running or starting agents.
New agent launches receive a retriable response while the updater applies the release. The detached
updater changes only its own profile; a kernel lock serializes automatic updates
across all accounts and Hubs belonging to the OS user. Other profiles keep running.
Setup verifies the restarted bridge and rolls back on failure. Retry state is
stored per profile in `auto-update.json`; failures back off from six hours up to
four days (with jitter), including after a crash or rollback.

Automatic updates are on by default. Toggle **Automatic bridge updates** in
**Settings → Bridges** while the bridge is online, or edit that profile's
`config.toml` (no restart needed):

```toml
[bridge]
auto_update_enabled = false
```

The setting applies only to that profile and is preserved by updates. A running
update finishes its current transaction; disabling the setting prevents the next
automatic update. Manual updates remain available.

Automatic updates still prefer a quiet window, but an update that stays overdue
is eventually forced. Once a profile has had no quiet window for
`auto_update_max_defer_hours` (default 24) after its scheduled check, the bridge
logs it and shows a notice on the bridge in the Hub ("auto-update to vX forcing
in ~2 min; K agents will be stopped"). About two minutes later it stops the PTY
host and every agent it hosts (agents preserved across bridge restarts
included), then runs the same verified, rolled-back-on-failure update. Stopped
agents do not restart on their own; their terminal status reaches the Hub. The
outcome (succeeded, or failed / rolled back) is reported on the bridge too. If
the agents finish during the notice, the update goes through the quiet window
instead.

```toml
[bridge]
auto_update_max_defer_hours = 24  # 0 = never force: wait for a quiet window indefinitely
```

With `0`, a profile with continuously running agents waits indefinitely, as
before. If the PTY host cannot be queried, the quiet window is never granted,
so only forcing (or a manual update) can proceed. Stop long-lived agents to
permit the next automatic check, or use the manual Update action.

Only *running* PTY host entries count against the quiet window: agents and
`ham-ctl shell` sessions that are alive. The PTY host keeps an exited agent or
shell run registered (with its exit code) until it is closed; those do not
block an update. Bridges up to v0.5.80 counted them, so one finished shell run
was enough to postpone every automatic check until it was forced
`auto_update_max_defer_hours` later.

The worker writes its decisions to the bridge log (journal / service log), each
line prefixed `bridge auto-update:`. At start it logs `worker started for
<profile> (...)` with the next due time, or `worker not started: <reason>`
(for example, the binary is not running from its profile's `bin/`). Each check
logs its outcome: `up to date`, `check failed` (lookup), `updating A -> B`, or
why it did not start the updater. While a due check waits for a quiet window it
logs the reason once, and again only when the reason changes:

```text
bridge auto-update: check due; waiting for a quiet window: 2 running agent(s) or shell session(s) on the PTY host
```

**Bridges on v0.5.80 or older** (one time). These versions wait for a quiet
window that exited PTY entries never grant. Nothing needs reinstalling; any of
these gets them onto a fixed version, after which they update on their own:

- use the bridge's **Update** action in the Hub (not gated on the quiet window), or
  run `ham-bridge update --service <profile>` on the host;
- or wait: the update is forced `auto_update_max_defer_hours` (default 24) after
  the overdue check, stopping that profile's PTY host and agents.
