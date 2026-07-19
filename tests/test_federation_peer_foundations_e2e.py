#!/usr/bin/env python3
"""Retired pre-bridge federation peer-foundations E2E.

This test validated direct-daemon peer management primitives that no longer
exist as active functionality in federation v2. Those behaviors are now either
410 bridge-migration shims or handled by ham-bridge itself.

Active bridge-era coverage:
- tests/test_federation_transport_e2e.py (410 retirement/compat checks)
- tests/test_federation_peer_backend_static.py
- tests/test_bridge_federation_two_homes_e2e.py
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
for rel in [
    "tests/test_federation_transport_e2e.py",
    "tests/test_federation_peer_backend_static.py",
    "tests/test_bridge_federation_two_homes_e2e.py",
]:
    if not (ROOT / rel).exists():
        raise SystemExit(f"missing bridge-era coverage: {rel}")

print("federation_peer_foundations_e2e: retired (direct-daemon peer foundations removed in bridge v2)")
