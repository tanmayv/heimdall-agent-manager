# Heimdall AI Manager – Home Manager module
#
# Exposes programs.heimdall.{hub,bridge,wrapper,ctl,...} options and generates
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
      useRandomDir = lib.mkOption {
        type        = lib.types.nullOr lib.types.bool;
        default     = null;
        description = "Override wrapper.useRandomDir for this agent command. When true, run dirs use a random basename under agentRunDir/project.";
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
        description = "Flags that precede the starter prompt positional argument when promptDelivery is flag-injection.";
      };
      starterPrompt = lib.mkOption {
        type        = lib.types.nullOr lib.types.str;
        default     = null;
        description = "Starter prompt template. {ctl_bin} and {token} are interpolated at launch time.";
      };
      promptDelivery = lib.mkOption {
        type        = lib.types.enum [ "flag-injection" "tmux" "none" ];
        default     = "flag-injection";
        description = "How to deliver the starter prompt: flag-injection appends promptFlags and the prompt to argv, tmux injects into the pane after launch, none disables prompt delivery.";
      };
      promptTmuxDelayMs = lib.mkOption {
        type        = lib.types.nullOr lib.types.int;
        default     = null;
        example     = 1500;
        description = "Delay before tmux prompt injection when promptDelivery is tmux. Null uses the wrapper default.";
      };
      promptTmuxEnter = lib.mkOption {
        type        = lib.types.nullOr lib.types.bool;
        default     = null;
        description = "Whether tmux prompt injection sends Enter after typing the prompt. Null uses the wrapper default.";
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
    // lib.optionalAttrs (sd.startupProbeSeconds != null)     { startup_probe_seconds       = sd.startupProbeSeconds; }
    // lib.optionalAttrs (sd.captureIntervalMs != null)       { capture_interval_ms         = sd.captureIntervalMs; }
    // lib.optionalAttrs (sd.autoEnterPatterns != [])         { auto_enter_patterns         = sd.autoEnterPatterns; }
    // lib.optionalAttrs (sd.autoEnterPreKeys != [])          { auto_enter_pre_keys         = sd.autoEnterPreKeys; }
    // lib.optionalAttrs (sd.blockedPatterns != [])           { blocked_patterns            = sd.blockedPatterns; }
    // lib.optionalAttrs (sd.startupUnknownIsBlocked != null) { startup_unknown_is_blocked  = sd.startupUnknownIsBlocked; }
    // lib.optionalAttrs (sd.sanitizedReasonMapping != [])    { sanitized_reason_mapping    = sd.sanitizedReasonMapping; };

  mkAgentCmd = ac:
    { command = ac.command; yolo_flags = ac.yoloFlags; prompt_flags = ac.promptFlags; prompt_delivery = ac.promptDelivery; }
    // lib.optionalAttrs (ac.project != null)             { project              = ac.project; }
    // lib.optionalAttrs (ac.useRandomDir != null)        { use_random_dir       = ac.useRandomDir; }
    // lib.optionalAttrs (ac.memoryTemplates != [])       { memory_templates     = ac.memoryTemplates; }
    // lib.optionalAttrs (ac.starterPrompt != null)       { starter_prompt       = ac.starterPrompt; }
    // lib.optionalAttrs (ac.promptTmuxDelayMs != null)   { prompt_tmux_delay_ms = ac.promptTmuxDelayMs; }
    // lib.optionalAttrs (ac.promptTmuxEnter != null)     { prompt_tmux_enter    = ac.promptTmuxEnter; }
    // (let bs = mkBootstrap ac.bootstrap; in lib.optionalAttrs (bs != {}) { bootstrap = bs; })
    // { models    = mkModels ac.models; }
    // lib.optionalAttrs (ac.startupDetection != null)  { startup_detection = mkStartupDetection ac.startupDetection; };

  system = pkgs.stdenv.hostPlatform.system;
  wrapperPkg = self.packages.${system}.ham-wrapper;
  bridgePkg = self.packages.${system}.ham-bridge;
  ctlPkg = self.packages.${system}.ham-ctl;
  ptyHostPkg = self.packages.${system}.ham-pty-host;

  mkGuideAgent = g: {
    enabled            = g.enabled;
    autostart          = g.autostart;
    restart_if_stopped = g.restartIfStopped;
    agent_instance_id  = g.agentInstanceId;
    template_id        = g.templateId;
    provider_profile   = g.providerProfile;
    model_tier         = g.modelTier;
  };

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
    // lib.optionalAttrs (w.command != [])          { command        = w.command; }
    // lib.optionalAttrs (w.agentRunDir != null)    { agent_run_dir  = w.agentRunDir; }
    // lib.optionalAttrs (w.useRandomDir != null)   { use_random_dir = w.useRandomDir; }
    // lib.optionalAttrs (w.agentCommands != {})    { "agent-cmd"   = lib.mapAttrs (_: mkAgentCmd) w.agentCommands; };

  configAttrs =
    { guide_agent = mkGuideAgent cfg.guideAgent; }
    // lib.optionalAttrs cfg.wrapper.enable { wrapper = mkWrapper cfg.wrapper; }
    // lib.optionalAttrs cfg.bridge.enable  { bridge  = { pty_host_runtime = cfg.bridge.ptyHostRuntime; }; }
    // lib.optionalAttrs cfg.ctl.enable     { ctl     = { daemon_url = cfg.ctl.daemonUrl; }; };

  resolvePackage = name:
    let
      basePkg = self.packages.${system}.${
        { hub = "ham-hub"; bridge = "ham-bridge"; wrapper = "ham-wrapper"; ctl = "ham-ctl";
          test-agent = "ham-test-agent"; ui = "heimdall"; pty-host = "ham-pty-host"; }.${name}
      };
    in
    basePkg;

  bridgeInstanceType = lib.types.submodule ({ name, ... }: {
    options = {
      enable = lib.mkOption { type = lib.types.bool; default = true; description = "Enable this named ham-bridge service."; };
      ptyHostRuntime = lib.mkOption { type = lib.types.bool; default = true; description = "Run agents directly via ham-pty-host (replacing wrapper/tmux)."; };
      hubUrl = lib.mkOption { type = lib.types.str; default = "http://127.0.0.1:8081"; example = "https://hub.mundus.in"; description = "Hub base URL used by ham-bridge (--hub)."; };
      tokenFile = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; description = "Path to a file containing this bridge's enrolled hbr_ token."; };
      bindHost = lib.mkOption { type = lib.types.str; default = "127.0.0.1"; description = "Loopback host for this bridge HTTP server."; };
      port = lib.mkOption { type = lib.types.port; default = 49323; description = "Loopback TCP port for this bridge HTTP server. Must be unique per local bridge."; };
      localEndpointPort = lib.mkOption { type = lib.types.nullOr lib.types.port; default = null; description = "Wrapper-local endpoint TCP port. Null defaults to port + 1, so wrappers launched by this bridge heartbeat to the matching bridge."; };
      localRunDir = lib.mkOption { type = lib.types.str; default = "/tmp/heimdall-bridge-local-${name}"; description = "Runtime directory for this bridge's local endpoint socket/files. Must be unique per local bridge."; };
      logDir = lib.mkOption { type = lib.types.str; default = "/tmp/heimdall-logs"; description = "Directory used for launchd stdout/stderr logs on macOS."; };
      extraArgs = lib.mkOption { type = lib.types.listOf lib.types.str; default = []; description = "Additional arguments appended to this ham-bridge service command."; };
      environment = lib.mkOption { type = lib.types.attrsOf lib.types.str; default = {}; description = "Extra environment variables for this bridge service."; };
      service = {
        enable = lib.mkOption { type = lib.types.bool; default = true; description = "Create a systemd user service on Linux or launchd agent on macOS."; };
        startOnBoot = lib.mkOption { type = lib.types.bool; default = true; description = "Start this bridge service on user login."; };
      };
    };
  });

  bridgePrimaryConfig = {
    enable = cfg.bridge.enable;
    ptyHostRuntime = cfg.bridge.ptyHostRuntime;
    hubUrl = cfg.bridge.hubUrl;
    tokenFile = cfg.bridge.tokenFile;
    bindHost = cfg.bridge.bindHost;
    port = cfg.bridge.port;
    localEndpointPort = cfg.bridge.localEndpointPort;
    localRunDir = cfg.bridge.localRunDir;
    logDir = cfg.bridge.logDir;
    extraArgs = cfg.bridge.extraArgs;
    environment = cfg.bridge.environment;
    service = cfg.bridge.service;
  };

  bridgeServiceEntries =
    (lib.optional cfg.bridge.enable { name = "default"; config = bridgePrimaryConfig; serviceName = "heimdall-bridge"; label = "works.earendil.heimdall-bridge"; })
    ++ (lib.mapAttrsToList (name: bridgeCfg: { name = name; config = bridgeCfg; serviceName = "heimdall-bridge-${name}"; label = "works.earendil.heimdall-bridge.${name}"; }) cfg.bridges);

  anyBridgeEnabled = cfg.bridge.enable || lib.any (bridgeCfg: bridgeCfg.enable) (lib.attrValues cfg.bridges);
  enabledBridgeEntries = lib.filter (entry: entry.config.enable) bridgeServiceEntries;
  enabledBridgeServiceEntries = lib.filter (entry: entry.config.enable && entry.config.service.enable && entry.config.service.startOnBoot) bridgeServiceEntries;

  bridgeActualLocalEndpointPort = bridgeCfg:
    if bridgeCfg.localEndpointPort != null then bridgeCfg.localEndpointPort else bridgeCfg.port + 1;

  bridgeCommandArgsFor = bridgeCfg: [
    "${bridgePkg}/bin/ham-bridge"
    "--hub" bridgeCfg.hubUrl
    "--bind-host" bridgeCfg.bindHost
    "--port" (toString bridgeCfg.port)
    "--local-endpoint-port" (toString (bridgeActualLocalEndpointPort bridgeCfg))
    "--local-run-dir" bridgeCfg.localRunDir
  ]
  ++ lib.optionals (bridgeCfg.tokenFile != null) [ "--bridge-token-file" bridgeCfg.tokenFile ]
  ++ bridgeCfg.extraArgs;

  bridgeDefaultPath = lib.concatStringsSep ":" [
    "${config.home.profileDirectory}/bin"
    "${config.home.homeDirectory}/.pi/agent/bin"
    "${config.home.homeDirectory}/.local/bin"
    "${ptyHostPkg}/bin"
    (lib.makeBinPath [ pkgs.tmux pkgs.bashInteractive pkgs.coreutils ])
    "/run/current-system/sw/bin"
    "/etc/profiles/per-user/${config.home.username}/bin"
    "/opt/homebrew/bin"
    "/usr/local/bin"
    "/usr/bin"
    "/bin"
  ];

  bridgeEnvironmentFor = bridgeCfg: {
    HEIMDALL_HAM_PTY_HOST_BIN = "${ptyHostPkg}/bin/ham-pty-host";
    HEIMDALL_BRIDGE_PTY_HOST = if bridgeCfg.ptyHostRuntime then "true" else "false";
    HEIMDALL_HAM_WRAPPER_BIN = "${wrapperPkg}/bin/ham-wrapper";
    HEIMDALL_HAM_CTL_BIN = "${ctlPkg}/bin/ham-ctl";
    PATH = bridgeDefaultPath;
    SHELL = "${pkgs.bashInteractive}/bin/bash";
  } // bridgeCfg.environment;

  bridgeServicePorts = map (entry: entry.config.port) enabledBridgeServiceEntries;
  bridgeLocalEndpointPorts = map (entry: bridgeActualLocalEndpointPort entry.config) enabledBridgeServiceEntries;
  bridgeLocalRunDirs = map (entry: entry.config.localRunDir) enabledBridgeServiceEntries;

in
{
  # ── Option declarations ────────────────────────────────────────────────────

  options.programs.heimdall = {
    enable = lib.mkEnableOption "Heimdall Agent Manager";

    packageNames = lib.mkOption {
      type    = lib.types.listOf (lib.types.enum [ "hub" "bridge" "wrapper" "ctl" "test-agent" "ui" "pty-host" ]);
      default = [ "hub" "bridge" "wrapper" "ctl" "pty-host" ];
      example = [ "hub" "bridge" "wrapper" "ctl" "pty-host" "ui" ];
      description = ''
        Heimdall packages to install and add to $PATH.
        "hub"        → ham-hub
        "bridge"     → ham-bridge
        "wrapper"    → ham-wrapper (+ bc-agent-wrapper symlink)
        "ctl"        → ham-ctl     (+ bc-odinctl symlink)
        "test-agent" → ham-test-agent
        "pty-host"   → ham-pty-host
        "ui"         → heimdall Electron app
      '';
    };

    extraPackages = lib.mkOption {
      type        = lib.types.listOf lib.types.package;
      default     = [];
      description = "Additional packages to install alongside the Heimdall binaries.";
    };

    # ── [guide_agent] ────────────────────────────────────────────────────────

    guideAgent = {
      enabled = lib.mkOption {
        type        = lib.types.bool;
        default     = false;
        description = "Whether the guide agent is enabled (`[guide_agent].enabled`).";
      };
      autostart = lib.mkOption {
        type        = lib.types.bool;
        default     = false;
        description = "Whether the daemon should start the guide agent during daemon startup (`[guide_agent].autostart`).";
      };
      restartIfStopped = lib.mkOption {
        type        = lib.types.bool;
        default     = false;
        description = "Guide-agent config parity for `[guide_agent].restart_if_stopped`. The current runtime stores and reports this value, but no restart loop behavior was found in the daemon yet.";
      };
      agentInstanceId = lib.mkOption {
        type        = lib.types.str;
        default     = "guide@heimdall";
        description = "Guide singleton agent instance ID (`[guide_agent].agent_instance_id`). Non-default values are accepted by config parsing, but the current daemon launch path only starts the default singleton and otherwise reports `invalid_singleton_id`.";
      };
      templateId = lib.mkOption {
        type        = lib.types.str;
        default     = "guide";
        description = "Guide template ID (`[guide_agent].template_id`).";
      };
      providerProfile = lib.mkOption {
        type        = lib.types.str;
        default     = "pi";
        description = "Provider profile for the guide agent (`[guide_agent].provider_profile`). Set to an empty string to fall back to `[daemon].default_agent_provider_profile`, then `pi`.";
      };
      modelTier = lib.mkOption {
        type        = lib.types.enum [ "cheap" "normal" "smart" ];
        default     = "smart";
        description = "Model tier for the guide agent (`[guide_agent].model_tier`).";
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
        description = "Root for agent run dirs. Default basename is <instance-id>-<timestamp>; with useRandomDir it is a random slug.";
      };
      useRandomDir = lib.mkOption {
        type        = lib.types.nullOr lib.types.bool;
        default     = null;
        description = "When true, ham-wrapper creates <agentRunDir>/<project>/<random-slug> instead of including the agent instance ID in the run-dir basename.";
      };
      project = lib.mkOption {
        type        = lib.types.str;
        default     = "";
        description = "Default project ID for new agent instances. Empty means no project association.";
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

    # ── Bridge service ───────────────────────────────────────────────────────

    bridge = {
      enable = lib.mkOption {
        type        = lib.types.bool;
        default     = false;
        description = "Install/configure the ham-bridge user service.";
      };
      ptyHostRuntime = lib.mkOption {
        type        = lib.types.bool;
        default     = true;
        description = "Run agents directly via ham-pty-host (replacing wrapper/tmux).";
      };
      hubUrl = lib.mkOption {
        type        = lib.types.str;
        default     = "http://127.0.0.1:8081";
        example     = "https://heimdall.mundus.in";
        description = "Hub base URL used by ham-bridge (--hub).";
      };
      tokenFile = lib.mkOption {
        type        = lib.types.nullOr lib.types.str;
        default     = null;
        defaultText = lib.literalExpression "null";
        description = ''
          Path to a file containing the enrolled bridge token (hbr_...). The
          token file is read by ham-bridge via --bridge-token-file and is not
          generated into the Nix store. Create it with mode 0600, or enroll with
          `ham-bridge enroll --hub <hub> --enrollment-token <token> --bridge-token-file <path>`.
        '';
      };
      bindHost = lib.mkOption {
        type        = lib.types.str;
        default     = "127.0.0.1";
        description = "Loopback host for the bridge HTTP server.";
      };
      port = lib.mkOption {
        type        = lib.types.port;
        default     = 49323;
        description = "Loopback TCP port for the bridge HTTP server.";
      };
      localEndpointPort = lib.mkOption {
        type        = lib.types.nullOr lib.types.port;
        default     = null;
        description = "Optional TCP port for the wrapper-local bridge endpoint. Null defaults to bridge.port + 1 so wrappers launched by this bridge heartbeat to the matching bridge.";
      };
      localRunDir = lib.mkOption {
        type        = lib.types.str;
        default     = "/tmp/heimdall-bridge-local";
        description = "Runtime directory for the bridge local endpoint socket/files.";
      };
      logDir = lib.mkOption {
        type        = lib.types.str;
        default     = "/tmp/heimdall-logs";
        defaultText = lib.literalExpression ''"/tmp/heimdall-logs"'';
        description = "Directory used for launchd stdout/stderr logs on macOS.";
      };
      extraArgs = lib.mkOption {
        type        = lib.types.listOf lib.types.str;
        default     = [];
        description = "Additional arguments appended to the ham-bridge service command.";
      };
      environment = lib.mkOption {
        type        = lib.types.attrsOf lib.types.str;
        default     = {};
        description = "Extra environment variables for the bridge service.";
      };
      service = {
        enable = lib.mkOption {
          type        = lib.types.bool;
          default     = true;
          description = "Create a systemd user service on Linux or launchd agent on macOS.";
        };
        startOnBoot = lib.mkOption {
          type        = lib.types.bool;
          default     = true;
          description = "Start the bridge service on user login.";
        };
      };
    };

    bridges = lib.mkOption {
      type        = lib.types.attrsOf bridgeInstanceType;
      default     = {};
      example     = lib.literalExpression ''
        {
          work = { hubUrl = "https://hub.mundus.in"; port = 49333; tokenFile = "~/.config/heimdall/work-bridge-token"; };
          personal = { hubUrl = "https://other-hub.example"; port = 49343; tokenFile = "~/.config/heimdall/personal-bridge-token"; };
        }
      '';
      description = ''
        Additional named ham-bridge services. Each named bridge gets its own
        systemd user service or launchd agent and must use unique bridge/local
        endpoint ports and localRunDir. Wrappers launched by a given bridge are
        started with that bridge's exact --bridge-endpoint, so their liveness and
        notification subscription calls return to the correct bridge.
      '';
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

  config = lib.mkIf cfg.enable (
    {
      assertions = [
        {
          assertion = (lib.length bridgeServicePorts) == (lib.length (lib.unique bridgeServicePorts));
          message = "programs.heimdall bridge services must use unique bridge.port values.";
        }
        {
          assertion = (lib.length bridgeLocalEndpointPorts) == (lib.length (lib.unique bridgeLocalEndpointPorts));
          message = "programs.heimdall bridge services must use unique localEndpointPort values.";
        }
        {
          assertion = (lib.length bridgeLocalRunDirs) == (lib.length (lib.unique bridgeLocalRunDirs));
          message = "programs.heimdall bridge services must use unique localRunDir values.";
        }
      ];

      home.packages =
        (map resolvePackage cfg.packageNames)
        ++ lib.optional anyBridgeEnabled bridgePkg
        ++ lib.optional anyBridgeEnabled ptyHostPkg
        ++ lib.optional anyBridgeEnabled wrapperPkg
        ++ lib.optional anyBridgeEnabled ctlPkg
        ++ lib.optional anyBridgeEnabled pkgs.tmux
        ++ cfg.extraPackages;

      xdg.configFile."heimdall/config.toml".source =
        tomlFormat.generate "heimdall-config.toml" configAttrs;

      home.activation.heimdallBridgeDirs = lib.mkIf anyBridgeEnabled (lib.hm.dag.entryAfter [ "writeBoundary" ] (lib.concatMapStringsSep "\n" (entry: ''
        $DRY_RUN_CMD mkdir -p ${lib.escapeShellArg entry.config.logDir}
        ${lib.optionalString (entry.config.tokenFile != null) "$DRY_RUN_CMD mkdir -p $(dirname ${lib.escapeShellArg entry.config.tokenFile})"}
        $DRY_RUN_CMD mkdir -p ${lib.escapeShellArg entry.config.localRunDir}
      '') enabledBridgeEntries));

      # macOS: home-manager's built-in setupLaunchAgents does an unreliable
      # `launchctl bootout <plist-path>` that frequently fails with
      # "Unrecognized target specifier", leaving the OLD bridge binary running
      # even though the plist now points at the new store path. Reload each
      # enabled bridge agent ourselves — AFTER the plists are written — using the
      # service-target form (gui/<uid>/<label>), waiting for the old service to
      # fully unload, then bootstrap + kickstart so the NEW store path is running.
      # (Mirrors the proven restart pattern used for agent-communicator-web.)
      home.activation.heimdallBridgeReload = lib.mkIf (anyBridgeEnabled && pkgs.stdenv.isDarwin) (
        lib.hm.dag.entryAfter [ "setupLaunchAgents" ] (
          lib.concatMapStringsSep "\n" (entry: ''
            label="${entry.label}"
            domain="gui/$(id -u)"
            service="$domain/$label"
            plist="$HOME/Library/LaunchAgents/$label.plist"
            $VERBOSE_ECHO "heimdall: force-restarting bridge launchd agent $label"
            if [ -f "$plist" ]; then
              # Unload the running (old) service. bootout by target is the reliable
              # spelling; ignore failure (may not be loaded yet).
              $DRY_RUN_CMD /bin/launchctl bootout "$service" >/dev/null 2>&1 || true
              # Wait for launchd to release the label + tear down the old pid.
              for _ in 1 2 3 4 5; do
                if ! /bin/launchctl print "$service" >/dev/null 2>&1; then break; fi
                $DRY_RUN_CMD /bin/sleep 1
              done
              # Load the freshly-written plist (new store path).
              if ! $DRY_RUN_CMD /bin/launchctl bootstrap "$domain" "$plist" >/dev/null 2>&1; then
                $VERBOSE_ECHO "heimdall: bootstrap failed for $service; falling back to kickstart"
              fi
              # Always kickstart to guarantee the new binary is actually running.
              if ! $DRY_RUN_CMD /bin/launchctl kickstart -k "$service" >/dev/null 2>&1; then
                $VERBOSE_ECHO "heimdall: kickstart failed for $service"
              fi
            else
              $VERBOSE_ECHO "heimdall: LaunchAgent plist not found: $plist"
            fi
          '') enabledBridgeServiceEntries
        )
      );

      systemd.user.services = {
      } // builtins.listToAttrs (map (entry: {
        name = entry.serviceName;
        value = {
          Unit = {
            Description = "Heimdall Bridge (${entry.name})";
            After       = [ "network-online.target" ];
          };
          Service = {
            ExecStart   = lib.escapeShellArgs (bridgeCommandArgsFor entry.config);
            Environment = lib.mapAttrsToList (name: value: "${name}=${value}") (bridgeEnvironmentFor entry.config);
            Restart     = "on-failure";
            RestartSec  = "5s";
            KillMode    = "process";
          };
          Install.WantedBy = [ "default.target" ];
        };
      }) enabledBridgeServiceEntries);

      launchd.agents = builtins.listToAttrs (map (entry: {
        name = entry.serviceName;
        value = {
          enable = true;
          config = {
            Label = entry.label;
            ProgramArguments = bridgeCommandArgsFor entry.config;
            EnvironmentVariables = bridgeEnvironmentFor entry.config;
            RunAtLoad = true;
            KeepAlive = { Crashed = true; SuccessfulExit = false; };
            StandardOutPath = "${entry.config.logDir}/${entry.serviceName}.out.log";
            StandardErrorPath = "${entry.config.logDir}/${entry.serviceName}.err.log";
          };
        };
      }) enabledBridgeServiceEntries);
    }
  );
}
