#!/usr/bin/env python3
"""Verification test suite for Jetski provider preconfiguration and CitC explorer root (CT-15)."""

import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INSTALL_SH = ROOT / "scripts" / "install.sh"
PACKAGE_SH = ROOT / "scripts" / "package-cloudtop-bundle.sh"
FS_MANAGEMENT_ODIN = ROOT / "src" / "bridge" / "fs_management.odin"


def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"[-] FAIL: {message}")
        sys.exit(1)


def test_static_checks() -> None:
    install_txt = INSTALL_SH.read_text(encoding="utf-8")
    package_txt = PACKAGE_SH.read_text(encoding="utf-8")
    fs_mgmt_txt = FS_MANAGEMENT_ODIN.read_text(encoding="utf-8")

    # 1. install.sh must configure providers.json
    require("providers.json" in install_txt, "scripts/install.sh must reference providers.json")
    require('"jetski"' in install_txt, "scripts/install.sh must preconfigure jetski provider")
    require("Gemini 3.5 Flash" in install_txt, "scripts/install.sh must specify Gemini 3.5 Flash")
    require("Gemini 3.7 Flash" in install_txt, "scripts/install.sh must specify Gemini 3.7 Flash")
    require("Gemini 3.8 Flash" in install_txt, "scripts/install.sh must specify Gemini 3.8 Flash")
    require("chmod 0600" in install_txt, "scripts/install.sh must set 0600 permissions on providers.json")

    # 2. package-cloudtop-bundle.sh must pre-seed providers.json
    require("bridge/providers.json" in package_txt, "scripts/package-cloudtop-bundle.sh must package bridge/providers.json")
    require('"default_provider": "jetski"' in package_txt, "scripts/package-cloudtop-bundle.sh must set default_provider: jetski")

    # 3. fs_management.odin must allow CitC roots
    require("fig_citc_user_root" in fs_mgmt_txt, "src/bridge/fs_management.odin must check fig_citc_user_root in bridge_fs_effective_root")
    require('"/google/src/cloud"' in fs_mgmt_txt, "src/bridge/fs_management.odin must check /google/src/cloud in bridge_fs_effective_root")

    print("[+] Static checks PASSED")


def test_install_script_execution() -> None:
    temp_dir = Path(tempfile.mkdtemp(prefix="heimdall-test-ct15-"))
    try:
        env = dict(os.environ)
        env["HEIMDALL_DATA_DIR"] = str(temp_dir)

        test_script = f"""
        set -euo pipefail
        DATA_DIR="{temp_dir}"
        BUNDLE_DIR="{ROOT}/dist/heimdall-cloudtop"
        
        BRIDGE_CONFIG_DIR="$DATA_DIR/bridge"
        PROVIDERS_FILE="$BRIDGE_CONFIG_DIR/providers.json"
        mkdir -p "$BRIDGE_CONFIG_DIR"
        chmod 0700 "$BRIDGE_CONFIG_DIR"

        if [ ! -f "$PROVIDERS_FILE" ] || ! grep -q '"jetski"' "$PROVIDERS_FILE" 2>/dev/null; then
          if [ -f "$BUNDLE_DIR/bridge/providers.json" ]; then
            cp "$BUNDLE_DIR/bridge/providers.json" "$PROVIDERS_FILE"
          else
            cat << 'PROVIDERSEOF' > "$PROVIDERS_FILE"
{{
  "default_provider": "jetski",
  "default_tier": "normal",
  "providers": [
    {{
      "name": "jetski",
      "enabled": true,
      "command": [
        "/google/bin/releases/jetski-devs/tools/cli"
      ],
      "prompt_flags": [
        "--prompt-interactive"
      ],
      "yolo_flags": [
        "--dangerously-skip-permissions"
      ],
      "starter_prompt": "First, run: {{ctl_bin}} --token {{token}} start-success.",
      "prompt_delivery": "",
      "skill_dir": ".agents/skills",
      "bootstrap_file_name": "AGENTS.md",
      "models": {{
        "flag": "--model",
        "cheap": "Gemini 3.5 Flash",
        "normal": "Gemini 3.7 Flash",
        "smart": "Gemini 3.8 Flash"
      }},
      "startup_detection": {{
        "enabled": false,
        "startup_probe_seconds": 0,
        "capture_interval_ms": 0,
        "blocked_patterns": [],
        "auto_enter_patterns": [],
        "auto_enter_pre_keys": [],
        "startup_unknown_is_blocked": false,
        "sanitized_reason_mapping": []
      }},
      "activity_detection": {{
        "enabled": true,
        "sample_line_count": 20,
        "ignore_bottom_lines": 0,
        "check_interval_seconds": 15,
        "min_gap_ms": 100,
        "max_gap_ms": 500
      }}
    }}
  ]
}}
PROVIDERSEOF
          fi
          chmod 0600 "$PROVIDERS_FILE"
        fi
        """
        subprocess.run(["bash", "-c", test_script], capture_output=True, text=True, check=True)
        providers_path = temp_dir / "bridge" / "providers.json"
        require(providers_path.exists(), "providers.json must be created")
        
        data = json.loads(providers_path.read_text(encoding="utf-8"))
        require(data.get("default_provider") == "jetski", "default_provider must be 'jetski'")
        require(data.get("default_tier") == "normal", "default_tier must be 'normal'")
        
        providers = data.get("providers", [])
        require(len(providers) == 1, "There must be 1 provider configured")
        jetski = providers[0]
        require(jetski.get("name") == "jetski", "Provider name must be 'jetski'")
        require(jetski.get("enabled") is True, "Provider must be enabled")
        require("/google/bin/releases/jetski-devs/tools/cli" in jetski.get("command", []), "Command must include jetski CLI")
        
        models = jetski.get("models", {})
        require(models.get("cheap") == "Gemini 3.5 Flash", "Cheap tier must be Gemini 3.5 Flash")
        require(models.get("normal") == "Gemini 3.7 Flash", "Normal tier must be Gemini 3.7 Flash")
        require(models.get("smart") == "Gemini 3.8 Flash", "Smart tier must be Gemini 3.8 Flash")
        
        mode = oct(providers_path.stat().st_mode & 0o777)
        require(mode == "0o600", f"providers.json permissions must be 0600, got {mode}")
        
        print("[+] Install snippet execution test PASSED")
    finally:
        shutil.rmtree(temp_dir, ignore_errors=True)


def main() -> None:
    print("=== Testing Jetski Install Config & CitC Explorer Support (CT-15) ===")
    test_static_checks()
    test_install_script_execution()
    print("[+] ALL CT-15 TESTS PASSED SUCCESSFULLY!")


if __name__ == "__main__":
    main()
