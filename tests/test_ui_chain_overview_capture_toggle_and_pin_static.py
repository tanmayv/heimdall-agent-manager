#!/usr/bin/env python3
"""
Static regression test verifying:
REQ-UI-CHAIN-SUMMARY-CAPTURE-TOGGLE-AND-PIN

Acceptance criteria:
1. Terminal capture toggle icon button added to each member card in Chain Agents section.
2. Fleet Terminals section displays only agents with active capture enabled.
3. Placeholder message displayed when no terminal captures are active.
4. Pin toggle button added to Fleet Terminal accordion header and maximize modal header.
5. Pin toggle adds/removes agent from /agent-monitor grid via clientPersistence.
"""

import sys
from pathlib import Path

def test_chain_overview_capture_and_pin():
    repo_root = Path(__file__).resolve().parent.parent
    chain_overview_path = repo_root / "src" / "ui" / "components" / "chat" / "ChainOverviewPanel.tsx"
    
    assert chain_overview_path.exists(), f"Missing {chain_overview_path}"
    content = chain_overview_path.read_text(encoding="utf-8")
    
    # 1. State declarations
    assert "capturedTerminalIds" in content, "Missing capturedTerminalIds state"
    assert "pinnedAgentIds" in content, "Missing pinnedAgentIds state"
    
    # 2. Persistence imports
    assert "readPinnedMonitorAgents" in content, "Missing readPinnedMonitorAgents import"
    assert "addPinnedMonitorAgent" in content, "Missing addPinnedMonitorAgent import"
    assert "removePinnedMonitorAgent" in content, "Missing removePinnedMonitorAgent import"
    
    # 3. Section 3: Terminal capture toggle button on member cards
    assert "chain-overview-toggle-capture-" in content, "Missing capture toggle button debug id"
    assert "Stop capturing terminal" in content, "Missing active title for capture toggle"
    assert "Capture terminal output" in content, "Missing inactive title for capture toggle"
    assert "bg-accent/20 text-accent font-semibold hover:bg-accent/30" in content, "Missing active capture styling"
    assert "text-muted hover:bg-neutral-soft hover:text-primary" in content, "Missing inactive capture styling"
    
    # Check that toggling capture on also ensures openTerminalIds is set to true
    assert "setOpenTerminalIds" in content, "Missing setOpenTerminalIds call"
    
    # 4. Section 6: Filtered Fleet Terminals
    assert "Fleet Terminals ({capturedMembers.length})" in content, "Missing Fleet Terminals count using capturedMembers"
    assert "No active terminal captures. Click the terminal icon on an agent card in Chain Agents to capture and monitor its output." in content, (
        "Missing placeholder text when capturedMembers is empty"
    )
    
    # 5. Pin toggle in Fleet Terminal accordion header
    assert "chain-overview-terminal-pin-" in content, "Missing accordion pin button debug id"
    assert "Unpin from monitor" in content, "Missing unpin title"
    assert "Pin to Agent Monitor" in content, "Missing pin title"
    
    # 6. Pin toggle in Maximized Terminal modal header
    assert "chain-overview-maximized-terminal-pin-" in content, "Missing modal pin button debug id"
    
    # 7. First pin opens /#/agent-monitor
    assert "/#/agent-monitor" in content, "Missing agent-monitor URL navigation on first pin"
    
    print("ALL STATIC REGRESSION ASSERTIONS PASSED")

if __name__ == "__main__":
    test_chain_overview_capture_and_pin()
