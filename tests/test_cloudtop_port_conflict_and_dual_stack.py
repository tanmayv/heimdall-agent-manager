#!/usr/bin/env python3
"""Automated verification test suite for CT-17:
1. Port Conflict & Service Loop Detection in scripts/install.sh and scripts/package-cloudtop-bundle.sh (start.sh).
2. Dual-Stack IPv6 and IPv4 support in ham-dev-proxy (src/dev_proxy/main.odin).
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
DEV_PROXY_MAIN = ROOT / "src" / "dev_proxy" / "main.odin"
ODIN_BIN = "/nix/store/lrzcmy4vglphhshdpsqmsgjpnf5z1yhi-odin-dev-2026-05/bin/odin"


def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"[-] FAIL: {message}", file=sys.stderr)
        sys.exit(1)


def test_static_checks() -> None:
    print("[+] Running static analysis checks for CT-17...")
    install_txt = INSTALL_SH.read_text(encoding="utf-8")
    package_txt = PACKAGE_SH.read_text(encoding="utf-8")
    odin_txt = DEV_PROXY_MAIN.read_text(encoding="utf-8")

    # 1. install.sh checks
    require("FORCE=false" in install_txt, "install.sh must initialize FORCE=false")
    require("--force" in install_txt, "install.sh must support --force flag")
    require("49322" in install_txt and "49323" in install_txt and "49325" in install_txt and "8989" in install_txt,
            "install.sh must inspect ports 49322, 49323, 49325, and 8989")
    require("heimdall.service" in install_txt, "install.sh must check heimdall.service status")
    require("Existing Heimdall processes/service occupy ports" in install_txt,
            "install.sh must contain the conflict prompt text")
    require("Stop/kill them to restart cleanly? [Y/n]" in install_txt,
            "install.sh must ask to stop/kill them to restart cleanly")
    require("is_ancestor_or_self" in install_txt, "install.sh must protect ancestor PIDs")
    require("systemctl --user stop heimdall.service" in install_txt,
            "install.sh must stop systemd service on conflict resolution")

    # 2. package-cloudtop-bundle.sh checks (start.sh template)
    require("--force" in package_txt, "package-cloudtop-bundle.sh must parse --force in start.sh")
    require("49322" in package_txt and "49323" in package_txt and "49325" in package_txt and "8989" in package_txt,
            "package-cloudtop-bundle.sh must inspect ports 49322, 49323, 49325, and 8989 in start.sh")
    require("heimdall.service" in package_txt, "start.sh template must check heimdall.service status")
    require("Existing Heimdall processes/service occupy ports" in package_txt,
            "start.sh template must contain the conflict prompt text")
    require("Stop/kill them to restart cleanly? [Y/n]" in package_txt,
            "start.sh template must ask to stop/kill them to restart cleanly")
    require("is_ancestor_or_self" in package_txt, "start.sh template must protect ancestor PIDs")

    # 3. dev_proxy/main.odin checks
    require("net.IP6_Any" in odin_txt, "src/dev_proxy/main.odin must reference net.IP6_Any")
    require("net.IP4_Any" in odin_txt, "src/dev_proxy/main.odin must reference net.IP4_Any fallback")
    require('0.0.0.0' in odin_txt and '::' in odin_txt,
            "src/dev_proxy/main.odin must handle 0.0.0.0 and :: listen hosts")

    print("[+] Static analysis checks PASSED")


def free_port() -> int:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def test_dev_proxy_dual_stack() -> None:
    print("[+] Testing ham-dev-proxy IPv6/IPv4 dual-stack binding...")
    test_proxy_bin = Path("/tmp/ham-dev-proxy-ct17-test")
    build_cmd = [ODIN_BIN, "build", "src/dev_proxy", f"-out:{test_proxy_bin}", "-collection:odin_test=src"]
    subprocess.check_call(build_cmd, cwd=ROOT)

    port = free_port()
    proc = subprocess.Popen(
        [str(test_proxy_bin), "--listen", f"0.0.0.0:{port}", "--hub-url", "http://127.0.0.1:49322"],
        cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    time.sleep(0.6)

    try:
        require(proc.poll() is None, "ham-dev-proxy process exited prematurely")

        # 1. Connect via IPv4 loopback (127.0.0.1)
        s4 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s4.settimeout(3.0)
        s4.connect(("127.0.0.1", port))
        s4.sendall(b"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
        resp4 = s4.recv(1024)
        s4.close()
        require(b"HTTP/1.1 200 OK" in resp4 or b"Heimdall Cloudtop Gateway" in resp4,
                f"IPv4 connection failed to receive valid response: {resp4[:100]}")
        print("    [+] IPv4 loopback connection verified (HTTP 200 OK)")

        # 2. Connect via IPv6 loopback (::1)
        s6 = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
        s6.settimeout(3.0)
        s6.connect(("::1", port))
        s6.sendall(b"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
        resp6 = s6.recv(1024)
        s6.close()
        require(b"HTTP/1.1 200 OK" in resp6 or b"Heimdall Cloudtop Gateway" in resp6,
                f"IPv6 connection failed to receive valid response: {resp6[:100]}")
        print("    [+] IPv6 loopback connection verified (HTTP 200 OK)")

    finally:
        proc.terminate()
        try:
            proc.wait(timeout=2.0)
        except subprocess.TimeoutExpired:
            proc.kill()

    print("[+] ham-dev-proxy dual-stack test PASSED")


def extract_conflict_function_script() -> str:
    install_txt = INSTALL_SH.read_text(encoding="utf-8")
    start_marker = "is_ancestor_or_self() {"
    end_marker = 'check_and_resolve_conflicts "$FORCE"'
    start_idx = install_txt.index(start_marker)
    end_idx = install_txt.index(end_marker) + len(end_marker)
    return install_txt[start_idx:end_idx]


def test_conflict_detection_behavior() -> None:
    print("[+] Testing port conflict & loop detection behavior...")
    conflict_code = extract_conflict_function_script()

    with tempfile.TemporaryDirectory(prefix="heimdall-ct17-test-") as tmpdir:
        run_dir = Path(tmpdir) / "run"
        run_dir.mkdir(parents=True, exist_ok=True)

        dummy_srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        dummy_srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        dummy_port = free_port()
        dummy_srv.bind(("127.0.0.1", dummy_port))
        dummy_srv.listen(5)

        dummy_proc = subprocess.Popen(
            [sys.executable, "-c",
             f"import socket, time; s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('127.0.0.1', {dummy_port})); s.listen(5); time.sleep(60)"]
        )
        dummy_srv.close()
        time.sleep(0.5)

        require(dummy_proc.poll() is None, "Dummy process failed to start")
        dummy_pid = dummy_proc.pid

        stale_pid_file = run_dir / "test_stale.pid"
        stale_pid_file.write_text(f"{dummy_pid}\n")

        test_script_content = f"""#!/usr/bin/env bash
set -euo pipefail
DATA_DIR="{tmpdir}"
RUN_DIR="{run_dir}"
FORCE=false

{conflict_code.replace("conflict_ports=(49322 49323 49325 8989)", f"conflict_ports=({dummy_port})")}
"""
        script_file = Path(tmpdir) / "test_conflict.sh"
        script_file.write_text(test_script_content)
        script_file.chmod(0o755)

        res = subprocess.run([str(script_file)], capture_output=True, text=True, stdin=subprocess.DEVNULL)
        require(res.returncode != 0, f"Expected non-zero exit code when ports are occupied without --force, got {res.returncode}")
        require("Existing Heimdall processes/service occupy ports" in res.stderr or "Existing Heimdall processes/service occupy ports" in res.stdout,
                f"Expected conflict prompt message in output, got stdout='{res.stdout}', stderr='{res.stderr}'")
        require("Stop/kill them to restart cleanly? [Y/n]" in res.stderr or "Stop/kill them to restart cleanly? [Y/n]" in res.stdout,
                "Expected [Y/n] confirmation prompt in output")
        require(dummy_proc.poll() is None, "Dummy process should NOT have been killed on non-interactive failure")
        print("    [+] Non-interactive run without --force rejected with prompt (PASSED)")

        # Test Case 2: Interactive rejection (user answers 'n')
        master, slave = pty.openpty()
        p_interactive_n = subprocess.Popen([str(script_file)], stdin=slave, stdout=master, stderr=master, text=True)
        os.close(slave)
        time.sleep(0.3)
        os.write(master, b"n\n")
        deadline = time.time() + 3
        while time.time() < deadline and p_interactive_n.poll() is None:
            time.sleep(0.1)
        os.close(master)
        p_interactive_n.wait()
        require(p_interactive_n.returncode != 0, "Interactive rejection with 'n' should exit non-zero")
        require(dummy_proc.poll() is None, "Dummy process should NOT have been killed when user answered 'n'")
        print("    [+] Interactive run with 'n' aborted safely (PASSED)")

        # Test Case 3: Interactive approval (user answers 'y')
        master_y, slave_y = pty.openpty()
        p_interactive_y = subprocess.Popen([str(script_file)], stdin=slave_y, stdout=master_y, stderr=master_y, text=True)
        os.close(slave_y)
        time.sleep(0.3)
        os.write(master_y, b"y\n")
        deadline = time.time() + 4
        while time.time() < deadline and p_interactive_y.poll() is None:
            time.sleep(0.1)
        os.close(master_y)
        p_interactive_y.wait()
        require(p_interactive_y.returncode == 0, f"Interactive run with 'y' failed with code {p_interactive_y.returncode}")
        time.sleep(0.5)
        require(dummy_proc.poll() is not None, "Dummy process SHOULD have been terminated when user answered 'y'")
        require(not stale_pid_file.exists(), "Stale PID file in RUN_DIR should have been deleted")
        print("    [+] Interactive run with 'y' successfully killed conflicting process and cleaned RUN_DIR (PASSED)")

        # Test Case 4: Non-interactive with --force
        dummy_proc2 = subprocess.Popen(
            [sys.executable, "-c",
             f"import socket, time; s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('127.0.0.1', {dummy_port})); s.listen(5); time.sleep(60)"]
        )
        time.sleep(0.5)
        require(dummy_proc2.poll() is None, "Second dummy process failed to start")
        dummy_pid2 = dummy_proc2.pid
        stale_pid_file2 = run_dir / "test_stale2.pid"
        stale_pid_file2.write_text(f"{dummy_pid2}\n")

        force_script = f"""#!/usr/bin/env bash
set -euo pipefail
DATA_DIR="{tmpdir}"
RUN_DIR="{run_dir}"
FORCE=true

{conflict_code.replace("conflict_ports=(49322 49323 49325 8989)", f"conflict_ports=({dummy_port})")}
"""
        script_file_force = Path(tmpdir) / "test_conflict_force.sh"
        script_file_force.write_text(force_script)
        script_file_force.chmod(0o755)

        res_force = subprocess.run([str(script_file_force)], capture_output=True, text=True, stdin=subprocess.DEVNULL)
        require(res_force.returncode == 0, f"Expected 0 exit code with FORCE=true, got {res_force.returncode}: {res_force.stderr}")
        time.sleep(0.5)
        require(dummy_proc2.poll() is not None, "Dummy process 2 should have been killed with --force")
        require(not stale_pid_file2.exists(), "Stale PID file 2 should have been deleted with --force")
        print("    [+] Non-interactive run with --force automatically resolved conflict (PASSED)")

    print("[+] All port conflict & loop detection behavioral tests PASSED")


def main() -> None:
    print("=== Testing Port Conflict Detection & Dual-Stack IPv6 Support (CT-17) ===")
    test_static_checks()
    test_dev_proxy_dual_stack()
    test_conflict_detection_behavior()
    print("=== ALL CT-17 VERIFICATION TESTS PASSED SUCCESSFULLY! ===")


if __name__ == "__main__":
    main()
