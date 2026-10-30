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
runs never prompt.

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
registered. Hook trust is per plugin: the own plugin is a different plugin id
from `heimdall@heimdall-codex`, so hook trust granted to the shared plugin in
the Codex TUI does not carry over. Claude keeps the shared registration.

Uninstalling a profile removes only that profile's own copy; the shared root and
the provider registration stay. Removing a provider's extension from the hub
(Settings) is left undone, with a message, while another profile of this OS user
is installed. Uninstalling any account, in any order, leaves the others' agents
working.
