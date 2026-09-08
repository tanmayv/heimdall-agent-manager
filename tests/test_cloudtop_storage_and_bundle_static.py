#!/usr/bin/env python3
"""Static regression tests for CT-5 & CT-6: Storage Migration, LOAS Monitor & Standalone Binary Package."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]

def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"[-] FAIL: {message}")
        sys.exit(1)

def main() -> None:
    # 1. Check persistence hygiene & 0600 file permissions in Hub (CT-5)
    wiring_odin = (ROOT / "src/hub/app/wiring.odin").read_text(encoding="utf-8")
    require("os.Permissions{.Read_User, .Write_User}" in wiring_odin, "hub wiring must enforce 0600 permissions on database file")
    require("%s-wal" in wiring_odin, "hub wiring must chmod 0600 wal sidecar")
    require("%s-shm" in wiring_odin, "hub wiring must chmod 0600 shm sidecar")

    hub_main = (ROOT / "src/hub/main.odin").read_text(encoding="utf-8")
    require("is_snapshot_command" in hub_main, "hub main must define is_snapshot_command")
    require("run_snapshot_command" in hub_main, "hub main must implement snapshot export and restore")
    require("--cloudtop" in hub_main, "hub main must support --cloudtop flag")
    require(".local/share/heimdall/hub.db" in hub_main, "hub main --cloudtop must target ~/.local/share/heimdall/hub.db")

    snapshot_sh = (ROOT / "scripts/snapshot-hub.sh").read_text(encoding="utf-8")
    require("chmod 0600" in snapshot_sh, "snapshot script must enforce 0600 on snapshot archives")
    require("chmod 0700" in snapshot_sh, "snapshot script must enforce 0700 on snapshots directory")
    require("export" in snapshot_sh and "restore" in snapshot_sh, "snapshot script must support export and restore")

    # 2. Check LOAS/gcert monitoring and signal handling in Bridge (CT-5)
    gcert_odin = (ROOT / "src/bridge/gcert_monitor.odin").read_text(encoding="utf-8")
    require("bridge_gcert_monitor_start" in gcert_odin, "bridge must implement bridge_gcert_monitor_start")
    require("bridge_gcert_is_expired" in gcert_odin, "bridge must implement bridge_gcert_is_expired")
    require("bridge_gcert_check_once" in gcert_odin, "bridge must implement bridge_gcert_check_once")
    require("gcertstatus" in gcert_odin, "bridge must monitor gcertstatus")
    require("LOAS/gcert credentials renewed" in gcert_odin, "bridge must log and re-arm on gcert renewal")

    hub_client_odin = (ROOT / "src/bridge/hub_runtime_client.odin").read_text(encoding="utf-8")
    require("bridge_gcert_is_expired" in hub_client_odin, "bridge launch_agent must check bridge_gcert_is_expired")
    require("LOAS/gcert credentials expired" in hub_client_odin, "bridge launch_agent must reject spawning when gcert is expired")

    bridge_main = (ROOT / "src/bridge/main.odin").read_text(encoding="utf-8")
    require("bridge_gcert_monitor_start()" in bridge_main, "bridge main must start gcert monitor")
    require("SIGINT" in bridge_main and "SIGTERM" in bridge_main, "bridge main must trap SIGINT and SIGTERM")
    require("bridge_signal_handler" in bridge_main, "bridge main must define bridge_signal_handler")

    # 3. Check systemd --user service and linger script (CT-5)
    systemd_svc = (ROOT / "systemd/heimdall.service").read_text(encoding="utf-8")
    require("KillMode=control-group" in systemd_svc, "systemd service must specify KillMode=control-group")
    require("TimeoutStopSec=10" in systemd_svc, "systemd service must specify TimeoutStopSec=10")
    require("Restart=on-failure" in systemd_svc, "systemd service must specify Restart=on-failure")

    install_svc_sh = (ROOT / "scripts/install-systemd-service.sh").read_text(encoding="utf-8")
    require("enable-linger" in install_svc_sh, "install-service script must enable systemd linger")
    require("systemctl --user daemon-reload" in install_svc_sh, "install-service script must reload systemd daemon")

    # 4. Check standalone package script and Flake app (CT-6)
    package_sh = (ROOT / "scripts/package-cloudtop-bundle.sh").read_text(encoding="utf-8")
    require("patchelf" in package_sh, "package script must utilize patchelf for de-Nixification")
    require("/lib64/ld-linux-x86-64.so.2" in package_sh, "package script must patch glibc interpreter")
    require("heimdall-cloudtop-bundle.tar.gz" in package_sh, "package script must create tarball")
    require("start.sh" in package_sh and "stop.sh" in package_sh, "package script must include start.sh and stop.sh")

    flake_nix = (ROOT / "flake.nix").read_text(encoding="utf-8")
    require("cloudtop = {" in flake_nix, "flake.nix must define cloudtop app")

    print("ALL CT-5 & CT-6 STATIC CHECKS PASSED")

if __name__ == "__main__":
    main()
