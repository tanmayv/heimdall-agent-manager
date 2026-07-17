#!/usr/bin/env python3
import base64
import json
import os
import re
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
SHARED_TOKEN = 'shared-peer-secret'
ARTIFACT_LINK_RE = re.compile(r'artifact://(art_[a-f0-9]+)')


def require(condition: bool, message: str):
    if not condition:
        print(f'FAIL: {message}')
        sys.exit(1)


def bin_path() -> str:
    env = os.environ.get('HEIMDALL_DAEMON_BIN')
    if env and Path(env).exists():
        return env
    candidate = ROOT / 'result' / 'bin' / 'ham-daemon'
    if candidate.exists():
        return str(candidate)
    raise RuntimeError('missing ham-daemon binary; set HEIMDALL_DAEMON_BIN')


def free_port() -> int:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(('127.0.0.1', 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


def request_json(base: str, path: str, method: str = 'GET', body=None, headers=None, expect_status: int = 200):
    data = None
    req_headers = {'Content-Type': 'application/json'}
    if headers:
        req_headers.update(headers)
    if body is not None:
        data = json.dumps(body).encode('utf-8')
    req = Request(base + path, data=data, headers=req_headers, method=method)
    try:
        with urlopen(req, timeout=10) as resp:
            payload = resp.read().decode('utf-8')
            status = resp.status
    except HTTPError as err:
        payload = err.read().decode('utf-8')
        status = err.code
    except URLError as err:
        raise RuntimeError(f'request failed: {path}: {err}') from err
    require(status == expect_status, f'{method} {path} expected {expect_status}, got {status}: {payload}')
    if not payload:
        return {}
    try:
        return json.loads(payload)
    except json.JSONDecodeError as err:
        raise RuntimeError(f'invalid json from {path}: {payload}') from err


def request_bytes(base: str, path: str, headers=None, expect_status: int = 200):
    req = Request(base + path, headers=headers or {}, method='GET')
    try:
        with urlopen(req, timeout=10) as resp:
            payload = resp.read()
            status = resp.status
    except HTTPError as err:
        payload = err.read()
        status = err.code
    except URLError as err:
        raise RuntimeError(f'request failed: {path}: {err}') from err
    require(status == expect_status, f'GET {path} expected {expect_status}, got {status}: {payload!r}')
    return payload


def authed_post(base: str, path: str, client_token: str, body: dict, expect_status: int = 200):
    return request_json(base, path, method='POST', body=body, headers={'Authorization': f'Bearer {client_token}'}, expect_status=expect_status)


def wait_for_health(base: str):
    for _ in range(100):
        try:
            if request_json(base, '/health').get('ok'):
                return
        except Exception:
            time.sleep(0.1)
    raise RuntimeError(f'daemon {base} did not become healthy')


def wait_for(predicate, message: str, timeout: float = 10.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.1)
    raise RuntimeError(message)


def write_config(path: Path, daemon_id: str, port: int, data_dir: Path, peer_name: str, peer_endpoint: str):
    path.write_text(
        '\n'.join([
            '[daemon]',
            'bind_host = "127.0.0.1"',
            f'port = {port}',
            f'data_dir = "{data_dir}"',
            f'daemon_id = "{daemon_id}"',
            '',
            '[guide_agent]',
            'enabled = false',
            'autostart = false',
            'restart_if_stopped = false',
            '',
            '[[peer]]',
            f'name = "{peer_name}"',
            f'endpoint = "{peer_endpoint}"',
            f'token = "{SHARED_TOKEN}"',
        ]),
        encoding='utf-8',
    )


def start_daemon(daemon_bin: str, cfg: Path):
    proc = subprocess.Popen([daemon_bin, '--config', str(cfg)], cwd=str(ROOT), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return proc


def stop_daemon(proc: subprocess.Popen):
    if proc.poll() is not None:
        return
    proc.terminate()
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=10)


def register_agent(base: str, agent_instance_id: str) -> str:
    data = request_json(base, '/register', method='POST', body={
        'agent_instance_id': agent_instance_id,
        'display_name': agent_instance_id,
    })
    token = data.get('agent_token', '')
    require(token, f'register should return token for {agent_instance_id}: {data}')
    return token


def user_client(base: str, suffix: str) -> str:
    data = request_json(base, '/user-client/register', method='POST', body={
        'user_id': 'operator@local',
        'client_instance_id': f'ui-{suffix}-{int(time.time() * 1000)}',
        'client_token': '',
    })
    return data['client_token']


def create_remote_review_task(base_a: str, operator_a: str, chain_id: str, title: str, proxy_id: str) -> str:
    task = request_json(base_a, '/tasks/create', method='POST', body={
        'agent_token': operator_a,
        'chain_id': chain_id,
        'title': title,
        'description': title,
        'status': 'in_progress',
    })
    task_id = task['task_id']
    request_json(base_a, '/tasks/participant', method='POST', body={
        'agent_token': operator_a,
        'task_id': task_id,
        'chain_id': chain_id,
        'agent_instance_id': proxy_id,
        'role': 'lgtm_required',
    })
    request_json(base_a, '/tasks/status', method='POST', body={
        'agent_token': operator_a,
        'task_id': task_id,
        'chain_id': chain_id,
        'status': 'review_ready',
        'body': 'ready for remote review',
    })
    return task_id


def extract_artifact_id(comment_body: str) -> str:
    match = ARTIFACT_LINK_RE.search(comment_body or '')
    require(match is not None, f'expected artifact link in comment body: {comment_body!r}')
    return match.group(1)


def main():
    daemon_bin = bin_path()
    temp_dir = Path(tempfile.mkdtemp(prefix='fed-phase45-'))
    port_a = free_port()
    port_b = free_port()
    base_a = f'http://127.0.0.1:{port_a}'
    base_b = f'http://127.0.0.1:{port_b}'
    cfg_a = temp_dir / 'a.toml'
    cfg_b = temp_dir / 'b.toml'
    write_config(cfg_a, 'fed-a', port_a, temp_dir / 'data-a', 'peer-b', base_b)
    write_config(cfg_b, 'fed-b', port_b, temp_dir / 'data-b', 'peer-a', base_a)

    proc_a = start_daemon(daemon_bin, cfg_a)
    proc_b = start_daemon(daemon_bin, cfg_b)
    try:
        wait_for_health(base_a)
        wait_for_health(base_b)
        operator_a = user_client(base_a, 'a')
        operator_b = user_client(base_b, 'b')
        register_agent(base_a, 'assignee@s-fed-a')
        reviewer_token = register_agent(base_b, 'reviewer@s-fed-b')

        authed_post(base_a, '/federation/peers/reconnect', operator_a, {'peer_id': 'peer-b'})
        authed_post(base_b, '/federation/peers/reconnect', operator_b, {'peer_id': 'peer-a'})
        bind = authed_post(base_a, '/federation/proxies/bind', operator_a, {
            'peer_id': 'peer-b',
            'origin_daemon_id': 'fed-b',
            'remote_agent_instance_id': 'reviewer@s-fed-b',
            'display_name': 'Remote Reviewer',
            'template_id': 'reviewer',
            'provider_profile': 'pi',
            'model_tier': 'normal',
            'agent_role': 'reviewer',
        })
        proxy_id = bind['agent']['agent_instance_id']

        chain = request_json(base_a, '/task-chains/create', method='POST', body={
            'agent_token': operator_a,
            'title': 'Phase45 remote review chain',
            'description': 'phase45 federation',
            'status': 'in_progress',
            'kind': 'coding',
            'coordinator_agent_instance_id': '',
        })
        chain_id = chain['chain_id']

        task1 = create_remote_review_task(base_a, operator_a, chain_id, 'Artifact review task', proxy_id)
        remote_next = wait_for(lambda: request_json(base_b, '/tasks/next', method='POST', body={'agent_token': reviewer_token}).get('task'), 'reviewer did not receive first task')
        require(remote_next.get('task_id') == task1, f'expected first remote task {task1}, got {remote_next}')

        artifact_bytes = b'# remote review artifact\nphase45\n'
        request_json(base_b, '/tasks/comment', method='POST', body={
            'agent_token': reviewer_token,
            'task_id': task1,
            'chain_id': chain_id,
            'body': 'remote reviewer attached artifact',
            'artifact_name': 'remote-review.md',
            'artifact_kind': 'markdown',
            'artifact_content_base64': base64.b64encode(artifact_bytes).decode('ascii'),
        })
        owner_comments = wait_for(lambda: request_json(base_a, '/tasks/comments', method='POST', body={'agent_token': operator_a, 'task_id': task1}).get('comments'), 'owner did not receive artifact comment')
        matching = [c for c in owner_comments if c.get('body', '').startswith('remote reviewer attached artifact')]
        require(len(matching) == 1, f'expected one artifact comment, got {owner_comments}')
        owner_artifact_id = extract_artifact_id(matching[0]['body'])
        meta = request_json(base_a, f'/artifacts/{owner_artifact_id}', headers={'Authorization': f'Bearer {operator_a}'})['artifact']
        require(meta.get('origin_kind') == 'federation_remote', f'owner artifact should be a remote reference: {meta}')
        fetched_bytes = request_bytes(base_a, f'/artifacts/{owner_artifact_id}/content?token={operator_a}')
        require(fetched_bytes == artifact_bytes, f'fetched artifact bytes mismatch: {fetched_bytes!r}')

        workspace_pointer = request_json(base_b, '/artifacts/create', method='POST', headers={'Authorization': f'Bearer {operator_b}'}, body={
            'name': 'workspace-pointer.md',
            'kind': 'markdown',
            'origin_kind': 'workspace_pointer',
            'content_base64': base64.b64encode(b'# pointer\n').decode('ascii'),
        })['artifact']['artifact_id']
        request_bytes(base_b, f'/federation/artifacts/{workspace_pointer}?peer_token={SHARED_TOKEN}&peer_daemon_id=fed-a', expect_status=403)

        stop_daemon(proc_b)
        authed_post(base_a, '/federation/peers/reconnect', operator_a, {'peer_id': 'peer-b'})
        attention = request_json(base_a, f'/attention?agent_token={operator_a}', headers={'Authorization': f'Bearer {operator_a}'})
        blocked = [row for row in attention.get('blocked', []) if row.get('task_id') == task1]
        require(len(blocked) == 1 and blocked[0].get('proxy_agent_instance_id') == proxy_id, f'expected blocked remote reviewer item for task1: {attention}')
        request_json(base_a, '/tasks/participant/remove', method='POST', body={
            'agent_token': operator_a,
            'task_id': task1,
            'chain_id': chain_id,
            'agent_instance_id': proxy_id,
            'role': 'lgtm_required',
        })
        attention_after = request_json(base_a, f'/attention?agent_token={operator_a}', headers={'Authorization': f'Bearer {operator_a}'})
        require(not [row for row in attention_after.get('blocked', []) if row.get('task_id') == task1], f'blocked attention should clear after reviewer removal: {attention_after}')

        proc_b = start_daemon(daemon_bin, cfg_b)
        wait_for_health(base_b)
        operator_b = user_client(base_b, 'b2')
        reviewer_token = register_agent(base_b, 'reviewer@s-fed-b')
        task2 = create_remote_review_task(base_a, operator_a, chain_id, 'Replay review task', proxy_id)
        authed_post(base_a, '/federation/peers/reconnect', operator_a, {'peer_id': 'peer-b'})
        remote_next_2 = wait_for(lambda: request_json(base_b, '/tasks/next', method='POST', body={'agent_token': reviewer_token}).get('task'), 'reviewer did not receive replay task after relink')
        require(remote_next_2.get('task_id') == task2, f'expected second remote task {task2}, got {remote_next_2}')

        print('federation_phase45_artifact_attention_replay_e2e: ok')
    finally:
        stop_daemon(proc_a)
        stop_daemon(proc_b)
        shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == '__main__':
    main()
