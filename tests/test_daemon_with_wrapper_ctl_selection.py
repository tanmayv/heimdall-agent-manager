#!/usr/bin/env python3
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
FLAKE = (ROOT / 'flake.nix').read_text(encoding='utf-8')
CTL = (ROOT / 'src/ctl/main.odin').read_text(encoding='utf-8')

checks = [
    ('daemon-with-wrapper pins same-build ham-ctl', 'HAM_CTL="${self.packages.${system}.ham-ctl}/bin/ham-ctl"' in FLAKE),
    ('daemon-with-wrapper refreshes legacy result-ctl symlink', 'refreshed ./result-ctl -> $HAM_CTL_DIR' in FLAKE),
    ('daemon-with-wrapper rewrites wrapper.ham_ctl_bin in generated config', 'print "ham_ctl_bin = \\\"" ctl "\\\""' in FLAKE),
    ('ctl help documents task-chains create --kind', 'task-chains create --token <token> [--project-id <id>] --kind <kind>' in CTL),
    ('ctl help documents artifact commands', 'artifacts create --token <token> --file <path>' in CTL and 'artifacts delete --token <token> --artifact-id <art_...|artifact://art_...>' in CTL),
]

failed = [name for name, ok in checks if not ok]
if failed:
    print('FAILED:')
    for name in failed:
        print('-', name)
    sys.exit(1)

print('TEST PASSED: daemon-with-wrapper pins same-build ham-ctl and ctl help covers --kind/artifacts')
