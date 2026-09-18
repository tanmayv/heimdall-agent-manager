#!/usr/bin/env python3
"""Static regression test for Bridge PTY spawn request ownership, provider store memory safety, and log appending.

Requirement IDs:
- REQ-BRIDGE-MEM-1: bridge_pty_host_build_spawn argv string ownership cloning
- REQ-BRIDGE-MEM-2: provider_store bootstrap_file_name interior pointer fix & agent_run_dir leak fix
- REQ-BRIDGE-LOG-1: package-cloudtop-bundle.sh start.sh log append redirection
- REQ-BRIDGE-STATIC-1: automated static regression verification
- REQ-VAL-BRIDGE-1: verification suite
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
PTY_HOST_RUNTIME = ROOT / "src" / "bridge" / "pty_host_runtime.odin"
PROVIDER_STORE = ROOT / "src" / "bridge" / "provider_store.odin"
PACKAGE_SCRIPT = ROOT / "scripts" / "package-cloudtop-bundle.sh"


def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"FAILED: {message}", file=sys.stderr)
        raise AssertionError(message)


def test_pty_host_build_spawn_argv_cloning() -> None:
    """REQ-BRIDGE-MEM-1: bridge_pty_host_build_spawn must clone all argv strings."""
    require(PTY_HOST_RUNTIME.exists(), f"pty_host_runtime.odin not found at {PTY_HOST_RUNTIME}")
    content = PTY_HOST_RUNTIME.read_text(encoding="utf-8")

    # Locate bridge_pty_host_build_spawn proc
    proc_match = re.search(r"bridge_pty_host_build_spawn\s*::\s*proc\b.*?\{(.*?)\n\}", content, re.DOTALL)
    require(bool(proc_match), "bridge_pty_host_build_spawn proc definition not found")
    proc_body = proc_match.group(1)

    # Must allocate cloned_argv slice
    require(
        "make([]string, len(agent_argv))" in proc_body,
        "bridge_pty_host_build_spawn must allocate cloned_argv slice with len(agent_argv)",
    )
    # Must clone each string from agent_argv
    require(
        "strings.clone(" in proc_body,
        "bridge_pty_host_build_spawn must call strings.clone() on each argument string",
    )
    # Must delete the container slice agent_argv
    require(
        "delete(agent_argv)" in proc_body,
        "bridge_pty_host_build_spawn must delete(agent_argv) slice container",
    )
    # Must assign cloned_argv to req.argv
    require(
        "argv             = cloned_argv" in proc_body or "argv = cloned_argv" in proc_body,
        "bridge_pty_host_build_spawn must assign cloned_argv to req.argv",
    )

    # Confirm bridge_pty_host_spawn_request_delete safely deletes strings and slice
    del_match = re.search(r"bridge_pty_host_spawn_request_delete\s*::\s*proc\b.*?\{(.*?)\n\}", content, re.DOTALL)
    require(bool(del_match), "bridge_pty_host_spawn_request_delete proc not found")
    del_body = del_match.group(1)
    require("for a in req.argv do delete(a)" in del_body or "delete(a)" in del_body, "req.argv elements must be deleted in delete proc")
    require("delete(req.argv)" in del_body, "req.argv slice must be deleted in delete proc")


def test_provider_store_memory_safety() -> None:
    """REQ-BRIDGE-MEM-2: provider_store must avoid interior pointers and free temporary expanded strings."""
    require(PROVIDER_STORE.exists(), f"provider_store.odin not found at {PROVIDER_STORE}")
    content = PROVIDER_STORE.read_text(encoding="utf-8")

    # Locate bridge_provider_override_from_json_with_name proc
    proc_match = re.search(r"bridge_provider_override_from_json_with_name\s*::\s*proc\b.*?\{(.*?)\n\}", content, re.DOTALL)
    require(bool(proc_match), "bridge_provider_override_from_json_with_name proc not found")
    proc_body = proc_match.group(1)

    # bootstrap_file_name must clone trimmed slice and delete original v
    require("bootstrap_file_name" in proc_body, "bootstrap_file_name extraction missing")
    bootstrap_snippet = proc_body[proc_body.find("bootstrap_file_name") - 50:proc_body.find("bootstrap_file_name") + 250]
    require(
        "strings.trim_space" in bootstrap_snippet and "strings.clone(" in bootstrap_snippet and "delete(v)" in bootstrap_snippet,
        f"bootstrap_file_name must trim_space, clone, and delete(v) to avoid interior pointer: got snippet {bootstrap_snippet}",
    )
    require(
        "o.bootstrap_file_name = strings.clone(trimmed)" in proc_body or "strings.clone(trimmed)" in bootstrap_snippet,
        "bootstrap_file_name must assign cloned trimmed string",
    )

    # agent_run_dir must check expanded != v and delete v
    require("agent_run_dir" in proc_body, "agent_run_dir extraction missing")
    agent_dir_snippet = proc_body[proc_body.find("agent_run_dir") - 50:proc_body.find("agent_run_dir") + 250]
    require(
        "bridge_expand_home" in agent_dir_snippet and "delete(v)" in agent_dir_snippet,
        f"agent_run_dir must delete(v) if expanded != v: got snippet {agent_dir_snippet}",
    )


def test_package_cloudtop_bundle_log_redirection() -> None:
    """REQ-BRIDGE-LOG-1: package-cloudtop-bundle.sh daemons must append logs with >>."""
    require(PACKAGE_SCRIPT.exists(), f"package-cloudtop-bundle.sh not found at {PACKAGE_SCRIPT}")
    content = PACKAGE_SCRIPT.read_text(encoding="utf-8")

    # Must contain >> "$BRIDGE_LOG"
    require('>> "$BRIDGE_LOG"' in content, 'package-cloudtop-bundle.sh must append to "$BRIDGE_LOG" using >>')
    # Must NOT contain > "$BRIDGE_LOG" (except possibly in comments or as >>)
    overwrites_bridge = re.findall(r'[^>]\s*>\s*"\$BRIDGE_LOG"', content)
    require(len(overwrites_bridge) == 0, f'Found overwrite redirection for BRIDGE_LOG: {overwrites_bridge}')

    # Must contain >> "$HUB_LOG"
    require('>> "$HUB_LOG"' in content, 'package-cloudtop-bundle.sh must append to "$HUB_LOG" using >>')
    overwrites_hub = re.findall(r'[^>]\s*>\s*"\$HUB_LOG"', content)
    require(len(overwrites_hub) == 0, f'Found overwrite redirection for HUB_LOG: {overwrites_hub}')

    # Must contain >> "$PROXY_LOG"
    require('>> "$PROXY_LOG"' in content, 'package-cloudtop-bundle.sh must append to "$PROXY_LOG" using >>')
    overwrites_proxy = re.findall(r'[^>]\s*>\s*"\$PROXY_LOG"', content)
    require(len(overwrites_proxy) == 0, f'Found overwrite redirection for PROXY_LOG: {overwrites_proxy}')


def main() -> None:
    print("Running test_pty_host_build_spawn_argv_cloning...")
    test_pty_host_build_spawn_argv_cloning()
    print("  PASS: test_pty_host_build_spawn_argv_cloning")

    print("Running test_provider_store_memory_safety...")
    test_provider_store_memory_safety()
    print("  PASS: test_provider_store_memory_safety")

    print("Running test_package_cloudtop_bundle_log_redirection...")
    test_package_cloudtop_bundle_log_redirection()
    print("  PASS: test_package_cloudtop_bundle_log_redirection")

    print("\nAll bridge pty spawn ownership and log appending static tests passed successfully.")


if __name__ == "__main__":
    main()
