#!/usr/bin/env python3
"""Source regression for chain progress UI in chain view and sidebar (TCUI-5/TCUI-6)."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "src/ui/components/App.tsx"


def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"[-] FAIL: {message}")
        sys.exit(1)


def main() -> None:
    src = APP.read_text(encoding="utf-8")
    require("function buildChainProgress" in src, "shared chain progress helper missing")
    require("TASK_PROGRESS_COMPLETE_STATUSES" in src and "approved" in src and "completed" in src, "success task statuses should count complete")
    require("TASK_PROGRESS_EXCLUDED_STATUSES" in src and "cancelled" in src, "cancelled/terminal-neutral tasks should be excluded")
    require("function ChainProgressPanel" in src, "chain progress panel component missing")
    require('data-debug-id="chain-progress-panel"' in src, "chain view progress panel debug id missing")
    require('data-debug-id="chain-progress-bar"' in src, "chain view progress bar debug id missing")
    require("<ChainProgressPanel chain={chain} progress={chainProgress} />" in src, "chain view should render progress above task surface")
    require("progress.total === 0 ? '—'" in src, "zero-task progress badge should be graceful")
    # The chain progress percent must be shown exactly ONCE in the progress panel:
    # a single numeric badge (`${progress.percent}%`). The heading no longer repeats
    # the percent (previously it also showed `${progress.percent}% complete`).
    require("`${progress.percent}%`" in src, "progress panel should render the numeric percent badge")
    require("${progress.percent}% complete" not in src, "progress heading must not duplicate the percent value")
    print("TASK CHAIN PROGRESS UI TEST PASSED")


if __name__ == "__main__":
    main()
