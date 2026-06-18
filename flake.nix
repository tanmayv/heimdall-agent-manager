{
  description = "Odin interactive agent daemon prototype";

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
          runHook postBuild
        '';
      };

      mkOdinDaemonPackage = pkgs: odin: pkgs.stdenv.mkDerivation {
        pname = "bc-odin-daemon";
        version = appVersion;
        src = ./.;
        nativeBuildInputs = [ odin ];
        dontConfigure = true;
        dontInstall = true;
        buildPhase = ''
          runHook preBuild
          mkdir -p $out/bin
          odin build src/daemon -collection:odin_test=src -out:$out/bin/bc-odin-daemon
          odin build src/wrapper -collection:odin_test=src -out:$out/bin/bc-agent-wrapper
          runHook postBuild
        '';
      };

      mkOdinCtlPackage = pkgs: odin: pkgs.stdenv.mkDerivation {
        pname = "bc-odinctl";
        version = appVersion;
        src = ./.;
        nativeBuildInputs = [ odin ];
        dontConfigure = true;
        dontInstall = true;
        buildPhase = ''
          runHook preBuild
          mkdir -p $out/bin
          odin build src/ctl -collection:odin_test=src -out:$out/bin/bc-odinctl
          odin build src/wrapper -collection:odin_test=src -out:$out/bin/bc-agent-wrapper
          runHook postBuild
        '';
      };
    in
    {
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
          bc-odin-daemon = mkOdinDaemonPackage pkgs odin;
          bc-agent-wrapper = mkOdinPackage pkgs odin "bc-agent-wrapper" "src/wrapper";
          bc-odinctl = mkOdinCtlPackage pkgs odin;
          bc-test-agent = mkOdinPackage pkgs odin "bc-test-agent" "src/test_agent";
          default = self.packages.${system}.bc-odin-daemon;
        });

      apps = forAllSystems (system: {
        daemon = {
          type = "app";
          program = "${self.packages.${system}.bc-odin-daemon}/bin/bc-odin-daemon";
        };
        wrapper = {
          type = "app";
          program = "${self.packages.${system}.bc-agent-wrapper}/bin/bc-agent-wrapper";
        };
        ctl = {
          type = "app";
          program = "${self.packages.${system}.bc-odinctl}/bin/bc-odinctl";
        };
        test-agent = {
          type = "app";
          program = "${self.packages.${system}.bc-test-agent}/bin/bc-test-agent";
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
