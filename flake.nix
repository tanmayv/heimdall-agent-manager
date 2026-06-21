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

      mkOdinDaemonPackage = pkgs: odin: pkgs.stdenv.mkDerivation {
        pname = "ham-daemon";
        version = appVersion;
        src = ./.;
        nativeBuildInputs = [ odin ];
        dontConfigure = true;
        dontInstall = true;
        buildPhase = ''
          runHook preBuild
          mkdir -p $out/bin
          odin build src/daemon -collection:odin_test=src -out:$out/bin/ham-daemon
          odin build src/wrapper -collection:odin_test=src -out:$out/bin/ham-wrapper
          ln -s ham-daemon $out/bin/bc-odin-daemon
          ln -s ham-wrapper $out/bin/bc-agent-wrapper
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
          odin build src/wrapper -collection:odin_test=src -out:$out/bin/ham-wrapper
          ln -s ham-ctl $out/bin/bc-odinctl
          ln -s ham-wrapper $out/bin/bc-agent-wrapper
          runHook postBuild
        '';
      };

      mkOdinUiPackage = pkgs: pkgs.buildNpmPackage {
        pname = "heimdall";
        version = appVersion;
        src = ./.;
        npmDepsHash = "sha256-HGsFWlo7IUWrhJBqsmXDAmhGZ6dDEaZ39ZOi1cGg7eU=";
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
          ln -s heimdall $out/bin/odin-ui
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
          heimdall = mkOdinUiPackage pkgs;
          # Compatibility package aliases for existing users/scripts.
          bc-odin-daemon = self.packages.${system}.ham-daemon;
          bc-agent-wrapper = self.packages.${system}.ham-wrapper;
          bc-odinctl = self.packages.${system}.ham-ctl;
          bc-test-agent = self.packages.${system}.ham-test-agent;
          bc-odin-ui = self.packages.${system}.heimdall;
          default = self.packages.${system}.ham-daemon;
        });

      apps = forAllSystems (system: {
        daemon = {
          type = "app";
          program = "${self.packages.${system}.ham-daemon}/bin/ham-daemon";
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
        odin-ui = self.apps.${system}.heimdall;
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
