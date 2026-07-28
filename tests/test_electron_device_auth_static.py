#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(rel: str) -> str:
    return (ROOT / rel).read_text()


def test_electron_device_auth_static_contract():
    main = read("src/ui/electron/main.cts")
    preload = read("src/ui/electron/preload.cts")
    gate = read("src/ui/components/ElectronDeviceAuthGate.tsx")

    # safeStorage-backed keychain path (ELDA-5 AC3)
    assert "safeStorage.encryptString" in main
    assert "safeStorage.decryptString" in main
    assert "device-authorization-token.bin" in main

    # Clickable verification link opens in the system browser (ELDA-5 AC1)
    assert "shell.openExternal" in main
    assert "heimdall-device-auth:open-external" in main
    assert "openExternal" in preload
    assert "electron-device-auth-open-browser" in gate

    # Public authorize/token poll lifecycle (ELDA-5 AC1/AC2/AC4)
    assert "'/device/authorize'" in gate
    assert "'/device/token'" in gate
    assert "Retry-After" in gate
    assert "slow_down" in gate
    assert "denied" in gate
    assert "expired" in gate
    assert "electron-device-auth-retry" in gate

    # Bearer-only API use after approval (ELDA-5 AC3)
    assert "Authorization" in gate
    assert "Bearer ${token}" in gate
    assert "credentials: 'omit'" in gate

    # API base defaults to the public Hub API, not the browser/outpost/dev-proxy URL.
    assert "HEIMDALL_HUB_API_URL" in main
    assert "HEIMDALL_HUB_URL" in main
    assert "http://127.0.0.1:8081" in main


def test_no_client_side_authentik_header_injection_static_guard():
    electron_sources = "\n".join(p.read_text() for p in (ROOT / "src/ui/electron").glob("*.cts"))
    assert "X-authentik" not in electron_sources
    assert "authentik" not in electron_sources.lower()


if __name__ == "__main__":
    test_electron_device_auth_static_contract()
    test_no_client_side_authentik_header_injection_static_guard()
    print("PASS: electron device auth static contract")
