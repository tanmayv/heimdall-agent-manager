#!/usr/bin/env python3
"""
Static regression test for REQ-UI-MOBILE-CHAIN-OVERFLOW-1:
Verifies mobile responsiveness & zero-overflow layout in TaskChainOverview, PageShell,
TaskChainsPage, and ChainHeader to prevent horizontal scrolling on mobile viewports.
"""

import os
import re
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

class TestUiMobileChainOverflowStatic(unittest.TestCase):
    def test_pageshell_actions_and_title_wrapping(self):
        pageshell_path = os.path.join(REPO_ROOT, "src", "ui", "components", "ui", "composites", "PageShell.tsx")
        with open(pageshell_path, "r", encoding="utf-8") as f:
            content = f.read()

        # actions container must not have hard shrink-0 without flex-wrap on mobile
        self.assertIn("flex flex-wrap items-center gap-2 max-w-full sm:shrink-0", content)
        # title must have break-words to avoid blowing out container
        self.assertIn("text-display text-primary break-words", content)

    def test_pageshell_css_bounds(self):
        css_path = os.path.join(REPO_ROOT, "src", "ui", "components", "ui", "composites", "PageShell.css")
        with open(css_path, "r", encoding="utf-8") as f:
            content = f.read()

        self.assertIn(".ui-pageshell {", content)
        self.assertIn("max-width: 100%;", content)
        self.assertIn(".ui-pageshell-container {", content)

    def test_taskchain_overview_container_and_actions(self):
        tco_path = os.path.join(REPO_ROOT, "src", "ui", "components", "taskchain", "TaskChainOverview.tsx")
        with open(tco_path, "r", encoding="utf-8") as f:
            content = f.read()

        # Root container must enforce zero horizontal overflow
        self.assertIn('data-debug-id="taskchain-overview"', content)
        self.assertIn('overflow-x-hidden', content)
        self.assertIn('max-w-full', content)
        self.assertIn('min-w-0', content)

        # PageShell actions slot must allow flex-wrap on FleetSlotChips and status badge
        self.assertIn('actions={\n          <div className="flex flex-wrap items-center gap-2 max-w-full">', content)

        # TaskCard contextual action buttons must allow flex-wrap
        self.assertIn('className="flex flex-wrap items-center gap-1.5"', content)

        # Task list header must wrap
        self.assertIn('className="flex flex-wrap items-center justify-between gap-2 px-4 py-3 sm:px-6"', content)

    def test_taskchains_page_container(self):
        tcp_path = os.path.join(REPO_ROOT, "src", "ui", "components", "taskchain", "TaskChainsPage.tsx")
        with open(tcp_path, "r", encoding="utf-8") as f:
            content = f.read()

        self.assertIn('className="h-full w-full max-w-full min-w-0 overflow-x-hidden"', content)

    def test_chain_header_wrapping(self):
        ch_path = os.path.join(REPO_ROOT, "src", "ui", "components", "chat", "ChainHeader.tsx")
        with open(ch_path, "r", encoding="utf-8") as f:
            content = f.read()

        self.assertIn('data-debug-id="chain-header"', content)
        self.assertIn('flex-wrap', content)
        self.assertIn('max-w-full', content)

if __name__ == "__main__":
    unittest.main()
