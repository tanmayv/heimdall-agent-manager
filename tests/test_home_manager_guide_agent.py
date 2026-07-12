#!/usr/bin/env python3
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def render_config(extra_module: str) -> str:
    expr = f'''
let
  flake = builtins.getFlake (toString {ROOT});
  system = builtins.currentSystem;
  pkgs = import flake.inputs.nixpkgs {{ inherit system; }};
  lib = pkgs.lib;
  module = flake.outputs.homeModules.default;
  hmStub = {{ lib, ... }}: {{
    options = {{
      home.packages = lib.mkOption {{ type = lib.types.listOf lib.types.anything; default = []; }};
      xdg.configFile = lib.mkOption {{
        type = lib.types.attrsOf (lib.types.submodule ({{ name, ... }}: {{
          options.source = lib.mkOption {{ type = lib.types.path; }};
        }}));
        default = {{}};
      }};
      systemd.user.services = lib.mkOption {{ type = lib.types.attrsOf lib.types.anything; default = {{}}; }};
    }};
  }};
  eval = lib.evalModules {{
    modules = [
      hmStub
      module
      {{ programs.heimdall.enable = true; }}
      {extra_module}
    ];
    specialArgs = {{ inherit pkgs; }};
  }};
in builtins.readFile eval.config.xdg.configFile."heimdall/config.toml".source
'''
    res = subprocess.run(
        ["nix", "eval", "--impure", "--raw", "--expr", expr],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    if res.returncode != 0:
        print(res.stdout)
        print(res.stderr)
        raise SystemExit(res.returncode)
    return res.stdout


def require(name: str, ok: bool):
    if not ok:
        print(f"FAILED: {name}")
        raise SystemExit(1)


def main() -> int:
    default_cfg = render_config("{}")
    require("default config renders guide_agent section", "[guide_agent]" in default_cfg)
    require("default guide enabled true", 'enabled = true' in default_cfg)
    require("default guide autostart true", 'autostart = true' in default_cfg)
    require("default guide restart_if_stopped true", 'restart_if_stopped = true' in default_cfg)
    require("default guide singleton id", 'agent_instance_id = "guide@heimdall"' in default_cfg)
    require("default guide template id", 'template_id = "guide"' in default_cfg)
    require("default guide provider profile", 'provider_profile = "pi"' in default_cfg)
    require("default guide model tier", 'model_tier = "smart"' in default_cfg)
    require("non-guide sections remain rendered", "[wrapper]" in default_cfg and "[ctl]" in default_cfg and "[daemon]" in default_cfg)

    custom_cfg = render_config('''
      {
        programs.heimdall.guideAgent = {
          enabled = false;
          autostart = false;
          restartIfStopped = false;
          agentInstanceId = "guide@alt";
          templateId = "guide-custom";
          providerProfile = "";
          modelTier = "normal";
        };
      }
    ''')
    require("custom guide enabled false", 'enabled = false' in custom_cfg)
    require("custom guide autostart false", 'autostart = false' in custom_cfg)
    require("custom guide restart_if_stopped false", 'restart_if_stopped = false' in custom_cfg)
    require("custom guide instance id", 'agent_instance_id = "guide@alt"' in custom_cfg)
    require("custom guide template id", 'template_id = "guide-custom"' in custom_cfg)
    require("custom guide empty provider profile", 'provider_profile = ""' in custom_cfg)
    require("custom guide model tier", 'model_tier = "normal"' in custom_cfg)
    require("custom render preserves wrapper and ctl", "[wrapper]" in custom_cfg and "[ctl]" in custom_cfg)

    print("TEST PASSED: Home Manager guideAgent options render to [guide_agent] TOML")
    return 0


if __name__ == "__main__":
    sys.exit(main())
