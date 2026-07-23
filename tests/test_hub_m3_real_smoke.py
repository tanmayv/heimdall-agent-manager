#!/usr/bin/env python3
"""M3 smoke: run Phase 5 + Phase 6 real-binary bridge/agent support checks."""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main() -> None:
    env = os.environ.copy()
    for script in [
        ROOT / "tests" / "test_hub_phase5_real_smoke.py",
        ROOT / "tests" / "test_hub_phase6_real_smoke.py",
    ]:
        subprocess.run([sys.executable, str(script)], cwd=ROOT, env=env, check=True)
    print("PASS: hub M3 real smoke")


if __name__ == "__main__":
    main()
