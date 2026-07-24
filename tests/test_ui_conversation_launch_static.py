#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LAUNCH = ROOT / "src" / "ui" / "components" / "chat" / "ConversationLaunchComposer.tsx"
SHELL = ROOT / "src" / "ui" / "components" / "shell" / "AppShell.tsx"
GAP = ROOT / "docs" / "plans" / "ui-backend-gap-analysis.md"
ARCH = ROOT / "docs" / "plans" / "ui-architecture.md"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    launch = LAUNCH.read_text()
    shell = SHELL.read_text()
    gap = GAP.read_text()
    arch = ARCH.read_text()

    for marker in [
        "data-debug-id=\"conversation-launch-composer\"",
        "data-debug-id=\"launch-required-agent-control\"",
        "Agent required",
        "Choose an agent before sending",
        "const hasCapableBridgeSupport = !agentId || capableSupport.length > 0",
        "const canSend = status !== 'sending' && Boolean(agentId) && hasCapableBridgeSupport && body.trim().length > 0",
        "disabled={!canSend}",
        "SYNTHETIC_DEFAULT_PROJECT",
        "Default project: {selectedProject.name || 'Conversations'}",
        "data-debug-id=\"launch-project-default-control\"",
        "data-debug-id=\"launch-advanced-bridge-provider-tier-controls\"",
        "/agents/${encodeURIComponent(agentId)}/bridge-support",
        "rows.filter((row) => row.enabled !== false)",
        "bridgeCapabilityEntries",
        "return capability.default_tier ? [capability.default_tier] : []",
        "supportHasCapabilityIntersection",
        "providersForSupportIntersection",
        "tiersForSupportIntersection",
        "capableSupport",
        "providerOptions",
        "tierOptions",
        "pendingTierOptions",
        "current === '' || pendingTierOptions.includes(current) ? current : (pendingTierOptions[0] || '')",
        "const pendingProviderTierValid = pendingProviderValid && pendingTierValid",
        "const canReconfigureProviderTier = hasPendingProviderTierChange && pendingProviderTierValid",
        "bridgeId) payload.bridge_id = bridgeId",
        "if (provider) payload.provider = provider",
        "if (tier) payload.tier = tier",
        "const payload: Record<string, unknown> = {",
        "agent_id: agentId",
        "initial_message: { body: body.trim() }",
        "artifact_ids: []",
        "apiJson<any>('/chats', { method: 'POST'",
        "/agent-instances/${encodeURIComponent(String(created.agent_instance_id))}",
        "conversation_id: String(created.conversation_id || boundInstance.conversation_id || '')",
        "agent_instance_id: String(created.agent_instance_id || boundInstance.agent_instance_id || '')",
        "chain_id: String(created.chain_id || boundInstance.chain_id || '')",
        "setBridgeId(nextLocked.bridge_id === 'Auto' ? '' : nextLocked.bridge_id)",
        "data-debug-id=\"conversation-launch-locked-state\"",
        "data-debug-id=\"launch-locked-chips\"",
        "data-debug-id=\"launch-post-start-provider-tier-controls\"",
        "data-debug-id=\"launch-post-start-provider-select\"",
        "data-debug-id=\"launch-post-start-tier-select\"",
        "pendingProvider !== locked.provider || pendingTier !== locked.tier",
        "JSON.stringify({ provider: pendingProvider, tier: pendingTier })",
        "data-debug-id=\"launch-reconfigure-provider-tier\"",
        "disabled={!canReconfigureProviderTier}",
        "Choose a provider/tier pair supported by the pinned Bridge before reconfiguring.",
        "Changing provider resets tier to a supported option",
        "method: 'PATCH'",
        "data-debug-id=\"launch-restart-instance\"",
        "/restart",
        "method: 'POST'",
        "data-debug-id=\"launch-synthetic-default-project-gap\"",
        "data-debug-id=\"launch-no-capable-bridge-support\"",
        "intersected with <code>/api/v1/bridges</code> capability providers/tiers",
        "compact capability rows use <code>default_tier</code> as the bounded tier",
        "if (!usingSyntheticDefault) payload.project_id = selectedProject.project_id",
    ]:
        require(marker in launch, f"missing launch marker: {marker}")

    require("pendingTier && !pendingTierOptions.includes(pendingTier)" not in launch, "post-start tier select must not preserve stale unsupported tier options")
    require("pendingProvider && !providerOptions.includes(pendingProvider)" not in launch, "post-start provider select must not preserve stale unsupported provider options")

    require("ConversationLaunchComposer" in shell, "AppShell must import launch composer")
    require("path === '/conversations/new'" in shell, "new conversation route must render launch composer")
    require("<ConversationLaunchComposer />" in shell, "RouteOutlet must mount launch composer")

    forbidden = [
        "agent_instance_id: agentId",
        "LocalLaunchWizard",
        "StandaloneLaunchWizard",
        "username",
        "password",
        "token=",
    ]
    for marker in forbidden:
        require(marker not in launch, f"conversation launch must not include forbidden marker: {marker}")

    for doc_marker in [
        "POST /api/v1/chats",
        "First-send composer",
        "Locked chips",
        "agent (required)",
        "project (defaults to",
        "Restart",
    ]:
        require(doc_marker in gap or doc_marker in arch, f"docs missing UI-4 marker: {doc_marker}")

    print("PASS: UI conversation launch static")


if __name__ == "__main__":
    main()
