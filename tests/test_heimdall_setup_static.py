#!/usr/bin/env python3
"""Regression: heimdall-setup detect/report command exists and is safe-by-design.

Feature (task_18c70887b39cdf84): an idempotent per-harness readiness check that
DETECTS install/auth/config-writability posture and prints wiring guidance, without
installing binaries, fabricating credentials, or overwriting read-only managed config.
"""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
SETUP = (ROOT / 'src/ctl/setup.odin').read_text(encoding='utf-8')
MAIN = (ROOT / 'src/ctl/main.odin').read_text(encoding='utf-8')


def require(cond: bool, msg: str) -> None:
    if not cond:
        print(f'FAILED: {msg}')
        sys.exit(1)


# Command is wired into ctl dispatch.
require('cmd[0] == "setup"' in MAIN, 'main must dispatch the setup command')
require('ctl_setup_command(' in MAIN, 'main must call ctl_setup_command')

# Core procs exist.
for sym in [
    'ctl_setup_command ::',
    'setup_known_harnesses ::',
    'setup_bin_on_path ::',
    'setup_is_symlink ::',
    'setup_path_exists ::',
]:
    require(sym in SETUP, f'setup.odin must define {sym}')

# Covers all four harnesses.
for h in ['"pi"', '"antigravity"', '"claude"', '"codex"']:
    require(h in SETUP, f'setup must know about harness {h}')

# Detection reports install + read-only-symlink overlay signal + JSON mode.
require('installed' in SETUP, 'report must include install status')
require('config_readonly_symlink' in SETUP and 'needs_overlay' in SETUP,
        'report must flag read-only managed config that needs an overlay')
require('--json' in SETUP, 'setup must support --json machine-readable output')

# Safe-by-design: never installs / never fabricates creds / never overwrites managed cfg.
require('detect-only' in SETUP, 'setup must state it is detect-only')
lower = SETUP.lower()
require('never overwrite' in lower or 'not overwrite' in lower or 'overlay, not overwrite' in lower,
        'setup must document not overwriting read-only managed config')

print('HEIMDALL SETUP STATIC TEST PASSED')
