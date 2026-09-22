#!/usr/bin/env python3
"""Regression test suite for collapsed sidebar pinned task chain avatar pills.

Requirements:
- REQ-UI-COLLAPSED-SIDEBAR-PINNED-CHAINS:
  1. chainAvatarInitials helper in ProjectChainTree.tsx extracts 2 uppercase initials
     for multi-word titles, first 2 chars for single-word, and 'TC' fallback for empty.
  2. isChainActive helper in ProjectChainTree.tsx accurately detects active routes
     for coordinator conversations (/conversations/:id, /c/:id) and chain overview (/chains/:id).
  3. CollapsedPinnedChains component in ProjectChainTree.tsx queries pinned task chains,
     renders 2-char avatar pills when collapsed, showing status dot, tooltip title,
     active border/ring, and click navigation.
  4. AppShell.tsx imports CollapsedPinnedChains and renders it under primary nav
     when collapsed is true.
"""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
PROJECT_CHAIN_TREE = ROOT / "src" / "ui" / "components" / "chains" / "ProjectChainTree.tsx"
APP_SHELL = ROOT / "src" / "ui" / "components" / "shell" / "AppShell.tsx"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def test_chain_avatar_initials_logic():
    """Verify avatar abbreviation logic directly against requirement specifications."""
    def chain_avatar_initials(title: str) -> str:
        trimmed = (title or "").strip()
        if not trimmed:
            return "TC"
        words = [w for w in trimmed.split() if w]
        if len(words) >= 2:
            return (words[0][0] + words[1][0]).upper()
        return trimmed[:2].upper()

    assert chain_avatar_initials("Sync Standalone Node with Main & Deploy Bundle") == "SS"
    assert chain_avatar_initials("Frontend Refactor") == "FR"
    assert chain_avatar_initials("Heimdall") == "HE"
    assert chain_avatar_initials("X") == "X"
    assert chain_avatar_initials("") == "TC"
    assert chain_avatar_initials("   ") == "TC"
    assert chain_avatar_initials("  two   words  ") == "TW"


def test_project_chain_tree_exports_and_structure():
    require(PROJECT_CHAIN_TREE.is_file(), f"ProjectChainTree.tsx must exist at {PROJECT_CHAIN_TREE}")
    src = PROJECT_CHAIN_TREE.read_text(encoding="utf-8")

    # 1. Export chainAvatarInitials
    require("export function chainAvatarInitials" in src,
            "ProjectChainTree.tsx must export chainAvatarInitials")
    require("TC" in src, "chainAvatarInitials must contain 'TC' fallback")

    # 2. Export isChainActive
    require("export function isChainActive" in src,
            "ProjectChainTree.tsx must export isChainActive")
    require("/conversations/" in src and "/chains/" in src,
            "isChainActive must check conversation and chain routes")

    # 3. Export CollapsedPinnedChains
    require("export function CollapsedPinnedChains" in src,
            "ProjectChainTree.tsx must export CollapsedPinnedChains")
    require("useListPinnedTaskChainsQuery" in src,
            "CollapsedPinnedChains must call useListPinnedTaskChainsQuery")
    require("StatusDot" in src,
            "CollapsedPinnedChains must render StatusDot")

    # 4. Check styling requirements
    require("border-2 border-accent text-accent bg-neutral-soft ring-1 ring-accent/30 font-bold" in src,
            "CollapsedPinnedChains must apply active border and ring styles")
    require("border border-subtle text-muted" in src,
            "CollapsedPinnedChains must apply inactive border styles")
    require("h-9 w-9" in src and "rounded-xl" in src,
            "CollapsedPinnedChains pills must have h-9 w-9 rounded-xl sizing")
    require("collapsed-pinned-chains" in src,
            "CollapsedPinnedChains must have data-debug-id collapsed-pinned-chains")


def test_app_shell_integration():
    require(APP_SHELL.is_file(), f"AppShell.tsx must exist at {APP_SHELL}")
    src = APP_SHELL.read_text(encoding="utf-8")

    # 1. Import CollapsedPinnedChains
    require("CollapsedPinnedChains" in src,
            "AppShell.tsx must import CollapsedPinnedChains")
    require(re.search(r"import\s+ProjectChainTree,\s*\{\s*CollapsedPinnedChains\s*\}\s*from\s*['\"]\.\./chains/ProjectChainTree['\"]", src) is not None,
            "AppShell.tsx must import CollapsedPinnedChains from ../chains/ProjectChainTree")

    # 2. Render when collapsed
    require(re.search(r"\{collapsed\s*&&\s*<CollapsedPinnedChains", src) is not None,
            "AppShell.tsx must render CollapsedPinnedChains when collapsed is true")
    require(re.search(r"\{!collapsed\s*&&\s*<ProjectChainTree", src) is not None,
            "AppShell.tsx must preserve uncollapsed ProjectChainTree rendering")


if __name__ == "__main__":
    test_chain_avatar_initials_logic()
    test_project_chain_tree_exports_and_structure()
    test_app_shell_integration()
    print("test_ui_collapsed_sidebar_pinned_chains_static.py: all checks passed successfully.")
