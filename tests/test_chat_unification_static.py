#!/usr/bin/env python3
"""Static contract checks for unified chat component reuse/debug prefixes."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = (ROOT / 'src/ui/components/App.tsx').read_text(encoding='utf-8')
COMPOSER = (ROOT / 'src/ui/components/chat/ChatComposer.tsx').read_text(encoding='utf-8')
MESSAGE_LIST = (ROOT / 'src/ui/components/chat/ChatMessageList.tsx').read_text(encoding='utf-8')
WORK_BANNER = (ROOT / 'src/ui/components/chat/ChatWorkBanner.tsx').read_text(encoding='utf-8')
DEBUG_PREFIXES = (ROOT / 'src/ui/components/chat/debugPrefixes.ts').read_text(encoding='utf-8')


def require(text: str, snippet: str, label: str) -> None:
    if snippet not in text:
        raise AssertionError(f'missing {label}: {snippet}')


def main() -> None:
    for snippet in [
        "import ChatHeader from './chat/ChatHeader';",
        "import ChatComposer from './chat/ChatComposer';",
        "import ChatWorkBanner from './chat/ChatWorkBanner';",
        "import ChatMessageList from './chat/ChatMessageList';",
        "import ChatSidebar from './chat/ChatSidebar';",
        "import { agentDetailChatDebug, chainCoordinatorChatDebug, conversationChatDebug } from './chat/debugPrefixes';",
    ]:
        require(APP, snippet, 'shared chat imports')

    for snippet in [
        '<ChatHeader',
        '<ChatMessageList',
        '<ChatComposer',
        '<ChatWorkBanner',
        '<ChatSidebar debugId={agentDetailChatDebug.sidebar}',
        '<ChatSidebar debugId={chainCoordinatorChatDebug.sidebar}',
    ]:
        require(APP, snippet, 'shared component usage')

    for snippet in [
        "shellDebugId={agentDetailChatDebug.composer + '-composer-shell'}",
        "shellDebugId={conversationChatDebug.composer + '-shell'}",
        "shellDebugId={chainCoordinatorChatDebug.composer + '-composer-shell'}",
        'debugPrefix={agentDetailChatDebug.messageList}',
        'debugPrefix={conversationChatDebug.messageList}',
        'debugPrefix={chainCoordinatorChatDebug.messageList}',
        'debugPrefix={agentDetailChatDebug.workBanner}',
        'debugPrefix={conversationChatDebug.workBanner}',
        'debugPrefix={chainCoordinatorChatDebug.workBanner}',
    ]:
        require(APP, snippet, 'per-surface debug wiring')

    for snippet in [
        "messageList: 'chain-coordinator'",
        "composer: 'chain-coordinator'",
        "upload: 'chain-coordinator-artifact-upload'",
        "messageList: 'conversation-thread'",
        "composer: 'conversation-composer'",
        "upload: 'conversation-attach'",
        "runtime: 'conversation'",
        "messageList: 'agent-detail-chat'",
        "composer: 'agent-detail-chat'",
        "upload: 'agent-detail-chat-artifact-upload'",
        "sidebar: 'agent-detail-chat-sidebar'",
    ]:
        require(DEBUG_PREFIXES, snippet, 'debug prefix contract')

    for snippet in [
        'if (event.key !== \'Enter\' || event.shiftKey || !(event.metaKey || event.ctrlKey)) return;',
        "keyboardHint = '⌘↵ to send'",
        '<ArtifactUploadButton',
        '<RuntimeRestartControls',
        'data-debug-id={sendButtonDebugId}',
        'data-debug-id={shellDebugId}',
        'data-debug-id={inputDebugId}',
    ]:
        require(COMPOSER, snippet, 'shared composer contract')

    for snippet in [
        'data-debug-id={`${debugPrefix}-scroll`}',
        'data-debug-id={`${debugPrefix}-load-older-messages-btn`}',
        'data-debug-id={`${debugPrefix}-message-${message.messageId}-time`}',
        'debugId={`${debugPrefix}-message-copy-btn-${message.messageId}`}',
        'data-debug-id={`${debugPrefix}-message-${message.messageId}-status`}',
        'data-debug-id={`${debugPrefix}-jump-latest-btn`}',
    ]:
        require(MESSAGE_LIST, snippet, 'shared message list contract')

    for snippet in [
        'data-debug-id={`${debugPrefix}-status-banner`}',
        'data-debug-id={`${debugPrefix}-status-start-btn`}',
        "const taskLabel = mode === 'working' ? agentCurrentTaskLabel(agent, tasksById) : '';",
    ]:
        require(WORK_BANNER, snippet, 'shared work banner contract')

    for snippet in [
        "runtimeControls={{ debugPrefix: chainCoordinatorChatDebug.runtime, providers, projects, provider: coordinatorProvider, modelTier: coordinatorTier, projectId, disabled: true, restarting: false, showProject: true, onRestart: async () => undefined }}",
        "runtimeControls={{ debugPrefix: conversationChatDebug.runtime, providers, projects, provider: messageProvider, modelTier: messageTier, projectId: agent?.projectId || '', disabled: !agent?.id || sending, restarting: threadBusy === 'restart', showProject: true, onRestart: restartConversationRuntime }}",
        "runtimeControls={{ debugPrefix: agentDetailChatDebug.runtime, providers, projects, provider: chatProvider, modelTier: chatTier, projectId: agent?.projectId || '', disabled: !agent?.id, restarting: Boolean(runtimeRestarting), showProject: true, onRestart: (next) => { void restartExactRuntime(next.provider, next.modelTier, 'runtime', next.projectId); } }}",
    ]:
        require(APP, snippet, 'project/provider/tier runtime controls')

    print('PASS: unified chat surfaces share components and preserve debug-prefix contracts')


if __name__ == '__main__':
    main()
