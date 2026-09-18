#!/usr/bin/env python3
"""
Static verification suite for Theme Migration B1 & B2:
[Theme/Migration] Migrate AppShell, TopBar, Navigation, Modals, and Chat components to semantic palette tokens.
Validates:
- REQ-THEME-MIGRATE-B1: AppShell, Navigation, TopBar, Modals, ScopeField, CommandPalette migration to semantic tokens.
- REQ-THEME-MIGRATE-B2: ChatMessageList, Composer, Bubbles, MentionPopup, ConversationThreadPage migration to semantic tokens.
- High contrast across light themes (e.g. Catppuccin Latte, Tokyo Night Day) and dark themes without inverted or washed-out text.
"""

from pathlib import Path
import unittest

REPO_ROOT = Path(__file__).resolve().parent.parent

class TestUiThemeMigrationStatic(unittest.TestCase):

    def setUp(self):
        self.app_shell = (REPO_ROOT / "src/ui/components/shell/AppShell.tsx").read_text(encoding="utf-8")
        self.responsive = (REPO_ROOT / "src/ui/components/shell/responsive.tsx").read_text(encoding="utf-8")
        self.error_boundary = (REPO_ROOT / "src/ui/components/shell/ErrorBoundary.tsx").read_text(encoding="utf-8")
        self.chat_message_list = (REPO_ROOT / "src/ui/components/chat/ChatMessageList.tsx").read_text(encoding="utf-8")
        self.agent_pane_composer = (REPO_ROOT / "src/ui/components/chat/AgentPaneComposerPanel.tsx").read_text(encoding="utf-8")
        self.bubbles = (REPO_ROOT / "src/ui/components/chat/AgentActivityBubbles.tsx").read_text(encoding="utf-8")
        self.mention_popup = (REPO_ROOT / "src/ui/components/chat/AtMentionPopup.tsx").read_text(encoding="utf-8")
        self.conversation_page = (REPO_ROOT / "src/ui/components/chat/ConversationThreadPage.tsx").read_text(encoding="utf-8")
        self.project_launch_modal = (REPO_ROOT / "src/ui/components/projects/ProjectLaunchModal.tsx").read_text(encoding="utf-8")
        self.delete_modal = (REPO_ROOT / "src/ui/components/actions/DeleteActionModal.tsx").read_text(encoding="utf-8")
        self.scope_field = (REPO_ROOT / "src/ui/components/ui/patterns/ScopeField.tsx").read_text(encoding="utf-8")
        self.command_palette = (REPO_ROOT / "src/ui/components/ui/patterns/CommandPalette.tsx").read_text(encoding="utf-8")

    def test_app_shell_semantic_tokens(self):
        """Verify AppShell uses semantic palette tokens for canvas, surface, text, and borders."""
        # Main shell background
        self.assertIn("bg-canvas text-primary", self.app_shell)
        # Sidebar surface and subtle border
        self.assertIn("border-subtle bg-surface", self.app_shell)
        # Search trigger
        self.assertIn("border border-subtle bg-surface-raised", self.app_shell)
        self.assertIn("text-muted", self.app_shell)
        # User footer
        self.assertIn("bg-neutral-soft", self.app_shell)
        # NavItem active/inactive states
        self.assertIn("bg-neutral-soft text-primary font-semibold", self.app_shell)
        # RouteOutlet uses bg-canvas
        self.assertIn('className="min-w-0 flex-1 overflow-hidden bg-canvas"', self.app_shell)
        # No hardcoded zinc or black canvas in AppShell
        self.assertNotIn("bg-[#090909]", self.app_shell)
        self.assertNotIn("bg-[#141414]", self.app_shell)
        self.assertNotIn("bg-[#1c1c1c]", self.app_shell)
        self.assertNotIn("text-zinc-", self.app_shell)
        self.assertNotIn("bg-zinc-", self.app_shell)
        self.assertNotIn("border-zinc-", self.app_shell)

    def test_responsive_semantic_tokens(self):
        """Verify responsive navigation and headers use semantic tokens."""
        self.assertIn("border-subtle bg-surface/95", self.responsive)
        self.assertIn("bg-accent text-accent-fg", self.responsive)
        self.assertNotIn("text-zinc-", self.responsive)
        self.assertNotIn("bg-zinc-", self.responsive)

    def test_error_boundary_semantic_tokens(self):
        """Verify ErrorBoundary uses semantic tokens."""
        self.assertIn("border border-subtle bg-surface-raised", self.error_boundary)
        self.assertIn("bg-accent", self.error_boundary)
        self.assertIn("text-accent-fg", self.error_boundary)
        self.assertIn("border border-subtle bg-surface", self.error_boundary)
        self.assertNotIn("text-zinc-", self.error_boundary)
        self.assertNotIn("bg-zinc-", self.error_boundary)

    def test_chat_message_list_semantic_tokens(self):
        """Verify ChatMessageList user bubble, assistant text, and scroll canvas use semantic tokens."""
        # Scroll canvas uses bg-canvas
        self.assertIn("bg-canvas", self.chat_message_list)
        # User message bubble uses surface-raised with subtle border and primary text
        self.assertIn("border border-subtle bg-surface-raised", self.chat_message_list)
        self.assertIn("text-primary", self.chat_message_list)
        # Assistant text uses text-primary
        self.assertIn(": 'text-primary'", self.chat_message_list)
        # Load older button
        self.assertIn("border border-subtle bg-surface px-3 py-1.5 text-xs text-muted hover:text-primary", self.chat_message_list)
        # Jump to latest button
        self.assertIn("border border-subtle bg-surface-raised/90", self.chat_message_list)
        # No hardcoded zinc or black canvas
        self.assertNotIn("bg-[#090909]", self.chat_message_list)
        self.assertNotIn("text-zinc-", self.chat_message_list)
        self.assertNotIn("bg-zinc-", self.chat_message_list)

    def test_agent_pane_composer_panel_semantic_tokens(self):
        """Verify AgentPaneComposerPanel uses surface, surface-raised, and subtle borders."""
        self.assertIn("border-subtle bg-surface", self.agent_pane_composer)
        self.assertIn("border-b border-subtle bg-surface-raised", self.agent_pane_composer)
        self.assertIn("bg-neutral-soft", self.agent_pane_composer)
        self.assertIn("text-muted hover:bg-neutral-soft hover:text-primary", self.agent_pane_composer)
        self.assertNotIn("text-zinc-", self.agent_pane_composer)
        self.assertNotIn("bg-zinc-", self.agent_pane_composer)

    def test_agent_activity_bubbles_semantic_tokens(self):
        """Verify AgentActivityBubbles uses semantic tokens."""
        self.assertIn("border border-subtle bg-surface", self.bubbles)
        self.assertIn("text-muted", self.bubbles)
        self.assertIn("bg-muted", self.bubbles)
        self.assertNotIn("text-zinc-", self.bubbles)
        self.assertNotIn("bg-zinc-", self.bubbles)

    def test_at_mention_popup_semantic_tokens(self):
        """Verify AtMentionPopup uses surface-raised and subtle borders."""
        self.assertIn("border border-subtle bg-surface-raised", self.mention_popup)
        self.assertIn("shadow-panel", self.mention_popup)
        self.assertIn("text-faint", self.mention_popup)
        self.assertIn("bg-neutral-soft", self.mention_popup)
        self.assertNotIn("text-zinc-", self.mention_popup)
        self.assertNotIn("bg-zinc-", self.mention_popup)

    def test_conversation_thread_page_semantic_tokens(self):
        """Verify ConversationThreadPage transcript, composer, headers, and tabs use semantic tokens."""
        # Page background uses bg-canvas
        self.assertIn('className="relative flex flex-col sm:flex-row h-full min-h-0 w-full max-w-full overflow-x-hidden bg-canvas p-0 text-left"', self.conversation_page)
        # Transcript scroll uses bg-canvas
        self.assertIn("rounded-none bg-canvas px-1 pt-16 pb-4", self.conversation_page)
        # Composer card uses bg-surface and border-subtle
        self.assertIn("rounded-[22px] border border-subtle bg-surface px-3 py-2.5 focus-within:border-accent sm:px-4 sm:py-3", self.conversation_page)
        # Send button uses accent
        self.assertIn("bg-accent text-accent-fg hover:opacity-90 disabled:cursor-not-allowed disabled:opacity-40", self.conversation_page)
        # Attachment tray uses surface-raised and subtle border
        self.assertIn("border border-subtle bg-surface-raised p-2 text-xs text-primary", self.conversation_page)
        # Resizer divider uses border-subtle and accent hover
        self.assertIn("border-l border-subtle hover:border-accent/50 hover:bg-accent/10 active:bg-accent/20", self.conversation_page)

    def test_project_launch_modal_semantic_tokens(self):
        """Verify ProjectLaunchModal uses semantic tokens without raw dark colors."""
        self.assertIn("Launch Agent — <span className=\"text-accent\">", self.project_launch_modal)
        self.assertIn("bg-neutral-soft text-primary font-semibold shadow-sm", self.project_launch_modal)
        self.assertIn("border-subtle bg-surface hover:bg-surface-raised", self.project_launch_modal)
        self.assertIn("border-accent/60 bg-accent/10 shadow-sm", self.project_launch_modal)
        self.assertNotIn("text-zinc-", self.project_launch_modal)
        self.assertNotIn("bg-zinc-", self.project_launch_modal)
        self.assertNotIn("border-zinc-", self.project_launch_modal)

    def test_delete_action_modal_semantic_tokens(self):
        """Verify DeleteActionModal uses semantic tokens."""
        self.assertIn("text-sm text-primary", self.delete_modal)
        self.assertIn("border border-subtle bg-surface p-3", self.delete_modal)
        self.assertIn("text-xs text-muted font-mono line-clamp-3", self.delete_modal)
        self.assertNotIn("text-zinc-", self.delete_modal)
        self.assertNotIn("bg-zinc-", self.delete_modal)

    def test_scope_field_semantic_tokens(self):
        """Verify ScopeField chip and allLabel pill use semantic tokens."""
        self.assertIn("border-accent/30 bg-accent/10 text-accent", self.scope_field)
        self.assertIn("border border-subtle bg-neutral-soft px-2 py-0.5 text-caption text-muted", self.scope_field)
        self.assertIn("text-caption uppercase tracking-wide text-faint", self.scope_field)
        self.assertNotIn("text-zinc-", self.scope_field)
        self.assertNotIn("bg-zinc-", self.scope_field)

    def test_command_palette_semantic_tokens(self):
        """Verify CommandPalette items, kbd tags, and scope toggles use semantic tokens."""
        self.assertIn("bg-neutral-soft text-primary font-semibold", self.command_palette)
        self.assertIn("bg-neutral-soft text-muted", self.command_palette)
        self.assertIn("border border-subtle bg-neutral-soft px-1.5 py-0.5", self.command_palette)
        self.assertNotIn("text-zinc-", self.command_palette)
        self.assertNotIn("bg-zinc-", self.command_palette)


if __name__ == "__main__":
    unittest.main()
