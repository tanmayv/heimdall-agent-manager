{ config, lib, pkgs, ... }:
let
  cfg = config.services.heimdall-nats;
  serverConfig = pkgs.writeText "heimdall-nats.conf" ''
    host: ${builtins.toJSON cfg.listenAddress}
    port: ${toString cfg.port}
    jetstream {
      store_dir: "/var/lib/heimdall-nats"
    }
  '';
in {
  options.services.heimdall-nats = {
    enable = lib.mkEnableOption "a local JetStream server for the Heimdall hub";
    package = lib.mkPackageOption pkgs "nats-server" {};
    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Client listen address. Keep loopback unless remote access is secured separately.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 4222;
      description = "NATS client port.";
    };
    authFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/run/secrets/heimdall-nats-auth.conf";
      description = ''
        Absolute runtime path to a NATS configuration fragment containing an
        authorization block (for example, a users list). Required when enabled.
        Use a string path outside the Nix store. systemd copies this file as a
        credential, so the source can remain root-readable.
        This is server configuration, not a client JWT/NKey .creds file.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = cfg.authFile != null && lib.hasPrefix "/" cfg.authFile
        && !(lib.hasPrefix "/nix/store/" cfg.authFile);
      message = "services.heimdall-nats.authFile must be an absolute runtime path outside the Nix store.";
    }];
    systemd.services.heimdall-nats = {
      description = "Heimdall NATS JetStream";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig = {
        DynamicUser = true;
        StateDirectory = "heimdall-nats";
        StateDirectoryMode = "0700";
        RuntimeDirectory = "heimdall-nats";
        RuntimeDirectoryMode = "0700";
        LoadCredential = lib.optional (cfg.authFile != null) "auth.conf:${cfg.authFile}";
        Restart = "on-failure";
        RestartSec = "5s";
        UMask = "0077";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
      };
      script = ''
        cat ${serverConfig} "$CREDENTIALS_DIRECTORY/auth.conf" > /run/heimdall-nats/server.conf
        exec ${lib.getExe cfg.package} --config /run/heimdall-nats/server.conf
      '';
    };
  };
}
