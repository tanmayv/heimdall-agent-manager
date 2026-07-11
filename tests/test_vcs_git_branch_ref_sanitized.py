#!/usr/bin/env python3
"""Regression: VCS git worktree branch names must not use conflicting slash refs."""
from pathlib import Path
import subprocess
import tempfile
import shutil
import os
import sys

ROOT = Path(__file__).resolve().parents[1]


def run(cmd, cwd=None, check=True):
    res = subprocess.run(cmd, cwd=cwd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and res.returncode != 0:
        raise AssertionError(f"command failed: {' '.join(cmd)}\nstdout={res.stdout}\nstderr={res.stderr}")
    return res


def main():
    src = (ROOT / "src/lib/vcs/git.odin").read_text(encoding="utf-8")
    if 'git_workspace_branch_name(name)' not in src or 'strings.replace_all(name, "/", "-")' not in src:
        raise AssertionError("git workspace add must sanitize slash-heavy workspace names before using them as branch refs")
    if '"-b", name' in src:
        raise AssertionError("git worktree add must not use raw workspace path name as branch ref")

    tmp = tempfile.mkdtemp(prefix="heimdall-vcs-ref-sanitize-")
    try:
        repo = os.path.join(tmp, "repo")
        wt_root = os.path.join(tmp, "worktrees")
        run(["git", "init", "-b", "main", repo])
        Path(repo, "README.md").write_text("hello\n", encoding="utf-8")
        run(["git", "add", "README.md"], cwd=repo)
        run(["git", "-c", "user.email=test@example.com", "-c", "user.name=Test", "commit", "-m", "init"], cwd=repo)

        # This existing ref makes a raw child branch like
        # team/team-chain-abc/agentsmd fail with: cannot lock ref ... exists.
        run(["git", "branch", "team/team-chain-abc"], cwd=repo)

        raw_name = "team/team-chain-abc/agentsmd"
        raw_path = os.path.join(wt_root, raw_name)
        raw = run(["git", "-C", repo, "worktree", "add", raw_path, "-b", raw_name, "main"], check=False)
        if raw.returncode == 0:
            raise AssertionError("test setup expected raw slash branch name to fail")

        clean_branch = "heimdall-team-team-chain-abc-agentsmd"
        clean_path = os.path.join(wt_root, "clean")
        run(["git", "-C", repo, "worktree", "add", clean_path, "-b", clean_branch, "main"])
        branches = run(["git", "-C", repo, "branch", "--list", clean_branch]).stdout
        if clean_branch not in branches:
            raise AssertionError("sanitized branch was not created")

        print("PASS: git VCS workspace branch refs are sanitized/flattened")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
