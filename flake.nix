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
<<<<<<< HEAD
        nativeBuildInputs = [ odin ];
        buildInputs = [ pkgs.sqlite ];
=======
        nativeBuildInputs = [ odin pkgs.makeWrapper ];
>>>>>>> 90f9cd3 (Add teams db schema service)
        dontConfigure = true;
        dontInstall = true;
        buildPhase = ''
          runHook preBuild
          mkdir -p $out/bin
<<<<<<< HEAD
          odin build src/daemon -collection:odin_test=src -out:$out/bin/ham-daemon
=======
          odin build src/daemon -collection:odin_test=src -out:$out/bin/bc-odin-daemon
          wrapProgram $out/bin/bc-odin-daemon --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.sqlite ]}
          odin build src/wrapper -collection:odin_test=src -out:$out/bin/bc-agent-wrapper
>>>>>>> 90f9cd3 (Add teams db schema service)
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
        npmDepsHash = "sha256-TZJIsQ3ckX+WAZEcSrKcEni1Ah+GnUX/P1YN4oFnm1g=";
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
          heimdall = mkOdinUiPackage pkgs;
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
        # ham-daemon, refreshes ./result-wrapper -> the freshly built store
        # path, and launches the daemon with ./config.toml. Use this in place
        # of `nix run .#ham-daemon` when you want a one-shot "latest daemon +
        # latest wrapper" boot without hand-managing the symlink.
        #
        # Extra args (e.g. --config /elsewhere.toml, --port ...) are forwarded.
        daemon-with-wrapper = {
          type = "app";
          program = "${pkgs.writeShellScriptBin "ham-daemon-with-wrapper" ''
            #!/usr/bin/env bash
            set -euo pipefail

            HAM_DAEMON="${self.packages.${system}.ham-daemon}/bin/ham-daemon"
            HAM_WRAPPER_DIR="${self.packages.${system}.ham-wrapper}"

            # Refresh ./result-wrapper -> latest wrapper store path so the
            # repo's config.toml (wrapper_bin = ./result-wrapper/bin/ham-wrapper)
            # resolves to the just-built binary. Only do this when run from
            # a directory that already has a result-wrapper (i.e. the repo);
            # otherwise skip silently so the daemon still starts.
            if [ -L result-wrapper ] || [ ! -e result-wrapper ]; then
              ln -sfn "$HAM_WRAPPER_DIR" result-wrapper
              echo "[ham-daemon-with-wrapper] refreshed ./result-wrapper -> $HAM_WRAPPER_DIR"
            fi

            # If no --config flag was passed and a repo config exists, use it.
            HAS_CONFIG=0
            for arg in "$@"; do
              if [ "$arg" = "--config" ]; then HAS_CONFIG=1; break; fi
            done
            if [ "$HAS_CONFIG" -eq 0 ] && [ -f "$PWD/config.toml" ]; then
              set -- --config "$PWD/config.toml" "$@"
              echo "[ham-daemon-with-wrapper] using $PWD/config.toml"
            fi

            echo "[ham-daemon-with-wrapper] daemon: $HAM_DAEMON"
            echo "[ham-daemon-with-wrapper] wrapper: $HAM_WRAPPER_DIR/bin/ham-wrapper"
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
          program = "${self.packages.${system}.heimdall}/bin/heimdall";
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
              echo "[heimdall] node_modules not found. Running npm install..."
              ${pkgs.nodejs}/bin/npm install
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
