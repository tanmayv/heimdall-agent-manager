#!/usr/bin/env python3
"""Phase 5 Grep-Guard Test: ensure ALL six task-store arrays and their _count variables are only accessed by the store owners."""
import glob
import os
import re
import sys

def main():
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    daemon_files = glob.glob(os.path.join(repo_root, "src", "daemon", "*.odin"))
    
    allowed_owners = {
        "task_store.odin",
        "task_store_repository.odin",
        "task_projection.odin",
        "task_db_service.odin",
    }
    
    pattern = re.compile(r'\b(task_events|task_event_count|task_states|task_state_count|task_participants|task_participant_count|task_chains|task_chain_count|task_comments|task_comment_count|task_lgtm_votes|task_lgtm_vote_count)\b')
    errors = []
    
    for filepath in daemon_files:
        filename = os.path.basename(filepath)
        if filename in allowed_owners:
            continue
        with open(filepath, "r", encoding="utf-8") as f:
            for line_idx, line in enumerate(f, 1):
                # ignore comments
                line_clean = line.split("//")[0]
                if pattern.search(line_clean):
                    errors.append(f"{filename}:{line_idx}: {line.strip()}")
                    
    if errors:
        print("FAIL: task-store array or count accessed outside store owners (Phase 5):")
        for err in errors:
            print(f"  {err}")
        sys.exit(1)
        
    print("PASS: all six task-store arrays and counts are private to the store (Phase 5)")
    sys.exit(0)

if __name__ == "__main__":
    main()
