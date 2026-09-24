#!/usr/bin/env python3
"""Hermetic test runner for ham-ctl fleet CLI verbs and polymorphic actor ref assignment.

Tests:
1. User-mode CLI against mock HTTP server:
   - task-chains fleet list <chain_id> -> GET /api/v1/task-chains/<chain_id>/fleets
   - task-chains fleet set <chain_id> --agent agt_worker --capacity 5 --min-warm 2 --idle-ttl 300
       -> PUT /api/v1/task-chains/<chain_id>/fleets/agt_worker with JSON payload
   - tasks create --chain <chain_id> --title "Fleet Task" --assignee agt_worker --reviewer agt_reviewer
       -> POST /api/v1/task-chains/<chain_id>/tasks with assignee_ref and reviewer_refs formatted as agent_id
   - tasks create --chain <chain_id> --title "Instance Task" --assignee inst_worker --reviewer inst_reviewer
       -> POST /api/v1/task-chains/<chain_id>/tasks with assignee_ref and reviewer_refs formatted as agent_instance

2. Agent-mode CLI against mock Bridge JSONL server (TCP):
   - task-chain fleet list <chain_id> -> agent.rest.request GET /api/v1/task-chains/<chain_id>/fleets
   - task-chain fleet set <chain_id> --agent agt_worker --capacity 4 --min-warm 1 --idle-ttl 120
       -> agent.rest.request PUT /api/v1/task-chains/<chain_id>/fleets/agt_worker with JSON payload
   - task create --chain <chain_id> --title "Agent Mode Task" --assignee agt_worker --reviewer agt_rev
       -> agent.rest.request POST /api/v1/task-chains/<chain_id>/tasks with agent_id actor refs
   - task create --chain <chain_id> --title "Agent Mode Inst" --assignee inst_w --reviewer inst_r
       -> agent.rest.request POST /api/v1/task-chains/<chain_id>/tasks with agent_instance actor refs
"""

import json
import os
import socket
import subprocess
import sys
import threading
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path

CTL_BIN = "/tmp/ham-ctl"
if not os.path.exists(CTL_BIN):
    print(f"Error: {CTL_BIN} does not exist. Build it first.", file=sys.stderr)
    sys.exit(1)


class MockHTTPHandler(BaseHTTPRequestHandler):
    recorded_requests = []

    def log_message(self, format, *args):
        pass  # suppress log output

    def do_GET(self):
        self.recorded_requests.append({
            "method": "GET",
            "path": self.path,
            "headers": dict(self.headers),
            "body": None,
        })
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"ok":true,"data":[{"agent_id":"agt_worker","capacity":3,"active_count":1}]}')

    def do_PUT(self):
        content_len = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_len).decode("utf-8") if content_len > 0 else ""
        self.recorded_requests.append({
            "method": "PUT",
            "path": self.path,
            "headers": dict(self.headers),
            "body": body,
        })
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"ok":true,"data":{"agent_id":"agt_worker","capacity":5}}')

    def do_POST(self):
        content_len = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_len).decode("utf-8") if content_len > 0 else ""
        self.recorded_requests.append({
            "method": "POST",
            "path": self.path,
            "headers": dict(self.headers),
            "body": body,
        })
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"ok":true,"data":{"task_id":"task_test_123","assignee_ref":{"type":"agent_id","agent_id":"agt_worker"}}}')


def test_user_mode():
    print("--- Running test_user_mode ---")
    server = HTTPServer(("127.0.0.1", 0), MockHTTPHandler)
    port = server.server_address[1]
    server_thread = threading.Thread(target=server.serve_forever, daemon=True)
    server_thread.start()

    base_url = f"http://127.0.0.1:{port}"
    token = "hut_test_token"
    env = {
        "PATH": os.environ.get("PATH", ""),
        # clear agent mode env vars
        "HOME": os.environ.get("HOME", "/tmp"),
    }

    def run_ctl(*args):
        cmd = [CTL_BIN, "--daemon-url", base_url, "--token", token] + list(args)
        proc = subprocess.run(cmd, capture_output=True, text=True, env=env)
        return proc

    # 1. task-chains fleet list
    MockHTTPHandler.recorded_requests.clear()
    proc = run_ctl("task-chains", "fleet", "list", "chain_test123")
    assert proc.returncode == 0, f"proc failed: {proc.stderr}"
    assert len(MockHTTPHandler.recorded_requests) == 1
    req = MockHTTPHandler.recorded_requests[0]
    assert req["method"] == "GET"
    assert req["path"] == "/api/v1/task-chains/chain_test123/fleets"
    print("PASS: user-mode task-chains fleet list")

    # 2. task-chains fleet set
    MockHTTPHandler.recorded_requests.clear()
    proc = run_ctl("task-chains", "fleet", "set", "chain_test123", "--agent", "agt_worker", "--capacity", "5", "--min-warm", "2", "--idle-ttl", "300")
    assert proc.returncode == 0, f"proc failed: {proc.stderr}"
    assert len(MockHTTPHandler.recorded_requests) == 1
    req = MockHTTPHandler.recorded_requests[0]
    assert req["method"] == "PUT"
    assert req["path"] == "/api/v1/task-chains/chain_test123/fleets/agt_worker"
    body = json.loads(req["body"])
    assert body == {"capacity": 5, "min_warm": 2, "idle_ttl_seconds": 300}, f"unexpected body: {body}"
    print("PASS: user-mode task-chains fleet set")

    # 3. tasks create with durable agent_id
    MockHTTPHandler.recorded_requests.clear()
    proc = run_ctl("tasks", "create", "--chain", "chain_test123", "--title", "Fleet Task", "--assignee", "agt_worker", "--reviewer", "agt_reviewer")
    assert proc.returncode == 0, f"proc failed: {proc.stderr}"
    assert len(MockHTTPHandler.recorded_requests) == 1
    req = MockHTTPHandler.recorded_requests[0]
    assert req["method"] == "POST"
    assert req["path"] == "/api/v1/task-chains/chain_test123/tasks"
    body = json.loads(req["body"])
    assert body.get("title") == "Fleet Task"
    assert body.get("assignee_ref") == {"type": "agent_id", "agent_id": "agt_worker"}, f"unexpected assignee_ref: {body.get('assignee_ref')}"
    assert body.get("reviewer_refs") == [{"type": "agent_id", "agent_id": "agt_reviewer"}], f"unexpected reviewer_refs: {body.get('reviewer_refs')}"
    print("PASS: user-mode tasks create with agt_ refs")

    # 4. tasks create with agent_instance
    MockHTTPHandler.recorded_requests.clear()
    proc = run_ctl("tasks", "create", "--chain", "chain_test123", "--title", "Inst Task", "--assignee", "inst_worker", "--reviewer", "inst_reviewer")
    assert proc.returncode == 0, f"proc failed: {proc.stderr}"
    assert len(MockHTTPHandler.recorded_requests) == 1
    req = MockHTTPHandler.recorded_requests[0]
    assert req["method"] == "POST"
    body = json.loads(req["body"])
    assert body.get("title") == "Inst Task"
    assert body.get("assignee_ref") == {"type": "agent_instance", "agent_instance_id": "inst_worker"}, f"unexpected assignee_ref: {body.get('assignee_ref')}"
    assert body.get("reviewer_refs") == [{"type": "agent_instance", "agent_instance_id": "inst_reviewer"}], f"unexpected reviewer_refs: {body.get('reviewer_refs')}"
    print("PASS: user-mode tasks create with inst_ refs")

    server.shutdown()


def test_agent_mode():
    print("--- Running test_agent_mode ---")
    recorded_rpc_calls = []

    # Create mock bridge JSONL server on TCP
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.listen(5)

    running = True

    def bridge_server():
        while running:
            try:
                conn, _ = sock.accept()
            except Exception:
                break
            with conn:
                f = conn.makefile("r")
                for line in f:
                    if not line.strip():
                        continue
                    msg = json.loads(line)
                    recorded_rpc_calls.append(msg)
                    method = msg.get("method")
                    req_id = msg.get("id", "test")
                    if method == "agent.rest.request":
                        resp = {"v": 1, "id": req_id, "ok": True, "data": {"status": 200, "body": '{"ok":true}'}}
                    elif method == "agent.context.get":
                        resp = {"v": 1, "id": req_id, "ok": True, "data": {"chain_id": "chain_ctx_456"}}
                    else:
                        resp = {"v": 1, "id": req_id, "ok": True, "data": {}}
                    conn.sendall((json.dumps(resp, separators=(",", ":")) + "\n").encode("utf-8"))

    t = threading.Thread(target=bridge_server, daemon=True)
    t.start()

    env = {
        "PATH": os.environ.get("PATH", ""),
        "HOME": os.environ.get("HOME", "/tmp"),
        "HEIMDALL_BRIDGE_ENDPOINT": f"tcp:127.0.0.1:{port}",
        "HEIMDALL_AGENT_TOKEN": "hlat_agent_test_tok",
    }

    def run_ctl(*args):
        cmd = [CTL_BIN] + list(args)
        proc = subprocess.run(cmd, capture_output=True, text=True, env=env)
        return proc

    # 1. task-chain fleet list with explicit chain
    recorded_rpc_calls.clear()
    proc = run_ctl("task-chain", "fleet", "list", "chain_test123")
    assert proc.returncode == 0, f"proc failed: {proc.stderr} {proc.stdout}"
    assert len(recorded_rpc_calls) == 1
    rpc = recorded_rpc_calls[0]
    assert rpc.get("method") == "agent.rest.request"
    params = rpc.get("params", {})
    assert params.get("http_method") == "GET"
    assert params.get("path") == "/api/v1/task-chains/chain_test123/fleets"
    print("PASS: agent-mode task-chain fleet list (explicit chain)")

    # 2. task-chain fleet list with context fallback
    recorded_rpc_calls.clear()
    proc = run_ctl("task-chain", "fleet", "list")
    assert proc.returncode == 0, f"proc failed: {proc.stderr} {proc.stdout}"
    # Should call agent.context.get then agent.rest.request
    assert len(recorded_rpc_calls) == 2
    assert recorded_rpc_calls[0].get("method") == "agent.context.get"
    assert recorded_rpc_calls[1].get("method") == "agent.rest.request"
    params = recorded_rpc_calls[1].get("params", {})
    assert params.get("http_method") == "GET"
    assert params.get("path") == "/api/v1/task-chains/chain_ctx_456/fleets"
    print("PASS: agent-mode task-chain fleet list (context chain)")

    # 3. task-chain fleet set
    recorded_rpc_calls.clear()
    proc = run_ctl("task-chain", "fleet", "set", "chain_test123", "--agent", "agt_worker", "--capacity", "4", "--min-warm", "1", "--idle-ttl", "120")
    assert proc.returncode == 0, f"proc failed: {proc.stderr} {proc.stdout}"
    assert len(recorded_rpc_calls) == 1
    rpc = recorded_rpc_calls[0]
    assert rpc.get("method") == "agent.rest.request"
    params = rpc.get("params", {})
    assert params.get("http_method") == "PUT"
    assert params.get("path") == "/api/v1/task-chains/chain_test123/fleets/agt_worker"
    body = json.loads(params.get("body", "{}"))
    assert body == {"capacity": 4, "min_warm": 1, "idle_ttl_seconds": 120}, f"unexpected body: {body}"
    print("PASS: agent-mode task-chain fleet set")

    # 4. task create with durable agt_ refs
    recorded_rpc_calls.clear()
    proc = run_ctl("task", "create", "--chain", "chain_test123", "--title", "Agent Mode Task", "--assignee", "agt_worker", "--reviewer", "agt_rev1,agt_rev2")
    assert proc.returncode == 0, f"proc failed: {proc.stderr} {proc.stdout}"
    assert len(recorded_rpc_calls) == 1
    rpc = recorded_rpc_calls[0]
    assert rpc.get("method") == "agent.task.create"
    params = rpc.get("params", {})
    assert params.get("title") == "Agent Mode Task"
    assert params.get("assignee_ref") == {"type": "agent_id", "agent_id": "agt_worker"}, f"unexpected assignee: {params.get('assignee_ref')}"
    assert params.get("reviewer_refs") == [
        {"type": "agent_id", "agent_id": "agt_rev1"},
        {"type": "agent_id", "agent_id": "agt_rev2"}
    ], f"unexpected reviewers: {params.get('reviewer_refs')}"
    print("PASS: agent-mode task create with agt_ refs")

    # 5. task create with inst_ refs
    recorded_rpc_calls.clear()
    proc = run_ctl("task", "create", "--chain", "chain_test123", "--title", "Agent Mode Inst", "--assignee", "inst_worker", "--reviewer", "inst_rev")
    assert proc.returncode == 0, f"proc failed: {proc.stderr} {proc.stdout}"
    assert len(recorded_rpc_calls) == 1
    rpc = recorded_rpc_calls[0]
    assert rpc.get("method") == "agent.task.create"
    params = rpc.get("params", {})
    assert params.get("title") == "Agent Mode Inst"
    assert params.get("assignee_ref") == {"type": "agent_instance", "agent_instance_id": "inst_worker"}, f"unexpected assignee: {params.get('assignee_ref')}"
    assert params.get("reviewer_refs") == [
        {"type": "agent_instance", "agent_instance_id": "inst_rev"}
    ], f"unexpected reviewers: {params.get('reviewer_refs')}"
    print("PASS: agent-mode task create with inst_ refs")

    # 6. task update with durable agt_ refs
    recorded_rpc_calls.clear()
    proc = run_ctl("task", "update", "task_999", "--assignee", "agt_worker", "--reviewer", "agt_rev")
    assert proc.returncode == 0, f"proc failed: {proc.stderr} {proc.stdout}"
    assert len(recorded_rpc_calls) == 1
    rpc = recorded_rpc_calls[0]
    assert rpc.get("method") == "agent.task.update"
    params = rpc.get("params", {})
    assert params.get("task_id") == "task_999"
    assert params.get("assignee_ref") == {"type": "agent_id", "agent_id": "agt_worker"}, f"unexpected assignee: {params.get('assignee_ref')}"
    assert params.get("reviewer_refs") == [
        {"type": "agent_id", "agent_id": "agt_rev"}
    ], f"unexpected reviewers: {params.get('reviewer_refs')}"
    print("PASS: agent-mode task update with agt_ refs")

    non_local_running = False
    sock.close()


def main():
    test_user_mode()
    test_agent_mode()
    print("\nALL FLEET CTL TESTS PASSED!")


if __name__ == "__main__":
    main()
