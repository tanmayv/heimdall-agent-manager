#!/usr/bin/env python3
"""
Static verification suite for Theme Migration B3 & B4:
[Theme/Migration] Migrate TaskChain, Cards, Memory, Viewers to semantic tokens and author static color regression tests.

Validates:
- REQ-THEME-MIGRATE-B3: TaskChainOverview, TaskChainsPage, TaskCommentsThread, CardsPanel, MemoryDetailPage, MemoryPage, memoryScope migration to semantic tokens.
- REQ-THEME-MIGRATE-B4: ArtifactViewer, ProjectFilesPanel, InstanceRunDirPanel, ShellJobsPanel migration to semantic tokens.
- REQ-THEME-TEST: Static regression test suite asserting zero raw color utilities across all B3 and B4 components.
"""

from pathlib import Path
import re
import unittest

REPO_ROOT = Path(__file__).resolve().parent.parent

B3_B4_FILES = [
    "src/ui/components/taskchain/TaskChainOverview.tsx",
    "src/ui/components/taskchain/TaskChainsPage.tsx",
    "src/ui/components/taskchain/TaskCommentsThread.tsx",
    "src/ui/components/cards/CardsPanel.tsx",
    "src/ui/components/memory/MemoryDetailPage.tsx",
    "src/ui/components/memory/MemoryPage.tsx",
    "src/ui/components/memory/memoryScope.tsx",
    "src/ui/components/ArtifactViewer.tsx",
    "src/ui/components/chat/ProjectFilesPanel.tsx",
    "src/ui/components/chat/InstanceRunDirPanel.tsx",
    "src/ui/components/chat/ShellJobsPanel.tsx",
]

RAW_COLOR_PATTERNS = [
    re.compile(r"\btext-(zinc|slate|neutral|stone|gray|sky|blue|red|amber|emerald|green|indigo|purple|rose|yellow)-\d+"),
    re.compile(r"\bbg-(zinc|slate|neutral|stone|gray|sky|blue|red|amber|emerald|green|indigo|purple|rose|yellow)-\d+"),
    re.compile(r"\bborder-(zinc|slate|neutral|stone|gray|sky|blue|red|amber|emerald|green|indigo|purple|rose|yellow)-\d+"),
    re.compile(r"(#090909|#141414|#1c1c1c|#121212|#27272a|#18181b|#111827)"),
    re.compile(r"\bborder-white/\d+"),
    re.compile(r"\bbg-white/\d+"),
    re.compile(r"\btext-white/\d+"),
    re.compile(r"\btext-white\b"),
    re.compile(r"\bbg-white\b"),
    re.compile(r"\bborder-white\b"),
]


class TestUiThemeTokensStatic(unittest.TestCase):

    def setUp(self):
        self.contents = {
            rel_path: (REPO_ROOT / rel_path).read_text(encoding="utf-8")
            for rel_path in B3_B4_FILES
        }

    def test_zero_raw_color_utility_regressions_b3_b4(self):
        """Assert zero raw color utilities remain across all B3 and B4 component files."""
        violations = []
        for rel_path, content in self.contents.items():
            for line_idx, line in enumerate(content.splitlines(), start=1):
                for pattern in RAW_COLOR_PATTERNS:
                    match = pattern.search(line)
                    if match:
                        violations.append(
                            f"{rel_path}:{line_idx}: found '{match.group(0)}' in line: {line.strip()}"
                        )
        self.assertEqual(
            violations,
            [],
            f"Found {len(violations)} raw color regressions:\n" + "\n".join(violations),
        )

    def test_task_chain_overview_semantic_tokens(self):
        """Verify TaskChainOverview uses semantic design tokens."""
        content = self.contents["src/ui/components/taskchain/TaskChainOverview.tsx"]
        self.assertIn("bg-canvas text-primary", content)
        self.assertIn("border-subtle bg-surface", content)
        self.assertIn("border border-subtle bg-surface-raised", content)
        self.assertIn("text-muted hover:text-primary", content)
        self.assertIn("bg-neutral-soft", content)
        self.assertIn("bg-accent text-accent-fg", content)
        self.assertIn("bg-surface-overlay/80 backdrop-blur-sm", content)

    def test_task_chains_page_semantic_tokens(self):
        """Verify TaskChainsPage uses semantic design tokens."""
        content = self.contents["src/ui/components/taskchain/TaskChainsPage.tsx"]
        self.assertIn("border-subtle bg-surface", content)
        self.assertIn("border border-subtle bg-surface-raised", content)
        self.assertIn("bg-neutral-soft", content)
        self.assertIn("text-muted", content)
        self.assertIn("text-primary", content)

    def test_task_comments_thread_semantic_tokens(self):
        """Verify TaskCommentsThread uses semantic design tokens."""
        content = self.contents["src/ui/components/taskchain/TaskCommentsThread.tsx"]
        self.assertIn("border border-subtle bg-surface", content)
        self.assertIn("border-subtle bg-surface-raised", content)
        self.assertIn("text-primary", content)
        self.assertIn("text-muted", content)
        self.assertIn("text-accent", content)

    def test_cards_panel_semantic_tokens(self):
        """Verify CardsPanel uses semantic design tokens."""
        content = self.contents["src/ui/components/cards/CardsPanel.tsx"]
        self.assertIn("border-subtle bg-surface", content)
        self.assertIn("border border-subtle bg-surface-raised", content)
        self.assertIn("text-muted", content)
        self.assertIn("bg-neutral-soft", content)
        self.assertIn("border-accent/30 bg-accent-soft", content)
        self.assertIn("text-primary", content)

    def test_memory_detail_page_semantic_tokens(self):
        """Verify MemoryDetailPage uses semantic design tokens."""
        content = self.contents["src/ui/components/memory/MemoryDetailPage.tsx"]
        self.assertIn("border border-subtle bg-surface-raised", content)
        self.assertIn("border border-subtle bg-surface", content)
        self.assertIn("text-muted", content)
        self.assertIn("text-primary", content)

    def test_memory_page_semantic_tokens(self):
        """Verify MemoryPage uses semantic design tokens."""
        content = self.contents["src/ui/components/memory/MemoryPage.tsx"]
        self.assertIn("border border-subtle bg-surface-raised", content)
        self.assertIn("border border-subtle bg-surface", content)
        self.assertIn("text-muted", content)
        self.assertIn("text-primary", content)

    def test_memory_scope_semantic_tokens(self):
        """Verify memoryScope re-exports ScopeField cleanly without raw color utilities."""
        content = self.contents["src/ui/components/memory/memoryScope.tsx"]
        self.assertIn("ScopeField", content)

    def test_artifact_viewer_semantic_tokens(self):
        """Verify ArtifactViewer uses semantic design tokens."""
        content = self.contents["src/ui/components/ArtifactViewer.tsx"]
        self.assertIn("border-subtle bg-surface", content)
        self.assertIn("border-subtle bg-surface-raised", content)
        self.assertIn("text-muted", content)
        self.assertIn("text-primary", content)
        self.assertIn("border-accent", content)

    def test_project_files_panel_semantic_tokens(self):
        """Verify ProjectFilesPanel uses semantic design tokens."""
        content = self.contents["src/ui/components/chat/ProjectFilesPanel.tsx"]
        self.assertIn("border-subtle bg-surface", content)
        self.assertIn("border border-subtle bg-surface-raised", content)
        self.assertIn("text-muted", content)
        self.assertIn("text-primary", content)
        self.assertIn("bg-accent", content)
        self.assertIn("text-accent-fg", content)

    def test_instance_run_dir_panel_semantic_tokens(self):
        """Verify InstanceRunDirPanel uses semantic design tokens."""
        content = self.contents["src/ui/components/chat/InstanceRunDirPanel.tsx"]
        self.assertIn("border-subtle bg-surface", content)
        self.assertIn("border border-subtle bg-surface-raised", content)
        self.assertIn("text-muted", content)
        self.assertIn("text-primary", content)

    def test_shell_jobs_panel_semantic_tokens(self):
        """Verify ShellJobsPanel uses semantic design tokens."""
        content = self.contents["src/ui/components/chat/ShellJobsPanel.tsx"]
        self.assertIn("border-subtle bg-surface", content)
        self.assertIn("border border-subtle bg-surface-raised", content)
        self.assertIn("text-muted", content)
        self.assertIn("text-primary", content)
        self.assertIn("text-accent", content)


if __name__ == "__main__":
    unittest.main()
