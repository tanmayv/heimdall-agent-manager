#!/usr/bin/env python3
"""Phase 3 regression: non-operator user review votes must count as required."""
import json
import os
import shutil
import socket
import subprocess
import tempfile
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TASK_SERVICE = ROOT / "src/daemon/task_service.odin"
DAEMON_BIN = Path(os.environ.get("HAM_DAEMON_BIN", ROOT / "result/bin/ham-daemon"))
WRAPPER_BIN = Path(os.environ.get("HAM_WRAPPER_BIN", ROOT / "result-wrapper/bin/ham-wrapper"))
HOST = "127.0.0.1"


def free_port() -> int:
    sock = socket.socket()
    sock.bind((HOST, 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


def request_post(url: str, path: str, data: dict) -> dict:
    req = urllib.request.Request(
        f"{url}{path}",
        data=json.dumps(data).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=5) as res:
        return json.loads(res.read().decode())


def wait_health(url: str) -> None:
    for _ in range(80):
        try:
            with urllib.request.urlopen(f"{url}/health", timeout=1) as res:
                if res.status == 200:
                    return
        except Exception:
            time.sleep(0.1)
    raise RuntimeError("daemon did not become healthy")


class Phase3UserVoteRequiredTests(unittest.TestCase):
    def test_source_uses_identity_predicate_not_operator_literal(self):
        src = TASK_SERVICE.read_text()
        self.assertIn('user_review_required := cmd.author_is_user && task_requires_user_review(state)', src)
        self.assertIn('if !is_required && (user_review_required || vote_author == task_reviewer_agent_instance_id(state)) {', src)
        fn = src.split('task_user_proxy_reviewer_for :: proc', 1)[1].split('task_notify_user_proxy_review_requests :: proc', 1)[0]
        self.assertNotIn('user_id == "operator@local"', fn)

    def test_non_operator_user_vote_is_required_and_auto_approves(self):
        temp_dir = tempfile.mkdtemp(prefix="heimdall-phase3-")
        daemon_proc = None
        try:
            port = free_port()
            config_path = Path(temp_dir) / "config.toml"
            config_path.write_text(
                f'''[daemon]\nbind_host = "{HOST}"\nport = {port}\ndata_dir = "{temp_dir}/data"\nwrapper_bin = "{WRAPPER_BIN}"\n''',
                encoding="utf-8",
            )
            daemon_proc = subprocess.Popen(
                [str(DAEMON_BIN), "--config", str(config_path)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.STDOUT,
            )
            url = f"http://{HOST}:{port}"
            wait_health(url)

            user_token = request_post(url, "/user-client/register", {
                "user_id": "alt-reviewer@local",
                "client_instance_id": "phase3-user",
            })["client_token"]
            agent_token = request_post(url, "/register", {
                "agent_class": "phase3-coder",
                "agent_instance_id": "phase3-coder@default",
                "display_name": "Phase 3 Coder",
            })["agent_token"]

            chain_id = request_post(url, "/task-chains/create", {
                "agent_token": agent_token,
                "kind": "solo",
                "no_scaffold": True,
                "title": "Phase 3 user vote regression",
                "coordinator_agent_instance_id": "phase3-coder@default",
            })["chain_id"]
            task_id = request_post(url, "/tasks/create", {
                "agent_token": agent_token,
                "chain_id": chain_id,
                "title": "User review task",
                "assignee_agent_instance_id": "phase3-coder@default",
            })["task_id"]

            request_post(url, "/tasks/done", {
                "agent_token": agent_token,
                "task_id": task_id,
                "chain_id": chain_id,
                "body": "ready for human review",
            })

            pre = request_post(url, "/tasks/show", {
                "agent_token": agent_token,
                "task_id": task_id,
                "chain_id": chain_id,
            })["task"]
            self.assertEqual(pre["status"], "review_ready")
            self.assertEqual(pre["reviewer_agent_instance_id"], "user_proxy")

            vote = request_post(url, "/tasks/vote", {
                "agent_token": user_token,
                "task_id": task_id,
                "chain_id": chain_id,
                "result": "lgtm",
                "comment": "approved by non-operator user",
            })
            self.assertTrue(vote["ok"])
            self.assertEqual(vote["status"], "approved")

            post = request_post(url, "/tasks/show", {
                "agent_token": agent_token,
                "task_id": task_id,
                "chain_id": chain_id,
            })["task"]
            self.assertEqual(post["status"], "approved")

            events = request_post(url, "/tasks/log", {
                "agent_token": agent_token,
                "task_id": task_id,
                "chain_id": chain_id,
            })["events"]
            votes = [e for e in events if e.get("kind") == "Task_Review_Vote"]
            self.assertTrue(votes, "expected review vote event")
            review_vote = votes[-1]
            self.assertEqual(review_vote["role"], "lgtm_required")
            self.assertEqual(review_vote["author_agent_instance_id"], "user_proxy")

            approvals = [e for e in events if e.get("kind") == "Task_Status_Changed" and e.get("status") == "approved"]
            self.assertTrue(approvals, "expected auto-approve event")
            self.assertIn("all_lgtm_required_approved", approvals[-1]["body"])
        finally:
            if daemon_proc is not None:
                daemon_proc.terminate()
                try:
                    daemon_proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    daemon_proc.kill()
            shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
