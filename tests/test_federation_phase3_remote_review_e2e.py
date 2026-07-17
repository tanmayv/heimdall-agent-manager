#!/usr/bin/env python3
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
SHARED_TOKEN = "shared-peer-secret"


def require(condition: bool, message: str):
    if not condition:
        print(f"FAIL: {message}")
        sys.exit(1)


def bin_path() -> str:
    env = os.environ.get("HEIMDALL_DAEMON_BIN")
    if env and Path(env).exists():
        return env
    candidate = ROOT / "result" / "bin" / "ham-daemon"
    if candidate.exists():
        return str(candidate)
    raise RuntimeError("missing ham-daemon binary; set HEIMDALL_DAEMON_BIN")


def free_port() -> int:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


def request_json(base: str, path: str, method: str = "GET", body=None, headers=None, expect_status: int = 200):
    data = None
    req_headers = {"Content-Type": "application/json"}
    if headers:
        req_headers.update(headers)
    if body is not None:
        data = json.dumps(body).encode("utf-8")
    req = Request(base + path, data=data, headers=req_headers, method=method)
    try:
        with urlopen(req, timeout=5) as resp:
            payload = resp.read().decode("utf-8")
            status = resp.status
    except HTTPError as err:
        payload = err.read().decode("utf-8")
        status = err.code
    except URLError as err:
        raise RuntimeError(f"request failed: {path}: {err}") from err
    require(status == expect_status, f"{method} {path} expected {expect_status}, got {status}: {payload}")
    return json.loads(payload)


def authed_post(base: str, path: str, client_token: str, body: dict, expect_status: int = 200):
    return request_json(base, path, method="POST", body=body, headers={"Authorization": f"Bearer {client_token}"}, expect_status=expect_status)


def wait_for_health(base: str):
    for _ in range(100):
        try:
            if request_json(base, "/health").get("ok"):
                return
        except Exception:
            time.sleep(0.1)
    raise RuntimeError(f"daemon {base} did not become healthy")


def wait_for(predicate, message: str, timeout: float = 8.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.1)
    raise RuntimeError(message)


def write_config(path: Path, daemon_id: str, port: int, data_dir: Path, peer_name: str, peer_endpoint: str):
    path.write_text(
        "\n".join([
            "[daemon]",
            'bind_host = "127.0.0.1"',
            f"port = {port}",
            f'data_dir = "{data_dir}"',
            f'daemon_id = "{daemon_id}"',
            "",
            "[guide_agent]",
            "enabled = false",
            "autostart = false",
            "restart_if_stopped = false",
            "",
            "[[peer]]",
            f'name = "{peer_name}"',
            f'endpoint = "{peer_endpoint}"',
            f'token = "{SHARED_TOKEN}"',
        ]),
        encoding="utf-8",
    )


def register_agent(base: str, agent_instance_id: str):
    data = request_json(base, "/register", method="POST", body={
        "agent_instance_id": agent_instance_id,
        "display_name": agent_instance_id,
    })
    token = data.get("agent_token", "")
    require(token, f"register should return token for {agent_instance_id}: {data}")
    return token


def user_client(base: str):
    data = request_json(base, "/user-client/register", method="POST", body={
        "user_id": "operator@local",
        "client_instance_id": f"ui-{int(time.time() * 1000)}",
        "client_token": "",
    })
    return data["client_token"]


def main():
    daemon_bin = bin_path()
    temp_dir = Path(tempfile.mkdtemp(prefix="fed-phase3-"))
    port_a = free_port()
    port_b = free_port()
    base_a = f"http://127.0.0.1:{port_a}"
    base_b = f"http://127.0.0.1:{port_b}"
    cfg_a = temp_dir / "a.toml"
    cfg_b = temp_dir / "b.toml"
    write_config(cfg_a, "fed-a", port_a, temp_dir / "data-a", "peer-b", base_b)
    write_config(cfg_b, "fed-b", port_b, temp_dir / "data-b", "peer-a", base_a)

    proc_a = subprocess.Popen([daemon_bin, "--config", str(cfg_a)], cwd=str(ROOT), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    proc_b = subprocess.Popen([daemon_bin, "--config", str(cfg_b)], cwd=str(ROOT), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        wait_for_health(base_a)
        wait_for_health(base_b)

        operator_a = user_client(base_a)
        operator_b = user_client(base_b)
        assignee_a = "assignee@s-fed-a"
        reviewer_b = "reviewer@s-fed-b"
        register_agent(base_a, assignee_a)
        reviewer_token = register_agent(base_b, reviewer_b)

        authed_post(base_a, "/federation/peers/reconnect", operator_a, {"peer_id": "peer-b"})
        authed_post(base_b, "/federation/peers/reconnect", operator_b, {"peer_id": "peer-a"})

        bind = authed_post(base_a, "/federation/proxies/bind", operator_a, {
            "peer_id": "peer-b",
            "origin_daemon_id": "fed-b",
            "remote_agent_instance_id": reviewer_b,
            "display_name": "Remote Reviewer",
            "template_id": "reviewer",
            "provider_profile": "pi",
            "model_tier": "normal",
            "agent_role": "reviewer",
        })
        proxy_id = bind["agent"]["agent_instance_id"]
        require(proxy_id and proxy_id != reviewer_b, f"bind should return a local proxy id: {bind}")

        chain = request_json(base_a, "/task-chains/create", method="POST", body={
            "agent_token": operator_a,
            "title": "Remote review chain",
            "description": "phase3 federation",
            "status": "in_progress",
            "kind": "coding",
            "coordinator_agent_instance_id": "",
        })
        chain_id = chain["chain_id"]

        task = request_json(base_a, "/tasks/create", method="POST", body={
            "agent_token": operator_a,
            "chain_id": chain_id,
            "title": "Remote review task",
            "description": "review via federation",
            "status": "in_progress",
            "assignee_agent_instance_id": assignee_a,
        })
        task_id = task["task_id"]

        request_json(base_a, "/tasks/participant", method="POST", body={
            "agent_token": operator_a,
            "task_id": task_id,
            "chain_id": chain_id,
            "agent_instance_id": proxy_id,
            "role": "lgtm_required",
        })

        request_json(base_a, "/tasks/status", method="POST", body={
            "agent_token": operator_a,
            "task_id": task_id,
            "chain_id": chain_id,
            "status": "review_ready",
            "body": "ready for remote review",
        })

        remote_next = wait_for(
            lambda: request_json(base_b, "/tasks/next", method="POST", body={
                "agent_token": reviewer_token,
            }).get("task"),
            "remote reviewer did not receive next task",
        )
        require(remote_next.get("task_id") == task_id, f"remote next should point at owner task: {remote_next}")

        remote_list = request_json(base_b, "/tasks/list", method="POST", body={"agent_token": reviewer_token})
        require(any(t.get("task_id") == task_id for t in remote_list.get("tasks", [])), f"remote task list should include owner task: {remote_list}")

        remote_show = request_json(base_b, "/tasks/show", method="POST", body={
            "agent_token": reviewer_token,
            "task_id": task_id,
        })["task"]
        require(remote_show.get("task_id") == task_id and remote_show.get("chain_id") == chain_id, f"remote show should proxy owner task: {remote_show}")

        remote_comments_before = request_json(base_b, "/tasks/comments", method="POST", body={
            "agent_token": reviewer_token,
            "task_id": task_id,
        })
        require(remote_comments_before.get("comments") == [], f"remote comments should start empty: {remote_comments_before}")

        request_json(base_b, "/tasks/comment", method="POST", body={
            "agent_token": reviewer_token,
            "task_id": task_id,
            "chain_id": chain_id,
            "body": "remote reviewer comment",
        })

        owner_comments = wait_for(
            lambda: request_json(base_a, "/tasks/comments", method="POST", body={
                "agent_token": operator_a,
                "task_id": task_id,
            }).get("comments"),
            "owner did not receive remote comment",
        )
        require(any(c.get("body") == "remote reviewer comment" and c.get("author_agent_instance_id") == proxy_id for c in owner_comments), f"owner should store remote comment as proxy identity: {owner_comments}")

        callback_path_a = f"/federation/callback?peer_token={SHARED_TOKEN}&peer_daemon_id=fed-b"
        duplicate_payload = {
            "kind": "comment",
            "idempotency_key": "phase3-dup-comment",
            "origin_daemon_id": "fed-a",
            "actor_origin_daemon_id": "fed-b",
            "task_id": task_id,
            "chain_id": chain_id,
            "proxy_agent_instance_id": proxy_id,
            "from_agent_instance_id": reviewer_b,
            "body": "duplicate callback comment",
        }
        request_json(base_a, callback_path_a, method="POST", body=duplicate_payload)
        request_json(base_a, callback_path_a, method="POST", body=duplicate_payload)
        owner_comments_after_dup = request_json(base_a, "/tasks/comments", method="POST", body={
            "agent_token": operator_a,
            "task_id": task_id,
        }).get("comments", [])
        require(sum(1 for c in owner_comments_after_dup if c.get("body") == "duplicate callback comment") == 1, f"duplicate callback should create one comment: {owner_comments_after_dup}")

        forged = dict(duplicate_payload)
        forged["idempotency_key"] = "phase3-forged-comment"
        forged["from_agent_instance_id"] = "intruder@s-fed-b"
        request_json(base_a, callback_path_a, method="POST", body=forged, expect_status=403)

        wrong_origin = dict(duplicate_payload)
        wrong_origin["idempotency_key"] = "phase3-wrong-origin"
        wrong_origin["origin_daemon_id"] = "fed-z"
        request_json(base_a, callback_path_a, method="POST", body=wrong_origin, expect_status=403)

        request_json(base_b, "/tasks/vote", method="POST", body={
            "agent_token": reviewer_token,
            "task_id": task_id,
            "chain_id": chain_id,
            "result": "lgtm",
            "comment": "remote reviewer approves",
        })

        owner_task = wait_for(
            lambda: request_json(base_a, "/tasks/show", method="POST", body={
                "agent_token": operator_a,
                "task_id": task_id,
            }).get("task"),
            "owner task did not refresh after remote vote",
        )
        require(owner_task.get("status") == "approved", f"remote vote should approve owner task: {owner_task}")
        require(any(v.get("reviewer_agent_instance_id") == proxy_id and v.get("approved") for v in owner_task.get("votes", [])), f"owner vote should be recorded under proxy id: {owner_task}")

        print("federation_phase3_remote_review_e2e: ok")
    finally:
        for proc in (proc_a, proc_b):
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=10)
        shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
