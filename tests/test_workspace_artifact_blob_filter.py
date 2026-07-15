#!/usr/bin/env python3
"""Regression: repo-level workspace diffs ignore artifact blob shard paths."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
GIT_VCS = ROOT / "src/lib/vcs/git.odin"
ARTIFACT_STORAGE = ROOT / "src/daemon/artifact_storage.odin"


def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"[-] FAIL: {message}")
        sys.exit(1)


def main() -> None:
    git_vcs = GIT_VCS.read_text(encoding="utf-8")
    artifact_storage = ARTIFACT_STORAGE.read_text(encoding="utf-8")

    require('artifact_blob_rel_path :: proc' in artifact_storage, 'artifact blob sharding helper missing')
    require('return fmt.tprintf("%s/%s/%s", shard_a, shard_b, artifact_id)' in artifact_storage, 'artifact blobs should remain two-level sharded')

    require('git_is_probable_artifact_blob_path :: proc' in git_vcs, 'artifact blob path detector missing from git vcs layer')
    require('len(artifact_id) != 36 || !strings.has_prefix(artifact_id, "art_")' in git_vcs, 'artifact blob detector should validate art_ id shape')
    require('if strings.contains(status, "?") && git_is_probable_artifact_blob_path(path) do continue' in git_vcs, 'repo status should skip artifact blob shard paths')
    require('if git_is_probable_artifact_blob_path(file) do continue' in git_vcs, 'untracked diff generation should skip artifact blob shard paths')

    print('WORKSPACE ARTIFACT BLOB FILTER TEST PASSED')


if __name__ == '__main__':
    main()
