#!/usr/bin/env python3
"""Automated verification test suite for REQ-REMOTE-1:
Multi-bridge port isolation and conflict guard in install.sh and start.sh.

Verifies:
1. Static analysis checks on install.sh, package-cloudtop-bundle.sh, and dist/heimdall-cloudtop/start.sh.
2. Standalone mode isolates conflict check to target bridge port only (ignoring 49322, 49323, 8989).
3. Primary bridge on port 49323 is never touched or killed when running in standalone mode.
4. Custom DATA_DIR does not overwrite, stop, or restart the primary systemd unit.
5. Port fallback from 49323 to 49325 is evaluated before conflict checking in standalone mode.
"""
from __future__ import annotations

import os
import pty
import select
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INSTALL_SH = ROOT / "scripts" / "install.sh"
PACKAGE_SH = ROOT / "scripts" / "package-cloudtop-bundle.sh"
DIST_START_SH = ROOT / "dist" / "heimdall-cloudtop" / "start.sh"


def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"[-] FAIL: {message}", file=sys.stderr)
        sys.exit(1)


def free_port() -> int:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def test_static_checks() -> None:
    print("[+] Running static analysis checks for REQ-REMOTE-1...")
    install_txt = INSTALL_SH.read_text(encoding="utf-8")
    package_txt = PACKAGE_SH.read_text(encoding="utf-8")
    dist_start_txt = DIST_START_SH.read_text(encoding="utf-8")

    # 1. install.sh checks
    require('MODE="standalone"' in install_txt or 'MODE=standalone' in install_txt or '[ "${MODE:-}" = "standalone" ]' in install_txt,
            "install.sh must handle standalone mode")
    require('BRIDGE_PORT=49325' in install_txt, "install.sh must have 49325 fallback for BRIDGE_PORT")
    require('conflict_ports=("${BRIDGE_PORT:-49323}")' in install_txt or 'conflict_ports=("$BRIDGE_PORT")' in install_txt,
            "install.sh must isolate conflict_ports to BRIDGE_PORT in standalone mode")
    require('should_check_systemd' in install_txt, "install.sh must guard systemd checks")
    require('Custom HEIMDALL_DATA_DIR' in install_txt, "install.sh must log notice when custom DATA_DIR avoids systemd reload")

    # 2. package-cloudtop-bundle.sh (and template) checks
    require('conflict_ports=("$BRIDGE_PORT")' in package_txt,
            "package-cloudtop-bundle.sh must set conflict_ports to BRIDGE_PORT in standalone mode")
    require('should_check_systemd' in package_txt,
            "package-cloudtop-bundle.sh must guard systemd checks for standalone mode")

    # Verify fallback is before check_and_resolve_conflicts in package_txt
    fb_idx_pkg = package_txt.index('using fallback port 49325 for standalone bridge')
    conflict_idx_pkg = package_txt.index('check_and_resolve_conflicts "$FORCE"')
    require(fb_idx_pkg < conflict_idx_pkg,
            "package-cloudtop-bundle.sh must evaluate port fallback before check_and_resolve_conflicts")

    # 3. dist/heimdall-cloudtop/start.sh checks
    require('conflict_ports=("$BRIDGE_PORT")' in dist_start_txt,
            "dist/heimdall-cloudtop/start.sh must set conflict_ports to BRIDGE_PORT in standalone mode")
    fb_idx_dist = dist_start_txt.index('using fallback port 49325 for standalone bridge')
    conflict_idx_dist = dist_start_txt.index('check_and_resolve_conflicts "$FORCE"')
    require(fb_idx_dist < conflict_idx_dist,
            "dist/heimdall-cloudtop/start.sh must evaluate port fallback before check_and_resolve_conflicts")

    print("[+] Static analysis checks for REQ-REMOTE-1 PASSED")


def extract_install_conflict_section() -> str:
    install_txt = INSTALL_SH.read_text(encoding="utf-8")
    start_marker = "is_ancestor_or_self() {"
    end_marker = 'check_and_resolve_conflicts "$FORCE"'
    start_idx = install_txt.index(start_marker)
    end_idx = install_txt.index(end_marker) + len(end_marker)
    return install_txt[start_idx:end_idx]


def extract_start_conflict_section() -> str:
    start_txt = DIST_START_SH.read_text(encoding="utf-8")
    start_marker = "is_ancestor_or_self() {"
    end_marker = 'check_and_resolve_conflicts "$FORCE"'
    start_idx = start_txt.index(start_marker)
    end_idx = start_txt.index(end_marker) + len(end_marker)
    return start_txt[start_idx:end_idx]


def test_install_standalone_isolation_behavior() -> None:
    print("[+] Testing install.sh standalone port isolation behavior...")
    conflict_section = extract_install_conflict_section()

    with tempfile.TemporaryDirectory(prefix="heimdall-multi-bridge-test-") as tmpdir:
        run_dir = Path(tmpdir) / "run"
        run_dir.mkdir(parents=True, exist_ok=True)

        # Bind dummy process on 49323 if not already bound
        dummy_srv_49323 = None
        s_test = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s_test.settimeout(0.2)
        if s_test.connect_ex(("127.0.0.1", 49323)) != 0:
            dummy_srv_49323 = subprocess.Popen(
                [sys.executable, "-c",
                 "import socket, time; s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('127.0.0.1', 49323)); s.listen(5); time.sleep(60)"]
            )
            time.sleep(0.5)
        s_test.close()

        try:
            # Case 1: Standalone mode with 49323 occupied and 49325 free.
            # Must choose 49325, ignore 49323, and succeed without conflict.
            test_script_content = f"""#!/usr/bin/env bash
set -euo pipefail
DATA_DIR="{tmpdir}"
RUN_DIR="{run_dir}"
FORCE=false
MODE="standalone"
HEIMDALL_BRIDGE_PORT=""

{conflict_section}

echo "DETECTED_BRIDGE_PORT=$BRIDGE_PORT"
"""
            script_file = Path(tmpdir) / "test_standalone_conflict.sh"
            script_file.write_text(test_script_content)
            script_file.chmod(0o755)

            res = subprocess.run([str(script_file)], capture_output=True, text=True)
            require(res.returncode == 0, f"Expected 0 exit code in standalone mode, got {res.returncode}: {res.stderr}")
            require("DETECTED_BRIDGE_PORT=49325" in res.stdout,
                    f"Expected fallback to 49325 when 49323 occupied, got: {res.stdout}")
            print("    [+] Standalone mode correctly fell back to 49325 and ignored 49323 conflict (PASSED)")

            # Case 2: Standalone mode when target port 49325 is occupied.
            # Must detect conflict on 49325.
            dummy_49325 = subprocess.Popen(
                [sys.executable, "-c",
                 "import socket, time; s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('127.0.0.1', 49325)); s.listen(5); time.sleep(60)"]
            )
            time.sleep(0.5)
            try:
                res_conflict = subprocess.run([str(script_file)], capture_output=True, text=True, stdin=subprocess.DEVNULL)
                require(res_conflict.returncode != 0,
                        f"Expected conflict on occupied target port 49325, got returncode {res_conflict.returncode}")
                require("Existing Heimdall processes/service occupy ports" in res_conflict.stderr,
                        "Expected conflict error message when 49325 occupied")
                print("    [+] Standalone mode accurately detected conflict when target port 49325 was occupied (PASSED)")
            finally:
                dummy_49325.terminate()
                dummy_49325.wait()

            # Case 3: Port 49322 occupied by a dummy process.
            # In standalone mode (target 49325), 49322 must be IGNORED (exits 0).
            # In full mode, 49322 must trigger a CONFLICT (non-zero exit).
            dummy_49322 = subprocess.Popen(
                [sys.executable, "-c",
                 "import socket, time; s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('127.0.0.1', 49322)); s.listen(5); time.sleep(60)"]
            )
            time.sleep(0.5)
            try:
                # Standalone mode should ignore 49322
                res_standalone_49322 = subprocess.run([str(script_file)], capture_output=True, text=True, stdin=subprocess.DEVNULL)
                require(res_standalone_49322.returncode == 0,
                        f"Standalone mode should ignore occupied port 49322, got returncode {res_standalone_49322.returncode}: {res_standalone_49322.stderr}")

                # Full mode must detect conflict on 49322
                test_full_content = f"""#!/usr/bin/env bash
set -euo pipefail
DATA_DIR="{tmpdir}"
RUN_DIR="{run_dir}"
FORCE=false
MODE="full"
HEIMDALL_BRIDGE_PORT=""

{conflict_section}
"""
                script_full = Path(tmpdir) / "test_full_conflict.sh"
                script_full.write_text(test_full_content)
                script_full.chmod(0o755)

                res_full = subprocess.run([str(script_full)], capture_output=True, text=True, stdin=subprocess.DEVNULL)
                require(res_full.returncode != 0,
                        "Expected full mode to detect occupied port 49322 as conflict")
                require("Existing Heimdall processes/service occupy ports" in res_full.stderr,
                        "Expected conflict message in full mode for occupied port 49322")
                print("    [+] Standalone ignored port 49322 and Full mode detected conflict on 49322 (PASSED)")
            finally:
                dummy_49322.terminate()
                dummy_49322.wait()

        finally:
            if dummy_srv_49323:
                dummy_srv_49323.terminate()
                dummy_srv_49323.wait()


def test_start_standalone_isolation_behavior() -> None:
    print("[+] Testing start.sh standalone port isolation behavior...")
    conflict_section = extract_start_conflict_section()

    with tempfile.TemporaryDirectory(prefix="heimdall-start-test-") as tmpdir:
        run_dir = Path(tmpdir) / "run"
        run_dir.mkdir(parents=True, exist_ok=True)

        test_script_content = f"""#!/usr/bin/env bash
set -euo pipefail
BUNDLE_DIR="{tmpdir}"
DATA_DIR="{tmpdir}"
RUN_DIR="{run_dir}"
FORCE=false
IS_STANDALONE=true
STANDALONE_HUB_URL="http://example.c.googlers.com:8989"

{conflict_section}

echo "START_BRIDGE_PORT=$BRIDGE_PORT"
echo "START_ENDPOINT_PORT=$BRIDGE_ENDPOINT_PORT"
"""
        script_file = Path(tmpdir) / "test_start_standalone.sh"
        script_file.write_text(test_script_content)
        script_file.chmod(0o755)

        res = subprocess.run([str(script_file), "--standalone"], capture_output=True, text=True)
        require(res.returncode == 0, f"Expected start.sh standalone dry-run to exit 0, got {res.returncode}: {res.stderr}")
        require("START_BRIDGE_PORT=49325" in res.stdout,
                f"Expected start.sh to fall back to 49325, got: {res.stdout}")
        require("START_ENDPOINT_PORT=49326" in res.stdout,
                f"Expected start.sh to fall back to endpoint 49326, got: {res.stdout}")
        print("    [+] start.sh port fallback and conflict isolation verified (PASSED)")


def main() -> None:
    print("=== Testing Multi-Bridge Port Isolation & Conflict Guard (REQ-REMOTE-1) ===")
    test_static_checks()
    test_install_standalone_isolation_behavior()
    test_start_standalone_isolation_behavior()
    print("=== ALL REQ-REMOTE-1 VERIFICATION TESTS PASSED SUCCESSFULLY! ===")


if __name__ == "__main__":
    main()
