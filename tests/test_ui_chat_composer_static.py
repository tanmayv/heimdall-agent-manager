#!/usr/bin/env python3
"""Static guard for UI-5 ChatComposer attachments + mentions."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CHAT = ROOT / "src" / "ui" / "components" / "chat" / "ChatComposer.tsx"
TYPES = ROOT / "src" / "ui" / "components" / "chat" / "types.ts"
LAUNCH = ROOT / "src" / "ui" / "components" / "chat" / "ConversationLaunchComposer.tsx"
APP = ROOT / "src" / "ui" / "components" / "App.tsx"
CHAT_SLICE = ROOT / "src" / "ui" / "store" / "chatSlice.ts"
CHAIN_SLICE = ROOT / "src" / "ui" / "store" / "chainViewSlice.ts"
DAEMON_API = ROOT / "src" / "ui" / "api" / "daemonApi.ts"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    chat = CHAT.read_text(encoding="utf-8")
    types = TYPES.read_text(encoding="utf-8")
    launch = LAUNCH.read_text(encoding="utf-8")
    app = APP.read_text(encoding="utf-8")

    for marker in [
        "data-upload-before-send=\"true\"",
        "AttachmentState",
        "status: 'uploading' | 'uploaded' | 'error'",
        "artifactIdFromUpload",
        "artifactIds:",
        "hasUploadingAttachments",
        "sendDisabled || hasUploadingAttachments",
        "onDrop=",
        "onDragOver=",
        "clipboardFiles",
        "type=\"file\" multiple",
        "attachment-progress",
        "attachment-retry",
        "attachment-remove",
        "upload.uploadFile(file)",
    ]:
        require(marker in chat, f"missing upload-before-send marker: {marker}")

    for marker in [
        "MENTION_CATEGORIES",
        "'agent'",
        "'task'",
        "'task-chain'",
        "'memory'",
        "'project'",
        "'artifact'",
        "parseMentions",
        "activeMentionToken",
        "mention-autocomplete",
        "mention-chips",
        "replaceActiveMention",
        "sendStructuredMentions",
    ]:
        require(marker in chat, f"missing mention marker: {marker}")

    for marker in [
        "ChatComposerSubmitPayload",
        "artifactIds: string[]",
        "ChatComposerMention",
        "searchMentions?",
        "uploadFile?: (file: File)",
        "onSubmit: (payload?: ChatComposerSubmitPayload)",
    ]:
        require(marker in types, f"missing typed composer contract: {marker}")

    require("artifact_ids: []" in launch, "first-send path must keep artifact_ids in POST /api/v1/chats payload")
    require("uploadFile: upload.uploadFile" in app and "uploadFile: composerArtifactUpload.uploadFile" in app, "live ChatComposer call sites must enable upload-before-send queueing")
    forbidden = ["slash command", "voice input", "implicit task-comment"]
    lowered = chat.lower()
    for marker in forbidden:
        require(marker not in lowered, f"UI-5 non-goal leaked into ChatComposer: {marker}")

    # --- Send-path threading: artifactIds must NOT be dropped at any live layer ---
    chat_slice = CHAT_SLICE.read_text(encoding="utf-8")
    chain_slice = CHAIN_SLICE.read_text(encoding="utf-8")
    daemon_api = DAEMON_API.read_text(encoding="utf-8")

    # Composer emits artifactIds in its submit payload.
    require("artifactIds: attachments" in chat, "ChatComposer must collect uploaded artifact ids into submit payload")

    # App.tsx submit handlers must forward payload?.artifactIds down each path.
    require("payload?.artifactIds" in app, "App.tsx submit handlers must forward payload?.artifactIds")
    require("(payload?: ChatComposerSubmitPayload)" in app, "App.tsx submit handlers must accept ChatComposerSubmitPayload")
    require("onSubmit: (payload?: ChatComposerSubmitPayload)" in app or "onSubmit: submit" in app, "App.tsx composer onSubmit must pass the submit payload through, not discard it")

    # chatSlice thunk must forward artifactIds into the RTK Query initiate call.
    require("artifactIds?: string[]" in chat_slice, "sendMessageToSelectedAgent must accept artifactIds")
    require("artifactIds: payload.artifactIds" in chat_slice, "sendMessageToSelectedAgent must forward artifactIds into sendAgentMessage.initiate")

    # chainViewSlice thunk must forward artifactIds into daemonApi.sendToCoordinator.
    require("artifactIds?: string[]" in chain_slice, "sendCoordinatorMessage must accept artifactIds")
    require("artifactIds: payload.artifactIds" in chain_slice, "sendCoordinatorMessage must forward artifactIds into daemonApi.sendToCoordinator")

    # daemonApi must serialize artifactIds as artifact_ids on BOTH send paths.
    require("artifact_ids: attachments" in daemon_api, "daemonApi must serialize artifact_ids from artifactIds")
    require(daemon_api.count("artifact_ids: attachments") >= 2, "daemonApi must forward artifact_ids on both sendToAgent and sendToCoordinator")

    print("PASS: UI-5 ChatComposer attachments + mentions static")


if __name__ == "__main__":
    main()
