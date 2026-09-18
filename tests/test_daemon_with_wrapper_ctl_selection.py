#!/usr/bin/env python3
"""Static guard: the flake bridge app pins the SAME-BUILD ham-ctl + ham-pty-host.

The old `daemon-with-wrapper` dev script (which pinned HAM_CTL and refreshed a
result-ctl symlink) was removed with the wrapper/tmux runtime. Its replacement is
`apps.bridge`: a generated ham-bridge launcher that exports the same-build
ham-ctl and ham-pty-host bins into the agent environment so a Bridge-launched
agent bootstraps against the matching build. This guard locks that pinning and
checks that ctl help still documents the task-chains/artifacts/chat surfaces.
"""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
FLAKE = (ROOT / 'flake.nix').read_text(encoding='utf-8')
CTL = "\n".join(p.read_text(encoding='utf-8', errors='ignore') for p in (ROOT / 'src' / 'ctl').rglob('*.odin'))

checks = [
    ('bridge app pins same-build ham-ctl',
     'HEIMDALL_HAM_CTL_BIN="${self.packages.${system}.ham-ctl}/bin/ham-ctl"' in FLAKE),
    ('bridge app pins same-build ham-pty-host',
     'HEIMDALL_HAM_PTY_HOST_BIN="${self.packages.${system}.ham-pty-host}/bin/ham-pty-host"' in FLAKE),
    ('bridge app selects the pty-host runtime',
     'HEIMDALL_BRIDGE_PTY_HOST="true"' in FLAKE),
    ('bridge app execs the same-build ham-bridge',
     'exec "${self.packages.${system}.ham-bridge}/bin/ham-bridge"' in FLAKE),
    ('ctl help documents task-chains create --kind',
     'task-chains create --title <title>' in CTL and '--kind <kind>' in CTL),
    ('ctl help documents artifact commands',
     'artifacts create --name <name>' in CTL and 'artifacts <list|create|show' in CTL),
    ('ctl help documents chat send-to-user',
     'send-to-user' in CTL),
]

failed = [name for name, ok in checks if not ok]
if failed:
    print('FAILED:')
    for name in failed:
        print('-', name)
    sys.exit(1)

print('TEST PASSED: bridge app pins same-build ham-ctl/ham-pty-host and ctl help covers task-chains/artifacts/chat')
