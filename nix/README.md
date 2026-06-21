# Heimdall Home Manager Module

The flake exposes a Home Manager module under `homeModules.default` (also
`homeManagerModules.default`).  Enabling it:

1. Installs the selected `ham-*` binaries and adds them to `$PATH`.
2. Writes `~/.config/heimdall/config.toml` from declarative Nix options.

---

## Quickstart

```nix
# flake.nix inputs
inputs.heimdall.url = "github:yourorg/heimdall-agent-manager";
```

```nix
# home-manager module
{ inputs, ... }:
{
  imports = [ inputs.heimdall.homeModules.default ];

  programs.heimdall = {
    enable       = true;
    packageNames = [ "daemon" "wrapper" "ctl" ];  # adds ham-daemon, ham-wrapper, ham-ctl to PATH
  };
}
```

This generates a minimal `~/.config/heimdall/config.toml` with the defaults
shown below and installs the three core binaries.

---

## Full example — equivalent to the repo's `config.toml`

The following Nix configuration produces the same `config.toml` that ships
with the repository on this system.

```nix
programs.heimdall = {
  enable       = true;
  packageNames = [ "daemon" "wrapper" "ctl" "ui" ];

  # ── [daemon] ────────────────────────────────────────────────────────────
  daemon = {
    bindHost = "127.0.0.1";
    port     = 49322;
    dataDir  = "~/.local/share/heimdall";

    # Optional nudge settings (all null = omitted from config.toml):
    # nudge.enabled                      = false;
    # nudge.intervalSeconds              = 60;
    # nudge.readyAfterSeconds            = 300;
    # nudge.reviewAfterSeconds           = 300;
    # nudge.needImprovementsAfterSeconds = 300;
    # nudge.workingStaleAfterSeconds     = 900;
    # nudge.cooldownSeconds              = 300;
    # nudge.restartGraceSeconds          = 60;
    # nudge.sendEscapePrefix             = false;
    # startupStaleAfterSeconds           = 120;
  };

  # ── [wrapper] ───────────────────────────────────────────────────────────
  wrapper = {
    daemonUrl           = "http://127.0.0.1:49322";
    credentialsPath     = "~/.local/share/heimdall/wrapper-credentials.json";
    agentName           = "pi";
    defaultAgent        = "pi";
    displayName         = "{instance}";
    requestedAccessMode = "main";
    command             = [ "pi" ];
    tmuxSession         = "ham-agents";
    tmuxWindowPrefix    = "agent";
    agentRunDir         = "~/.local/share/heimdall/agent-runs";
    project             = "default";
    memoryTemplates     = [];

    agentCommands = {

      # [wrapper.agent-cmd.pi]
      pi = {
        command        = [ "pi" ];
        project        = "project_1781933146508";
        memoryTemplates = [ "bootstrap-guidance" ];
        yoloFlags      = [];
        promptFlags    = [];
        starterPrompt  = "First, run: {ctl_bin} --token {token} start-success. Then read your bootstrap file (AGENTS.md or CLAUDE.md) for context, identity, and what you can do.";

        # bootstrap section only needed for per-file overrides (name, content, dir)
        # All three files (AGENTS_MD, MEMORY_MD, SKILLS) are always generated.

        models = {
          flag   = "--model";
          cheap  = "openai-codex/gpt-5.3-codex-spark";
          normal = "sonnet";
          smart  = "opus";
        };

        startupDetection = {
          enabled       = false;
          readyOnLaunch = true;
        };
      };

      # [wrapper.agent-cmd.claude]
      claude = {
        command       = [ "claude" ];
        yoloFlags     = [ "--dangerously-skip-permissions" ];
        promptFlags   = [];
        starterPrompt = "First, run: {ctl_bin} --token {token} start-success. Then read your bootstrap file (AGENTS.md or CLAUDE.md) for context, identity, and what you can do.";

        bootstrap = {
          agentsMd = {
            name    = "CLAUDE.md";
            content = [ "IDENTITY" "GUIDANCE" "PROJECT" "MEMORY" ];
          };
          memoryMd.name = "MEMORY.md";
          skills = {
            relativeDir = "skills";
            filename    = "SKILL.md";
          };
        };

        models = {
          flag   = "--model";
          cheap  = "haiku";
          normal = "sonnet";
          smart  = "opus";
        };

        startupDetection = {
          enabled                = true;
          startupProbeSeconds    = 20;
          captureIntervalMs      = 500;
          autoEnterPatterns      = [
            "Yes, I trust this folder"
            "WARNING: Claude Code running in Bypass Permissions mode"
          ];
          autoEnterPreKeys       = [ "" "Down" ];
          blockedPatterns        = [ "Enter auto mode" ];
          startupUnknownIsBlocked = false;
          sanitizedReasonMapping = [
            "trust=Claude directory trust prompt"
            "trust=Claude directory trust prompt"
            "bypass=Claude bypass permissions warning"
            "confirm=Claude interactive confirm prompt"
          ];
        };
      };

      # [wrapper.agent-cmd.codex]
      codex = {
        command       = [ "codex" ];
        yoloFlags     = [];
        promptFlags   = [];
        starterPrompt = "First, run: {ctl_bin} --token {token} start-success. Then read your bootstrap file (AGENTS.md or CLAUDE.md) for context, identity, and what you can do.";

        # No bootstrap overrides needed; all three files are generated with defaults.

        models = {
          flag   = "-m";
          cheap  = "gpt-5-mini";
          normal = "gpt-5";
          smart  = "gpt-5-pro";
        };
        # No startupDetection → section omitted from config.toml
      };
    };
  };

  # ── [ctl] ───────────────────────────────────────────────────────────────
  ctl.daemonUrl = "http://127.0.0.1:49322";
};
```

---

## Option reference

### `programs.heimdall`

| Option | Type | Default | Description |
|---|---|---|---|
| `enable` | bool | — | Enable the module |
| `packageNames` | list of enum | `["daemon" "wrapper" "ctl"]` | Packages to install / add to `$PATH` |
| `extraPackages` | list of package | `[]` | Additional arbitrary packages |

**Package name → binary mapping**

| Name | Binaries added to `$PATH` |
|---|---|
| `daemon` | `ham-daemon`, `bc-odin-daemon` |
| `wrapper` | `ham-wrapper`, `bc-agent-wrapper` |
| `ctl` | `ham-ctl`, `bc-odinctl` |
| `test-agent` | `ham-test-agent` |
| `ui` | `heimdall` (Electron app) |

### `programs.heimdall.daemon`

| Option | Type | Default |
|---|---|---|
| `enable` | bool | `true` |
| `bindHost` | str | `"127.0.0.1"` |
| `port` | port | `49322` |
| `dataDir` | str | `"~/.local/share/heimdall"` |
| `startupStaleAfterSeconds` | int \| null | `null` |
| `nudge.enabled` | bool \| null | `null` |
| `nudge.intervalSeconds` | int \| null | `null` |
| `nudge.{ready,review,needImprovements,workingStale}AfterSeconds` | int \| null | `null` |
| `nudge.{cooldown,restartGrace}Seconds` | int \| null | `null` |
| `nudge.sendEscapePrefix` | bool \| null | `null` |

`null` values are omitted from the generated TOML (daemon built-in defaults apply).

### `programs.heimdall.wrapper`

| Option | Type | Default |
|---|---|---|
| `enable` | bool | `true` |
| `daemonUrl` | str | `"http://127.0.0.1:49322"` |
| `credentialsPath` | str | `"~/.local/share/heimdall/wrapper-credentials.json"` |
| `agentName` | str | `"pi"` |
| `defaultAgent` | str | `"pi"` |
| `displayName` | str | `"{instance}"` |
| `requestedAccessMode` | `"main"\|"review"\|"readonly"` | `"main"` |
| `command` | list of str | `[]` |
| `tmuxSession` | str | `"ham-agents"` |
| `tmuxWindowPrefix` | str | `"agent"` |
| `agentRunDir` | str \| null | `"~/.local/share/heimdall/agent-runs"` |
| `project` | str | `"default"` |
| `memoryTemplates` | list of str | `[]` |
| `agentCommands` | attrs of agentCmd | `{}` |

### `programs.heimdall.wrapper.agentCommands.<name>`

| Option | Type | Default |
|---|---|---|
| `command` | list of str | `[]` |
| `project` | str \| null | `null` |
| `memoryTemplates` | list of str | `[]` |
| `yoloFlags` | list of str | `[]` |
| `promptFlags` | list of str | `[]` |
| `starterPrompt` | str \| null | `null` |
| `bootstrap.agentsMd.{name,content}` | see above | `null` (defaults: AGENTS.md or CLAUDE.md, all sections) |
| `bootstrap.memoryMd.name` | str \| null | `null` |
| `bootstrap.skills.{relativeDir,filename}` | str \| null | `null` |
| `models.{flag,cheap,normal,smart}` | str | `"--model"` / `null` |
| `startupDetection` | submodule \| null | `null` (section omitted) |

### `programs.heimdall.ctl`

| Option | Type | Default |
|---|---|---|
| `enable` | bool | `true` |
| `daemonUrl` | str | `"http://127.0.0.1:49322"` |

