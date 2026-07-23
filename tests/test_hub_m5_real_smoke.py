#!/usr/bin/env python3
"""M5 smoke: run Phase 11 real-binary content API checks."""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main() -> None:
    env = os.environ.copy()
    subprocess.run([sys.executable, str(ROOT / "tests" / "test_hub_phase11_real_smoke.py")], cwd=ROOT, env=env, check=True)
    print("PASS: hub M5 real smoke")


if __name__ == "__main__":
    main()
