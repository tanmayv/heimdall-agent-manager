{ pkgs, nixpkgs, module }:
let
  evaluate = settings: (nixpkgs.lib.nixosSystem {
    system = pkgs.stdenv.hostPlatform.system;
    modules = [
      module
      {
        system.stateVersion = "26.05";
        boot.isContainer = true;
        fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
        services.heimdall-nats = settings;
      }
    ];
  }).config;
  disabled = evaluate {};
  enabled = evaluate { enable = true; authFile = "/run/secrets/nats-auth.conf"; };
  custom = evaluate {
    enable = true;
    authFile = "/run/secrets/custom-auth.conf";
    port = 4422;
    listenAddress = "::1";
  };
  missingAuth = evaluate { enable = true; };
  storeAuth = evaluate { enable = true; authFile = "/nix/store/not-a-secret"; };
  unit = enabled.systemd.services.heimdall-nats;
  # Regex captures discard string context; retain the generated configuration's
  # derivation dependency so it is available inside the build sandbox.
  configPath = service: builtins.appendContext
    (builtins.head (builtins.match ".*cat ([^ ]+) .*" service.script))
    (builtins.getContext service.script);
  valid = config: builtins.all (a: a.assertion) config.assertions;
in
assert !(disabled.systemd.services ? heimdall-nats);
assert valid disabled;
assert valid enabled;
assert valid custom;
assert !(valid missingAuth);
assert !(valid storeAuth);
assert unit.serviceConfig.StateDirectory == "heimdall-nats";
assert unit.serviceConfig.DynamicUser;
assert unit.serviceConfig.LoadCredential == [ "auth.conf:/run/secrets/nats-auth.conf" ];
assert builtins.elem "multi-user.target" unit.wantedBy;
# Force the actual unit generation as well as option values.
assert builtins.isString enabled.systemd.units."heimdall-nats.service".text;
pkgs.runCommand "check-heimdall-nats-module" {
  nativeBuildInputs = [ pkgs.nats-server ];
} ''
  # Validate the generated config plus the runtime credential fragment, as
  # concatenated by the unit script. No real secrets enter the store.
  cat > auth.conf <<'AUTH'
  authorization { users: [ { user: "heimdall", password: "test-only" } ] }
  AUTH
  cat ${configPath unit} auth.conf > server.conf
  nats-server -t --config "$PWD/server.conf"
  cat ${configPath custom.systemd.services.heimdall-nats} auth.conf > custom.conf
  nats-server -t --config "$PWD/custom.conf"
  # An invalid configuration must fail, proving the parser actually ran.
  printf 'port: "not-a-port"\n' > invalid.conf
  if nats-server -t --config "$PWD/invalid.conf"; then
    echo "invalid NATS configuration unexpectedly accepted" >&2
    exit 1
  fi
  grep -F 'host: "127.0.0.1"' server.conf
  grep -F 'port: 4222' server.conf
  grep -F 'jetstream {' server.conf
  grep -F 'store_dir: "/var/lib/heimdall-nats"' server.conf
  grep -F 'host: "::1"' custom.conf
  grep -F 'port: 4422' custom.conf
  touch $out
''
