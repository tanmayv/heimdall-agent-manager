#!/usr/bin/env python3
"""Regression: agent/team defaults must not use an actual cheap model tier."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]


def fail(message: str) -> None:
    print(f"[-] FAIL: {message}")
    sys.exit(1)


def model_sections(path: Path):
    sections = []
    current_name = ""
    current = None
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        m = re.match(r"\[wrapper\.agent-cmd\.([^\]]+)\.models\]", line)
        if m:
            current_name = m.group(1)
            current = {}
            sections.append((current_name, current))
            continue
        if line.startswith("["):
            current = None
            continue
        if current is not None and "=" in line:
            key, value = line.split("=", 1)
            current[key.strip()] = value.strip().strip('"')
    return sections


def main() -> None:
    team_kinds = (ROOT / "src/daemon/team_kinds.odin").read_text(encoding="utf-8")
    if 'default_tier = "cheap"' in team_kinds:
        fail("team kind role defaults must not use cheap")

    agents_start = (ROOT / "src/daemon/agents_start.odin").read_text(encoding="utf-8")
    if 'normalize_model_tier :: proc' not in agents_start or 'tier == "cheap" do return "normal"' not in agents_start:
        fail("agents_start must normalize cheap tier to normal")
    if not re.search(r'launch_wrapper_detached[\s\S]+?tier := normalize_model_tier\(model_tier\)', agents_start):
        fail("wrapper launches must normalize cheap tier before passing --tier")

    agent_store = (ROOT / "src/daemon/agent_store.odin").read_text(encoding="utf-8")
    if 'tier := normalize_model_tier(event.model_tier)' not in agent_store:
        fail("agent store must persist cheap as normal")

    for config_name in ("config.toml", "config-test.toml"):
        for provider, models in model_sections(ROOT / config_name):
            if "cheap" in models and models.get("cheap") != models.get("normal"):
                fail(f"{config_name} provider {provider} cheap model must equal normal")

    onboarding = (ROOT / "src/ui/components/OnboardingWizard.tsx").read_text(encoding="utf-8")
    if '<option value="cheap">' in onboarding or "['cheap', 'normal', 'smart']" in onboarding:
        fail("onboarding should not offer cheap as an agent tier")

    print("PASS: cheap agent tier is upgraded/normalized to normal")


if __name__ == "__main__":
    main()
