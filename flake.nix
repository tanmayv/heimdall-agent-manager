{
  description = "Heimdall Agent Manager";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      pkgsFor = system: import nixpkgs { inherit system; };

      # Keep appVersion in sync with src/contracts/protocol.odin APP_VERSION.
      appVersion = "0.1.0";
      npmDepsHash = "sha256-TMloUKbCJwOsAkU1o6P71YDcZ5qhPUrvzjB3b4T5owk=";

      mkOdinPackage = pkgs: odin: name: srcDir: pkgs.stdenv.mkDerivation {
        pname = name;
        version = appVersion;
        src = ./.;
        nativeBuildInputs = [ odin ];
        dontConfigure = true;
        dontInstall = true;
        buildPhase = ''
          runHook preBuild
          mkdir -p $out/bin
          odin build ${srcDir} -collection:odin_test=src -out:$out/bin/${name}
          ${if name == "ham-wrapper" then "ln -s ham-wrapper $out/bin/bc-agent-wrapper" else ""}
          ${if name == "ham-test-agent" then "ln -s ham-test-agent $out/bin/bc-test-agent" else ""}
          runHook postBuild
        '';
      };

      mkOdinPackageWithRuntime = pkgs: odin: name: srcDir: runtimeInputs: pkgs.stdenv.mkDerivation {
        pname = name;
        version = appVersion;
        src = ./.;
        nativeBuildInputs = [ odin pkgs.makeWrapper ];
        buildInputs = runtimeInputs;
        dontConfigure = true;
        dontInstall = true;
        buildPhase = ''
          runHook preBuild
          mkdir -p $out/bin
          odin build ${srcDir} -collection:odin_test=src -out:$out/bin/${name}
          wrapProgram $out/bin/${name} --prefix PATH : ${pkgs.lib.makeBinPath runtimeInputs}
          runHook postBuild
        '';
      };

      mkOdinDaemonPackage = pkgs: odin: pkgs.stdenv.mkDerivation {
        pname = "ham-daemon";
        version = appVersion;
        src = ./.;
        nativeBuildInputs = [ odin pkgs.makeWrapper ];
        buildInputs = [ pkgs.sqlite ];
        dontConfigure = true;
        dontInstall = true;
        buildPhase = ''
          runHook preBuild
          mkdir -p $out/bin
          odin build src/daemon -collection:odin_test=src -out:$out/bin/ham-daemon
          wrapProgram $out/bin/ham-daemon --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.sqlite ]}
          runHook postBuild
        '';
      };

      mkOdinCtlPackage = pkgs: odin: pkgs.stdenv.mkDerivation {
        pname = "ham-ctl";
        version = appVersion;
        src = ./.;
        nativeBuildInputs = [ odin ];
        dontConfigure = true;
        dontInstall = true;
        buildPhase = ''
          runHook preBuild
          mkdir -p $out/bin
          odin build src/ctl -collection:odin_test=src -out:$out/bin/ham-ctl
          runHook postBuild
        '';
      };

      mkOdinUiPackage = pkgs: pkgs.buildNpmPackage {
        pname = "heimdall";
        version = appVersion;
        src = ./.;
        inherit npmDepsHash;
        nativeBuildInputs = [ pkgs.makeWrapper ];
        npmBuildScript = "build";
        npmFlags = [ "--ignore-scripts" ];
        npmInstallFlags = [ "--ignore-scripts" ];
        installPhase = ''
          runHook preInstall
          mkdir -p $out/share/heimdall/{dist,electron-dist}
          cp -r dist/* $out/share/heimdall/dist/
          cp -r electron-dist/* $out/share/heimdall/electron-dist/
          mkdir -p $out/bin
          makeWrapper ${pkgs.electron}/bin/electron $out/bin/heimdall \
            --add-flags "$out/share/heimdall/electron-dist/main.cjs"
          runHook postInstall
        '';
      };

      mkNodeModules = pkgs: pkgs.buildNpmPackage {
        pname = "heimdall-node-modules";
        version = appVersion;
        src = ./.;
        inherit npmDepsHash;
        dontBuild = true;
        npmFlags = [ "--ignore-scripts" ];
        npmInstallFlags = [ "--ignore-scripts" ];
        installPhase = ''
          runHook preInstall
          mkdir -p $out
          cp -r node_modules $out/node_modules
          runHook postInstall
        '';
      };

      homeManagerModule = import ./nix/home-manager.nix { inherit self; };
    in
    {
      homeModules.default = homeManagerModule;
      homeManagerModules.default = homeManagerModule;

      packages = forAllSystems (system:
        let
          pkgs = pkgsFor system;
          # On current nixpkgs-unstable Darwin, pkgs.odin's default LLVM 18 path can
          # try to locally build compiler-rt against a newer Apple SDK/libc++ and fail.
          # Building Odin with LLVM 21 avoids that compiler-rt mismatch and stays on
          # nixpkgs-unstable.
          odin = pkgs.odin.override { llvmPackages_18 = pkgs.llvmPackages_21; };
        in
        {
          ham-daemon = mkOdinDaemonPackage pkgs odin;
          ham-wrapper = mkOdinPackage pkgs odin "ham-wrapper" "src/wrapper";
          ham-ctl = mkOdinCtlPackage pkgs odin;
          ham-test-agent = mkOdinPackage pkgs odin "ham-test-agent" "src/test_agent";
          ham-team-kinds-test = mkOdinPackage pkgs odin "ham-team-kinds-test" "tests";
          ham-team-db-service-test = mkOdinPackageWithRuntime pkgs odin "ham-team-db-service-test" "tests/team_db_service_test" [ pkgs.sqlite ];
          ham-team-service-test = mkOdinPackageWithRuntime pkgs odin "ham-team-service-test" "tests/team_service_test" [ pkgs.sqlite ];
          ham-task-store-repository-test = mkOdinPackageWithRuntime pkgs odin "ham-task-store-repository-test" "tests/task_store_repository_test" [ pkgs.sqlite ];
          ham-vcs-backend-test = mkOdinPackageWithRuntime pkgs odin "ham-vcs-backend-test" "tests/vcs_backend_test" [ pkgs.git pkgs.jujutsu ];
          heimdall = mkOdinUiPackage pkgs;
          heimdall-node-modules = mkNodeModules pkgs;
          bc-agent-wrapper = self.packages.${system}.ham-wrapper;
          bc-test-agent = self.packages.${system}.ham-test-agent;
          default = self.packages.${system}.ham-daemon;
        });

      apps = forAllSystems (system: 
        let pkgs = pkgsFor system;
        in {
        daemon = {
          type = "app";
          program = "${self.packages.${system}.ham-daemon}/bin/ham-daemon";
        };
        # daemon-with-wrapper: builds the current ham-wrapper alongside the
        # ham-daemon and launches the daemon with a generated config whose
        # [daemon].wrapper_bin points at that exact wrapper store path. This is
        # stronger than relying on ./result-wrapper because it works from any
        # CWD/config and cannot accidentally use a stale symlink.
        #
        # Extra args are forwarded. If --config is supplied, that config is used
        # as the base and rewritten into a temp file with the current wrapper.
        daemon-with-wrapper = {
          type = "app";
          program = "${pkgs.writeShellScriptBin "ham-daemon-with-wrapper" ''
            #!/usr/bin/env bash
            set -euo pipefail

            HAM_DAEMON="${self.packages.${system}.ham-daemon}/bin/ham-daemon"
            HAM_WRAPPER="${self.packages.${system}.ham-wrapper}/bin/ham-wrapper"
            HAM_WRAPPER_DIR="${self.packages.${system}.ham-wrapper}"

            # Keep the legacy repo symlink fresh for tools/tests that still read
            # config.toml directly, but do not depend on it for this daemon run.
            if [ -L result-wrapper ] || [ ! -e result-wrapper ]; then
              ln -sfn "$HAM_WRAPPER_DIR" result-wrapper
              echo "[ham-daemon-with-wrapper] refreshed ./result-wrapper -> $HAM_WRAPPER_DIR"
            fi

            CONFIG_PATH=""
            REST=()
            while [ "$#" -gt 0 ]; do
              case "$1" in
                --config)
                  if [ "$#" -lt 2 ]; then
                    echo "[ham-daemon-with-wrapper] --config requires a path" >&2
                    exit 2
                  fi
                  CONFIG_PATH="$2"
                  shift 2
                  ;;
                *)
                  REST+=("$1")
                  shift
                  ;;
              esac
            done
            if [ -z "$CONFIG_PATH" ]; then
              XDG_CONFIG="''${XDG_CONFIG_HOME:-$HOME/.config}/heimdall/config.toml"
              if [ -f "$XDG_CONFIG" ]; then
                CONFIG_PATH="$XDG_CONFIG"
                echo "[ham-daemon-with-wrapper] using $CONFIG_PATH"
              else
                echo "[ham-daemon-with-wrapper] no config at $XDG_CONFIG; pass --config <path> to override" >&2
              fi
            fi

            TMP_CONFIG=""
            if [ -n "$CONFIG_PATH" ]; then
              TMP_CONFIG="$(${pkgs.coreutils}/bin/mktemp "''${TMPDIR:-/tmp}/heimdall-daemon-with-wrapper.XXXXXX")"
              ${pkgs.gawk}/bin/awk -v wrapper="$HAM_WRAPPER" '
                BEGIN { in_daemon = 0; replaced = 0 }
                /^\[daemon\][[:space:]]*$/ { in_daemon = 1; print; next }
                /^\[/ {
                  if (in_daemon && !replaced) {
                    print "wrapper_bin = \"" wrapper "\""
                    replaced = 1
                  }
                  in_daemon = 0
                  print
                  next
                }
                in_daemon && /^[[:space:]]*wrapper_bin[[:space:]]*=/ {
                  print "wrapper_bin = \"" wrapper "\""
                  replaced = 1
                  next
                }
                { print }
                END {
                  if (!replaced) {
                    if (!in_daemon) print ""
                    if (!in_daemon) print "[daemon]"
                    print "wrapper_bin = \"" wrapper "\""
                  }
                }
              ' "$CONFIG_PATH" > "$TMP_CONFIG"
              trap 'rm -f "$TMP_CONFIG"' EXIT
              set -- --config "$TMP_CONFIG" "''${REST[@]}"
              echo "[ham-daemon-with-wrapper] base config: $CONFIG_PATH"
              echo "[ham-daemon-with-wrapper] generated config: $TMP_CONFIG"
            else
              set -- "''${REST[@]}"
            fi

            echo "[ham-daemon-with-wrapper] daemon: $HAM_DAEMON"
            echo "[ham-daemon-with-wrapper] wrapper: $HAM_WRAPPER"
            exec "$HAM_DAEMON" "$@"
          ''}/bin/ham-daemon-with-wrapper";
        };
        wrapper = {
          type = "app";
          program = "${self.packages.${system}.ham-wrapper}/bin/ham-wrapper";
        };
        ctl = {
          type = "app";
          program = "${self.packages.${system}.ham-ctl}/bin/ham-ctl";
        };
        test-agent = {
          type = "app";
          program = "${self.packages.${system}.ham-test-agent}/bin/ham-test-agent";
        };
        heimdall = {
          type = "app";
          program = "${pkgs.writeShellScriptBin "heimdall" ''
            #!/usr/bin/env bash
            set -euo pipefail

            echo "[heimdall] Checking for node_modules..."
            if [ ! -d "node_modules" ]; then
              echo "[heimdall] node_modules not found. Running npm install..."
              ${pkgs.nodejs}/bin/npm install
            fi

            echo "[heimdall] Building Electron TypeScript..."
            ${pkgs.nodejs}/bin/npm run build:electron

            PORT=5173
            while ! (${pkgs.python3}/bin/python3 -c "import socket; s = socket.socket(); s.bind(('127.0.0.1', $PORT)); s.close()" 2>/dev/null); do
              PORT=$((PORT + 1))
            done

            echo "[heimdall] Starting Vite dev server on port $PORT..."
            ${pkgs.nodejs}/bin/npx vite --host 127.0.0.1 --port "$PORT" &
            VITE_PID=$!
            cleanup() {
              echo "[heimdall] Cleaning up Vite dev server (PID: $VITE_PID)..."
              kill "$VITE_PID" 2>/dev/null || true
            }
            trap cleanup EXIT INT TERM

            echo "[heimdall] Waiting for Vite server at http://127.0.0.1:$PORT..."
            while ! ${pkgs.curl}/bin/curl -s "http://127.0.0.1:$PORT" > /dev/null 2>&1; do
              if ! kill -0 "$VITE_PID" 2>/dev/null; then
                echo "[heimdall] Vite server process died unexpectedly." >&2
                exit 1
              fi
              sleep 0.1
            done

            echo "[heimdall] Vite ready. Launching Electron in dev mode..."
            export VITE_DEV_SERVER_URL="http://127.0.0.1:$PORT"
            ${pkgs.electron}/bin/electron electron-dist/main.cjs
          ''}/bin/heimdall";
        };
        heimdall-browser = {
          type = "app";
          program = "${pkgs.writeShellScriptBin "heimdall-browser" ''
            #!/usr/bin/env bash
            MODE="dev"
            PORT="5173"

            while [[ "$#" -gt 0 ]]; do
                case $1 in
                    --dev) MODE="dev"; shift ;;
                    --release) MODE="release"; shift ;;
                    --port) PORT="$2"; shift 2 ;;
                    *) echo "Unknown parameter passed: $1"; exit 1 ;;
                esac
            done

            echo "[heimdall] Starting Vite server ($MODE mode) on port $PORT..."
            if [ ! -d "node_modules" ]; then
              echo "[heimdall] node_modules not found. Copying from Nix store..."
              cp -r "${self.packages.${system}.heimdall-node-modules}/node_modules" node_modules
              chmod -R u+w node_modules
            fi

            if [ "$MODE" == "release" ]; then
              echo "[heimdall] Building for release..."
              ${pkgs.nodejs}/bin/npm run build
              ${pkgs.nodejs}/bin/npx vite preview --host 127.0.0.1 --port $PORT
            else
              ${pkgs.nodejs}/bin/npx vite --host 127.0.0.1 --port $PORT
            fi
          ''}/bin/heimdall-browser";
        };
        default = self.apps.${system}.daemon;
      });

      devShells = forAllSystems (system:
        let
          pkks = pkgsFor system;
          odin = pkks.odin.override { llvmPackages_18 = pkks.llvmPackages_21; };
          ols = pkks.ols.override { inherit odin; };
        in
        {
          default = pkks.mkShell {
            packages = [
              odin
              ols
              pkks.tmux
              pkks.curl
              pkks.jq
            ];
          };
        });
    };
}
