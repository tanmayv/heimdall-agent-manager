#!/usr/bin/env python3
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
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


def write_config(path: Path, daemon_id: str, port: int, data_dir: Path, peers: list[tuple[str, str]]):
    lines = [
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
    ]
    for peer_name, peer_endpoint in peers:
        lines.extend([
            "",
            "[[peer]]",
            f'name = "{peer_name}"',
            f'endpoint = "{peer_endpoint}"',
            f'token = "{SHARED_TOKEN}"',
        ])
    path.write_text("\n".join(lines), encoding="utf-8")


def register_agent(base: str, agent_instance_id: str):
    data = request_json(base, "/register", method="POST", body={
        "agent_instance_id": agent_instance_id,
        "display_name": agent_instance_id,
    })
    token = data.get("agent_token", "")
    require(token, f"register should return token for {agent_instance_id}: {data}")
    return token


def user_client(base: str, suffix: str):
    data = request_json(base, "/user-client/register", method="POST", body={
        "user_id": "operator@local",
        "client_instance_id": f"ui-{suffix}-{int(time.time() * 1000)}",
        "client_token": "",
    })
    return data["client_token"]


def create_task(base: str, operator_token: str, chain_id: str, title: str, assignee: str) -> str:
    body = {
        "agent_token": operator_token,
        "chain_id": chain_id,
        "title": title,
        "description": title,
        "status": "in_progress",
    }
    if assignee:
        body["assignee_agent_instance_id"] = assignee
    task = request_json(base, "/tasks/create", method="POST", body=body)
    return task["task_id"]


def prepare_remote_review_task(base: str, operator_token: str, task_id: str, chain_id: str, proxy_id: str):
    request_json(base, "/tasks/participant", method="POST", body={
        "agent_token": operator_token,
        "task_id": task_id,
        "chain_id": chain_id,
        "agent_instance_id": proxy_id,
        "role": "lgtm_required",
    })
    request_json(base, "/tasks/status", method="POST", body={
        "agent_token": operator_token,
        "task_id": task_id,
        "chain_id": chain_id,
        "status": "review_ready",
        "body": "ready for remote review",
    })


def main():
    daemon_bin = bin_path()
    temp_dir = Path(tempfile.mkdtemp(prefix="fed-phase3-collision-"))
    port_a = free_port()
    port_b = free_port()
    port_c = free_port()
    base_a = f"http://127.0.0.1:{port_a}"
    base_b = f"http://127.0.0.1:{port_b}"
    base_c = f"http://127.0.0.1:{port_c}"
    cfg_a = temp_dir / "a.toml"
    cfg_b = temp_dir / "b.toml"
    cfg_c = temp_dir / "c.toml"
    write_config(cfg_a, "fed-a", port_a, temp_dir / "data-a", [("peer-b", base_b)])
    write_config(cfg_b, "fed-b", port_b, temp_dir / "data-b", [("peer-a", base_a), ("peer-c", base_c)])
    write_config(cfg_c, "fed-c", port_c, temp_dir / "data-c", [("peer-b", base_b)])

    proc_a = subprocess.Popen([daemon_bin, "--config", str(cfg_a)], cwd=str(ROOT), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    proc_b = subprocess.Popen([daemon_bin, "--config", str(cfg_b)], cwd=str(ROOT), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    proc_c = subprocess.Popen([daemon_bin, "--config", str(cfg_c)], cwd=str(ROOT), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        wait_for_health(base_a)
        wait_for_health(base_b)
        wait_for_health(base_c)

        operator_a = user_client(base_a, "a")
        operator_b = user_client(base_b, "b")
        operator_c = user_client(base_c, "c")
        reviewer_b = "reviewer@s-fed-b"
        assignee_a = "assignee@s-fed-a"
        assignee_c = "assignee@s-fed-c"
        reviewer_token = register_agent(base_b, reviewer_b)
        register_agent(base_a, assignee_a)
        register_agent(base_c, assignee_c)

        authed_post(base_a, "/federation/peers/reconnect", operator_a, {"peer_id": "peer-b"})
        authed_post(base_b, "/federation/peers/reconnect", operator_b, {"peer_id": "peer-a"})
        authed_post(base_b, "/federation/peers/reconnect", operator_b, {"peer_id": "peer-c"})
        authed_post(base_c, "/federation/peers/reconnect", operator_c, {"peer_id": "peer-b"})

        bind_a = authed_post(base_a, "/federation/proxies/bind", operator_a, {
            "peer_id": "peer-b",
            "origin_daemon_id": "fed-b",
            "remote_agent_instance_id": reviewer_b,
            "display_name": "Remote Reviewer B",
            "template_id": "reviewer",
            "provider_profile": "pi",
            "model_tier": "normal",
            "agent_role": "reviewer",
        })
        bind_c = authed_post(base_c, "/federation/proxies/bind", operator_c, {
            "peer_id": "peer-b",
            "origin_daemon_id": "fed-b",
            "remote_agent_instance_id": reviewer_b,
            "display_name": "Remote Reviewer B",
            "template_id": "reviewer",
            "provider_profile": "pi",
            "model_tier": "normal",
            "agent_role": "reviewer",
        })
        proxy_a = bind_a["agent"]["agent_instance_id"]
        proxy_c = bind_c["agent"]["agent_instance_id"]

        chain_id = "chain-collision-phase3"
        for base, token, title in ((base_a, operator_a, "Collision owner A"), (base_c, operator_c, "Collision owner C")):
            request_json(base, "/task-chains/create", method="POST", body={
                "agent_token": token,
                "chain_id": chain_id,
                "title": title,
                "description": title,
                "status": "in_progress",
                "kind": "coding",
                "coordinator_agent_instance_id": "",
            })

        collision_pair = None
        for attempt in range(1000):
            with ThreadPoolExecutor(max_workers=2) as pool:
                future_a = pool.submit(create_task, base_a, operator_a, chain_id, f"Collision owner A {attempt}", "")
                future_c = pool.submit(create_task, base_c, operator_c, chain_id, f"Collision owner C {attempt}", "")
                task_id_a = future_a.result()
                task_id_c = future_c.result()
            if task_id_a == task_id_c:
                collision_pair = (task_id_a, task_id_c)
                break
        require(collision_pair is not None, "failed to generate same-ms task id collision across two owner daemons")
        task_id = collision_pair[0]

        prepare_remote_review_task(base_a, operator_a, task_id, chain_id, proxy_a)
        prepare_remote_review_task(base_c, operator_c, task_id, chain_id, proxy_c)

        remote_list = wait_for(
            lambda: request_json(base_b, "/tasks/list", method="POST", body={"agent_token": reviewer_token}).get("tasks"),
            "remote reviewer did not receive collision tasks",
        )
        collision_tasks = [task for task in remote_list if task.get("task_id") == task_id]
        require(len(collision_tasks) == 2, f"expected 2 collision tasks, got: {remote_list}")
        require({task.get("origin_daemon_id") for task in collision_tasks} == {"fed-a", "fed-c"}, f"remote tasks should expose distinct origins: {collision_tasks}")

        ambiguous_show = request_json(base_b, "/tasks/show", method="POST", body={
            "agent_token": reviewer_token,
            "task_id": task_id,
        }, expect_status=409)
        require("origin_daemon_id" in ambiguous_show.get("message", ""), f"ambiguous task show should require origin_daemon_id: {ambiguous_show}")

        exact_show = request_json(base_b, "/tasks/show", method="POST", body={
            "agent_token": reviewer_token,
            "task_id": task_id,
            "origin_daemon_id": "fed-a",
        })["task"]
        require(exact_show.get("origin_daemon_id") == "fed-a" and exact_show.get("title", "").startswith("Collision owner A "), f"exact task show should route to fed-a: {exact_show}")

        ambiguous_chain = request_json(base_b, "/task-chains/show", method="POST", body={
            "agent_token": reviewer_token,
            "chain_id": chain_id,
        }, expect_status=409)
        require("origin_daemon_id" in ambiguous_chain.get("message", ""), f"ambiguous chain show should require origin_daemon_id: {ambiguous_chain}")

        exact_chain = request_json(base_b, "/task-chains/show", method="POST", body={
            "agent_token": reviewer_token,
            "chain_id": chain_id,
            "origin_daemon_id": "fed-c",
        })["chain"]
        require(exact_chain.get("origin_daemon_id") == "fed-c" and exact_chain.get("title") == "Collision owner C", f"exact chain show should route to fed-c: {exact_chain}")

        ambiguous_comment = request_json(base_b, "/tasks/comment", method="POST", body={
            "agent_token": reviewer_token,
            "task_id": task_id,
            "chain_id": chain_id,
            "body": "should fail without origin",
        }, expect_status=409)
        require("origin_daemon_id" in ambiguous_comment.get("message", ""), f"ambiguous task comment should require origin_daemon_id: {ambiguous_comment}")

        request_json(base_b, "/tasks/comment", method="POST", body={
            "agent_token": reviewer_token,
            "task_id": task_id,
            "chain_id": chain_id,
            "origin_daemon_id": "fed-a",
            "body": "collision-safe routed comment",
        })

        owner_a_comments = wait_for(
            lambda: request_json(base_a, "/tasks/comments", method="POST", body={"agent_token": operator_a, "task_id": task_id}).get("comments"),
            "owner A did not receive collision-safe comment",
        )
        require(any(c.get("body") == "collision-safe routed comment" and c.get("author_agent_instance_id") == proxy_a for c in owner_a_comments), f"owner A should record routed comment under proxy A: {owner_a_comments}")
        owner_c_comments = request_json(base_c, "/tasks/comments", method="POST", body={"agent_token": operator_c, "task_id": task_id}).get("comments", [])
        require(all(c.get("body") != "collision-safe routed comment" for c in owner_c_comments), f"owner C should not receive fed-a scoped comment: {owner_c_comments}")

        print("federation_phase3_identity_collision_e2e: ok")
    finally:
        for proc in (proc_a, proc_b, proc_c):
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=10)
        shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
