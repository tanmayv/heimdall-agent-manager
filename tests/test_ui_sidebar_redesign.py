#!/usr/bin/env python3
"""Locks in the modern sidebar redesign:
- icon rail replaces the three text buttons for surface switching
- chain rows carry status-based color accents
- badge on attention rail uses ring/pill positioning
"""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "src/ui/components/App.tsx"


def require(cond: bool, msg: str) -> None:
    if not cond:
        print(f"[-] FAIL: {msg}")
        sys.exit(1)


def main() -> None:
    app = APP.read_text()

    # --- Icon rail replaces the three text buttons
    require('function SurfaceRail(' in app, 'SurfaceRail component missing')
    require('data-debug-id="surface-rail"' in app, 'surface-rail debug id missing')
    require('data-debug-id={`nav-${item.key}-btn`}' in app, 'rail buttons must render nav-<key>-btn debug ids')
    for key in ['home', 'attention', 'settings']:
        require(f"key: '{key}'" in app, f'rail item for {key} missing')
    require('nav-attention-badge' in app, 'attention rail badge missing')
    # Old three-in-a-row nav must be gone
    require('nav className="px-2 py-2 border-b border-white/10 flex gap-1"' not in app, 'legacy horizontal nav bar must be removed')

    # --- Chain color coding
    require('function chainStatusAccent(' in app, 'chainStatusAccent helper missing')
    for token in ['bg-emerald-400', 'bg-amber-400', 'bg-sky-400', 'bg-violet-400', 'bg-teal-400']:
        require(token in app, f'accent color {token} missing from status map')
    require('data-status={chain.status}' in app, 'chain buttons must expose data-status for tests/styling')
    require('accent.border' in app, 'chain button must apply left accent border')
    require('accent.dot' in app, 'chain button must render a colored status dot')

    # Collapsible projects with persisted state
    require('sidebar-project-toggle-' in app, 'projects must be collapsible with an explicit toggle affordance')
    require('collapsedProjectIds' in app, 'collapsed-project state must be tracked')
    require('heimdall.sidebar.collapsedProjects' in app, 'collapsed-project state must persist to localStorage')

    # Completed chains are hidden from the sidebar list
    require('function isChainCompleted' in app, 'completed-chain filter helper missing')
    require('!isChainCompleted(chain)' in app, 'sidebar must exclude completed chains')

    # --- Project card cleanup
    require('sidebar-project-' in app, 'sidebar project debug ids preserved')
    require('sidebar-chain-' in app, 'sidebar chain debug ids preserved')
    require('sidebar-new-chain-btn-' in app, 'sidebar new-chain button preserved')
    require('home-new-project-btn' in app, 'sidebar new-project button preserved')

    print('UI SIDEBAR REDESIGN TEST PASSED')


if __name__ == '__main__':
    main()
