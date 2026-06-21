# Heimdall AI Manager – Home Manager module
#
# Exposes programs.heimdall.{daemon,wrapper,ctl,...} options and generates
# ~/.config/heimdall/config.toml.  ham-* binaries are added to $PATH via
# home.packages.
#
# Usage in a flake-based home-manager config:
#
#   inputs.heimdall.url = "github:yourorg/heimdall-agent-manager";
#
#   home-manager.users.you = { imports = [ inputs.heimdall.homeModules.default ]; ... };
#
# Then set programs.heimdall options (see nix/README.md for a full example).

{ self }:
{ config, lib, pkgs, ... }:

let
  cfg = config.programs.heimdall;

  tomlFormat  = pkgs.formats.toml { };
  filterNulls = lib.filterAttrs (_: v: v != null);

  # ── Submodule types ────────────────────────────────────────────────────────

  bootstrapAgentsMdType = lib.types.submodule {
    options = {
      name = lib.mkOption {
        type        = lib.types.nullOr lib.types.str;
        default     = null;
        example     = "CLAUDE.md";
        description = "Filename for the AGENTS_MD bootstrap file.";
      };
      content = lib.mkOption {
        type        = lib.types.nullOr (lib.types.listOf lib.types.str);
        default     = null;
        example     = [ "IDENTITY" "GUIDANCE" "PROJECT" "MEMORY" ];
        description = "Sections to include in the AGENTS_MD file.";
      };
    };
  };

  bootstrapMemoryMdType = lib.types.submodule {
    options = {
      name = lib.mkOption {
        type        = lib.types.nullOr lib.types.str;
        default     = null;
        example     = "MEMORY.md";
        description = "Filename for the MEMORY_MD bootstrap file.";
      };
    };
  };

  bootstrapSkillsType = lib.types.submodule {
    options = {
      relativeDir = lib.mkOption {
        type        = lib.types.nullOr lib.types.str;
        default     = null;
        example     = "skills";
        description = "Subdirectory for skill files relative to the agent run dir.";
      };
      filename = lib.mkOption {
        type        = lib.types.nullOr lib.types.str;
        default     = null;
        example     = "SKILL.md";
        description = "Filename pattern used for each skill memory file.";
      };
    };
  };

  bootstrapType = lib.types.submodule {
    options = {
      agentsMd = lib.mkOption {
        type        = lib.types.nullOr bootstrapAgentsMdType;
        default     = null;
        description = "Settings for the AGENTS_MD (CLAUDE.md) bootstrap file.";
      };
      memoryMd = lib.mkOption {
        type        = lib.types.nullOr bootstrapMemoryMdType;
        default     = null;
        description = "Settings for the MEMORY_MD (MEMORY.md) bootstrap file.";
      };
      skills = lib.mkOption {
        type        = lib.types.nullOr bootstrapSkillsType;
        default     = null;
        description = "Settings for per-skill SKILLS bootstrap files.";
      };
    };
  };

  modelsType = lib.types.submodule {
    options = {
      flag = lib.mkOption {
        type        = lib.types.str;
        default     = "--model";
        description = "CLI flag used to pass the model name to the agent binary.";
      };
      cheap = lib.mkOption {
        type        = lib.types.nullOr lib.types.str;
        default     = null;
        description = "Model identifier for the 'cheap' tier.";
      };
      normal = lib.mkOption {
        type        = lib.types.nullOr lib.types.str;
        default     = null;
        description = "Model identifier for the 'normal' tier.";
      };
      smart = lib.mkOption {
        type        = lib.types.nullOr lib.types.str;
        default     = null;
        description = "Model identifier for the 'smart' tier.";
      };
    };
  };

  startupDetectionType = lib.types.submodule {
    options = {
      enabled = lib.mkOption {
        type        = lib.types.bool;
        default     = false;
        description = "Enable startup detection for this agent command.";
      };
      readyOnLaunch = lib.mkOption {
        type        = lib.types.nullOr lib.types.bool;
        default     = null;
        description = "Mark the agent as ready immediately on launch (skips probing).";
      };
      startupProbeSeconds = lib.mkOption {
        type        = lib.types.nullOr lib.types.int;
        default     = null;
        example     = 20;
        description = "How long (seconds) to probe the pane for startup patterns.";
      };
      captureIntervalMs = lib.mkOption {
        type        = lib.types.nullOr lib.types.int;
        default     = null;
        example     = 500;
        description = "Pane-capture polling interval in milliseconds during the startup probe.";
      };
      autoEnterPatterns = lib.mkOption {
        type        = lib.types.listOf lib.types.str;
        default     = [];
        description = "Pane patterns that trigger an automatic key+Enter during startup.";
      };
      autoEnterPreKeys = lib.mkOption {
        type        = lib.types.listOf lib.types.str;
        default     = [];
        description = "Keys to send before Enter for each autoEnterPatterns entry (empty string = bare Enter).";
      };
      blockedPatterns = lib.mkOption {
        type        = lib.types.listOf lib.types.str;
        default     = [];
        description = "Pane patterns that mark the agent as blocked during startup.";
      };
      startupUnknownIsBlocked = lib.mkOption {
        type        = lib.types.nullOr lib.types.bool;
        default     = null;
        description = "Treat unrecognized startup output as blocked.";
      };
      sanitizedReasonMapping = lib.mkOption {
        type        = lib.types.listOf lib.types.str;
        default     = [];
        description = "pattern=label pairs used to sanitize blocked reasons in the UI.";
      };
    };
  };

  agentCmdType = lib.types.submodule {
    options = {
      command = lib.mkOption {
        type        = lib.types.listOf lib.types.str;
        default     = [];
        example     = [ "claude" ];
        description = "Command and arguments for launching this agent.";
      };
      project = lib.mkOption {
        type        = lib.types.nullOr lib.types.str;
        default     = null;
        description = "Default project ID for agents started with this command.";
      };
      memoryTemplates = lib.mkOption {
        type        = lib.types.listOf lib.types.str;
        default     = [];
        description = "Memory template IDs/titles to inject into agent starter prompts.";
      };
      yoloFlags = lib.mkOption {
        type        = lib.types.listOf lib.types.str;
        default     = [];
        example     = [ "--dangerously-skip-permissions" ];
        description = "Extra flags appended when launching in non-interactive / permission-bypass mode.";
      };
      promptFlags = lib.mkOption {
        type        = lib.types.listOf lib.types.str;
        default     = [];
        description = "Flags that precede the starter prompt positional argument.";
      };
      starterPrompt = lib.mkOption {
        type        = lib.types.nullOr lib.types.str;
        default     = null;
        description = "Starter prompt template. {ctl_bin} and {token} are interpolated at launch time.";
      };
      bootstrap = lib.mkOption {
        type        = bootstrapType;
        default     = {};
        description = "Bootstrap file generation settings for this agent command.";
      };
      models = lib.mkOption {
        type        = modelsType;
        default     = {};
        description = "Model tier → name mappings for this agent command.";
      };
      startupDetection = lib.mkOption {
        type        = lib.types.nullOr startupDetectionType;
        default     = null;
        description = "Startup detection settings. Null omits the startup_detection section entirely.";
      };
    };
  };

  # ── TOML section builders ──────────────────────────────────────────────────

  mkBootstrap = b:
    lib.optionalAttrs (b.agentsMd != null) {
      AGENTS_MD = filterNulls { name = b.agentsMd.name; content = b.agentsMd.content; };
    }
    // lib.optionalAttrs (b.memoryMd != null) {
      MEMORY_MD = filterNulls { name = b.memoryMd.name; };
    }
    // lib.optionalAttrs (b.skills != null) {
      SKILLS = filterNulls { relative_dir = b.skills.relativeDir; filename = b.skills.filename; };
    };

  mkModels = m: filterNulls {
    flag   = m.flag;
    cheap  = m.cheap;
    normal = m.normal;
    smart  = m.smart;
  };

  mkStartupDetection = sd:
    { enabled = sd.enabled; }
    // lib.optionalAttrs (sd.readyOnLaunch != null)          { ready_on_launch            = sd.readyOnLaunch; }
    // lib.optionalAttrs (sd.startupProbeSeconds != null)     { startup_probe_seconds       = sd.startupProbeSeconds; }
    // lib.optionalAttrs (sd.captureIntervalMs != null)       { capture_interval_ms         = sd.captureIntervalMs; }
    // lib.optionalAttrs (sd.autoEnterPatterns != [])         { auto_enter_patterns         = sd.autoEnterPatterns; }
    // lib.optionalAttrs (sd.autoEnterPreKeys != [])          { auto_enter_pre_keys         = sd.autoEnterPreKeys; }
    // lib.optionalAttrs (sd.blockedPatterns != [])           { blocked_patterns            = sd.blockedPatterns; }
    // lib.optionalAttrs (sd.startupUnknownIsBlocked != null) { startup_unknown_is_blocked  = sd.startupUnknownIsBlocked; }
    // lib.optionalAttrs (sd.sanitizedReasonMapping != [])    { sanitized_reason_mapping    = sd.sanitizedReasonMapping; };

  mkAgentCmd = ac:
    { command = ac.command; yolo_flags = ac.yoloFlags; prompt_flags = ac.promptFlags; }
    // lib.optionalAttrs (ac.project != null)           { project          = ac.project; }
    // lib.optionalAttrs (ac.memoryTemplates != [])     { memory_templates = ac.memoryTemplates; }
    // lib.optionalAttrs (ac.starterPrompt != null)     { starter_prompt   = ac.starterPrompt; }
    // (let bs = mkBootstrap ac.bootstrap; in lib.optionalAttrs (bs != {}) { bootstrap = bs; })
    // { models    = mkModels ac.models; }
    // lib.optionalAttrs (ac.startupDetection != null)  { startup_detection = mkStartupDetection ac.startupDetection; };

  wrapperPkg = self.packages.${pkgs.stdenv.hostPlatform.system}.ham-wrapper;

  mkDaemon = d:
    { bind_host = d.bindHost; port = d.port; data_dir = d.dataDir;
      wrapper_bin = "${wrapperPkg}/bin/ham-wrapper"; }
    // lib.optionalAttrs (d.startupStaleAfterSeconds != null)           { startup_stale_after_seconds          = d.startupStaleAfterSeconds; }
    // lib.optionalAttrs (d.nudge.enabled != null)                      { nudge_enabled                        = d.nudge.enabled; }
    // lib.optionalAttrs (d.nudge.intervalSeconds != null)              { nudge_interval_seconds               = d.nudge.intervalSeconds; }
    // lib.optionalAttrs (d.nudge.readyAfterSeconds != null)            { nudge_ready_after_seconds            = d.nudge.readyAfterSeconds; }
    // lib.optionalAttrs (d.nudge.reviewAfterSeconds != null)           { nudge_review_after_seconds           = d.nudge.reviewAfterSeconds; }
    // lib.optionalAttrs (d.nudge.needImprovementsAfterSeconds != null) { nudge_need_improvements_after_seconds = d.nudge.needImprovementsAfterSeconds; }
    // lib.optionalAttrs (d.nudge.workingStaleAfterSeconds != null)     { nudge_working_stale_after_seconds    = d.nudge.workingStaleAfterSeconds; }
    // lib.optionalAttrs (d.nudge.cooldownSeconds != null)              { nudge_cooldown_seconds               = d.nudge.cooldownSeconds; }
    // lib.optionalAttrs (d.nudge.restartGraceSeconds != null)          { nudge_restart_grace_seconds          = d.nudge.restartGraceSeconds; }
    // lib.optionalAttrs (d.nudge.sendEscapePrefix != null)             { nudge_send_escape_prefix             = d.nudge.sendEscapePrefix; };

  mkWrapper = w:
    {
      daemon_url          = w.daemonUrl;
      credentials_path    = w.credentialsPath;
      agent_name          = w.agentName;
      default_agent       = w.defaultAgent;
      display_name        = w.displayName;
      requested_access_mode = w.requestedAccessMode;
      tmux_session        = w.tmuxSession;
      tmux_window_prefix  = w.tmuxWindowPrefix;
      project             = w.project;
      memory_templates    = w.memoryTemplates;
    }
    // lib.optionalAttrs (w.hamCtlBin != null)      { ham_ctl_bin   = w.hamCtlBin; }
    // lib.optionalAttrs (w.command != [])          { command       = w.command; }
    // lib.optionalAttrs (w.agentRunDir != null)    { agent_run_dir = w.agentRunDir; }
    // lib.optionalAttrs (w.agentCommands != {})    { "agent-cmd"   = lib.mapAttrs (_: mkAgentCmd) w.agentCommands; };

  configAttrs =
    lib.optionalAttrs cfg.daemon.enable  { daemon  = mkDaemon cfg.daemon; }
    // lib.optionalAttrs cfg.wrapper.enable { wrapper = mkWrapper cfg.wrapper; }
    // lib.optionalAttrs cfg.ctl.enable     { ctl     = { daemon_url = cfg.ctl.daemonUrl; }; };

  resolvePackage = name:
    self.packages.${pkgs.stdenv.hostPlatform.system}.${
      { daemon = "ham-daemon"; wrapper = "ham-wrapper"; ctl = "ham-ctl";
        test-agent = "ham-test-agent"; ui = "heimdall"; }.${name}
    };

  daemonPkg = self.packages.${pkgs.stdenv.hostPlatform.system}.ham-daemon;

in
{
  # ── Option declarations ────────────────────────────────────────────────────

  options.programs.heimdall = {
    enable = lib.mkEnableOption "Heimdall Agent Manager";

    packageNames = lib.mkOption {
      type    = lib.types.listOf (lib.types.enum [ "daemon" "wrapper" "ctl" "test-agent" "ui" ]);
      default = [ "daemon" "wrapper" "ctl" ];
      example = [ "daemon" "wrapper" "ctl" "ui" ];
      description = ''
        Heimdall packages to install and add to $PATH.
        "daemon"     → ham-daemon  (+ bc-odin-daemon symlink)
        "wrapper"    → ham-wrapper (+ bc-agent-wrapper symlink)
        "ctl"        → ham-ctl     (+ bc-odinctl symlink)
        "test-agent" → ham-test-agent
        "ui"         → heimdall Electron app
      '';
    };

    extraPackages = lib.mkOption {
      type        = lib.types.listOf lib.types.package;
      default     = [];
      description = "Additional packages to install alongside the Heimdall binaries.";
    };

    # ── [daemon] ──────────────────────────────────────────────────────────────

    daemon = {
      enable = lib.mkOption {
        type        = lib.types.bool;
        default     = true;
        description = "Generate the [daemon] section in config.toml.";
      };

      service = {
        enable = lib.mkOption {
          type        = lib.types.bool;
          default     = true;
          description = "Create a systemd user service (heimdall-daemon.service) that starts ham-daemon on login.";
        };
      };
      bindHost = lib.mkOption {
        type        = lib.types.str;
        default     = "127.0.0.1";
        description = "IP address the daemon HTTP server binds to.";
      };
      port = lib.mkOption {
        type        = lib.types.port;
        default     = 49322;
        description = "TCP port the daemon listens on.";
      };
      dataDir = lib.mkOption {
        type        = lib.types.str;
        default     = "~/.local/share/heimdall";
        description = "Directory for daemon-persisted data (tasks, memory, agent store, event log).";
      };
      startupStaleAfterSeconds = lib.mkOption {
        type        = lib.types.nullOr lib.types.int;
        default     = null;
        example     = 120;
        description = "Agents stuck in 'starting' longer than this many seconds are marked startup_failed. Null = use daemon built-in default.";
      };

      nudge = {
        enabled = lib.mkOption {
          type        = lib.types.nullOr lib.types.bool;
          default     = null;
          description = "Enable scheduled task nudges. Null omits the key (daemon default: false).";
        };
        intervalSeconds = lib.mkOption {
          type        = lib.types.nullOr lib.types.int;
          default     = null;
          example     = 60;
          description = "Seconds between nudge scans.";
        };
        readyAfterSeconds = lib.mkOption {
          type    = lib.types.nullOr lib.types.int;
          default = null;
        };
        reviewAfterSeconds = lib.mkOption {
          type    = lib.types.nullOr lib.types.int;
          default = null;
        };
        needImprovementsAfterSeconds = lib.mkOption {
          type    = lib.types.nullOr lib.types.int;
          default = null;
        };
        workingStaleAfterSeconds = lib.mkOption {
          type    = lib.types.nullOr lib.types.int;
          default = null;
        };
        cooldownSeconds = lib.mkOption {
          type    = lib.types.nullOr lib.types.int;
          default = null;
        };
        restartGraceSeconds = lib.mkOption {
          type    = lib.types.nullOr lib.types.int;
          default = null;
        };
        sendEscapePrefix = lib.mkOption {
          type    = lib.types.nullOr lib.types.bool;
          default = null;
        };
      };
    };

    # ── [wrapper] ─────────────────────────────────────────────────────────────

    wrapper = {
      enable = lib.mkOption {
        type        = lib.types.bool;
        default     = true;
        description = "Generate the [wrapper] section in config.toml.";
      };
      daemonUrl = lib.mkOption {
        type        = lib.types.str;
        default     = "http://127.0.0.1:49322";
        description = "Daemon URL that ham-wrapper connects to.";
      };
      credentialsPath = lib.mkOption {
        type        = lib.types.str;
        default     = "~/.local/share/heimdall/wrapper-credentials.json";
        description = "Path for wrapper credential/token storage.";
      };
      agentName = lib.mkOption {
        type        = lib.types.str;
        default     = "pi";
        description = "Default agent name; selects [wrapper.agent-cmd.<agentName>].";
      };
      defaultAgent = lib.mkOption {
        type        = lib.types.str;
        default     = "pi";
        description = "Default agent command alias (default_agent in TOML).";
      };
      displayName = lib.mkOption {
        type        = lib.types.str;
        default     = "{instance}";
        description = "Display name template. {instance} is replaced with the agent instance ID.";
      };
      requestedAccessMode = lib.mkOption {
        type        = lib.types.enum [ "main" "review" "readonly" ];
        default     = "main";
        description = "Default access mode requested for new agent instances.";
      };
      command = lib.mkOption {
        type        = lib.types.listOf lib.types.str;
        default     = [];
        description = "Top-level default launch command (overridden by agentCommands.<name>.command).";
      };
      tmuxSession = lib.mkOption {
        type        = lib.types.str;
        default     = "ham-agents";
        description = "tmux session that agent windows are created in.";
      };
      tmuxWindowPrefix = lib.mkOption {
        type        = lib.types.str;
        default     = "agent";
        description = "Prefix for tmux window names (e.g. 'agent' → 'agent-<instance-id>').";
      };
      agentRunDir = lib.mkOption {
        type        = lib.types.nullOr lib.types.str;
        default     = "~/.local/share/heimdall/agent-runs";
        description = "Root for agent run dirs: <agentRunDir>/<project-slug>/<instance-id>. Null disables managed run dirs.";
      };
      project = lib.mkOption {
        type        = lib.types.str;
        default     = "default";
        description = "Default project ID for new agent instances.";
      };
      memoryTemplates = lib.mkOption {
        type        = lib.types.listOf lib.types.str;
        default     = [];
        description = "Memory template IDs/titles injected into agent starter prompts (global default).";
      };

      hamCtlBin = lib.mkOption {
        type        = lib.types.nullOr lib.types.str;
        default     = "${self.packages.${pkgs.stdenv.hostPlatform.system}.ham-ctl}/bin/ham-ctl";
        defaultText = lib.literalExpression ''"''${pkgs.ham-ctl}/bin/ham-ctl"'';
        description = ''
          Absolute path to the ham-ctl binary written into agent bootstrap files.
          Defaults to the ham-ctl binary from the Nix store so agents do not need
          ham-ctl on $PATH. Set to null to omit the key and fall back to the
          wrapper binary's built-in default.
        '';
      };

      agentCommands = lib.mkOption {
        type        = lib.types.attrsOf agentCmdType;
        default     = {};
        example     = lib.literalExpression ''
          {
            claude = {
              command        = [ "claude" ];
              yoloFlags      = [ "--dangerously-skip-permissions" ];
              starterPrompt  = "First, run: {ctl_bin} --token {token} start-success. Then read your bootstrap file.";
              bootstrap = {
                agentsMd = { name = "CLAUDE.md"; content = [ "IDENTITY" "GUIDANCE" "PROJECT" "MEMORY" ]; };
                memoryMd = { name = "MEMORY.md"; };
                skills   = { relativeDir = "skills"; filename = "SKILL.md"; };
              };
              models = { flag = "--model"; cheap = "haiku"; normal = "sonnet"; smart = "opus"; };
              startupDetection = {
                enabled             = true;
                startupProbeSeconds = 20;
                captureIntervalMs   = 500;
                autoEnterPatterns   = [ "Yes, I trust this folder" ];
                autoEnterPreKeys    = [ "" ];
                blockedPatterns     = [ "Enter auto mode" ];
              };
            };
          }
        '';
        description = ''
          Per-agent-command launch customization.
          Each key becomes a [wrapper.agent-cmd.<key>] TOML section.
        '';
      };
    };

    # ── [ctl] ─────────────────────────────────────────────────────────────────

    ctl = {
      enable = lib.mkOption {
        type        = lib.types.bool;
        default     = true;
        description = "Generate the [ctl] section in config.toml.";
      };
      daemonUrl = lib.mkOption {
        type        = lib.types.str;
        default     = "http://127.0.0.1:49322";
        description = "Daemon URL that ham-ctl connects to.";
      };
    };
  };

  # ── Activation ────────────────────────────────────────────────────────────

  config = lib.mkIf cfg.enable {
    home.packages =
      (map resolvePackage cfg.packageNames)
      ++ cfg.extraPackages;

    xdg.configFile."heimdall/config.toml".source =
      tomlFormat.generate "heimdall-config.toml" configAttrs;

    systemd.user.services.heimdall-daemon = lib.mkIf (cfg.daemon.enable && cfg.daemon.service.enable) {
      Unit = {
        Description = "Heimdall Agent Manager Daemon";
        After       = [ "network.target" ];
      };
      Service = {
        ExecStart = "${daemonPkg}/bin/ham-daemon";
        Restart    = "on-failure";
        RestartSec = "5s";
      };
      Install.WantedBy = [ "default.target" ];
    };
  };
}
