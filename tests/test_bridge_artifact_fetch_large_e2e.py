#!/usr/bin/env python3
"""Bridge-only large artifact fetch-through smoke.

This is intentionally an opt-in e2e helper: set HEIMDALL_DAEMON_BIN and
HEIMDALL_BRIDGE_BIN (or build with the local result-daemon-large/result-bridge-large
symlinks) before running. It validates that a 10 MiB opaque artifact body stays
byte-exact across daemon -> bridge loopback, bridge WS chunk/reassembly, and the
A-side artifact cache/read path.
"""
import base64
import hashlib
import json
import re
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
BRIDGE_TOKEN = 'bridge-secret'
PEER_TOKEN = 'peer-secret'
LARGE_SIZE = 10 * 1024 * 1024
ARTIFACT_RE = re.compile(r'artifact://(art_[a-f0-9]+)')


def require(condition: bool, message: str):
    if not condition:
        print(f'FAIL: {message}')
        sys.exit(1)


def binary_path(env_name: str, candidates):
    env = os.environ.get(env_name) if 'os' in globals() else None
    if env and Path(env).exists():
        return env
    for candidate in candidates:
        p = ROOT / candidate
        if p.exists():
            return str(p)
    raise RuntimeError(f'missing binary; set {env_name}')


# Import os lazily after binary_path is defined so the script stays stdlib-only.
import os  # noqa: E402


def daemon_bin() -> str:
    return binary_path('HEIMDALL_DAEMON_BIN', ['result-daemon-large/bin/ham-daemon', 'result/bin/ham-daemon'])


def bridge_bin() -> str:
    return binary_path('HEIMDALL_BRIDGE_BIN', ['result-bridge-large/bin/ham-bridge', 'result/bin/ham-bridge'])


def free_port() -> int:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(('127.0.0.1', 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


def request(base: str, path: str, method: str = 'GET', body=None, headers=None, expect: int = 200, timeout: float = 90.0, raw: bool = False):
    data = json.dumps(body).encode('utf-8') if body is not None else None
    req_headers = {'Content-Type': 'application/json'}
    if headers:
        req_headers.update(headers)
    req = Request(base + path, data=data, headers=req_headers, method=method)
    try:
        with urlopen(req, timeout=timeout) as resp:
            payload = resp.read()
            status = resp.status
    except HTTPError as err:
        payload = err.read()
        status = err.code
    except URLError as err:
        raise RuntimeError(f'{method} {path} failed: {err}') from err
    require(status == expect, f'{method} {path} expected {expect}, got {status}: {payload[:500]!r}')
    if raw:
        return payload
    if not payload:
        return {}
    return json.loads(payload.decode('utf-8'))


def wait_for_health(base: str):
    for _ in range(200):
        try:
            if request(base, '/health', timeout=5).get('ok'):
                return
        except Exception:
            time.sleep(0.1)
    raise RuntimeError(f'{base} did not become healthy')


def wait_for(predicate, message: str, timeout: float = 30.0):
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        try:
            last = predicate()
            if last:
                return last
        except Exception as err:
            last = err
        time.sleep(0.2)
    raise RuntimeError(f'{message}: {last!r}')


def write_daemon_config(path: Path, port: int, daemon_id: str, bridge_port: int, data_dir: Path):
    path.write_text(
        f'''[daemon]\nbind_host = "127.0.0.1"\nport = {port}\ndata_dir = "{data_dir}"\ndaemon_id = "{daemon_id}"\nbridge_url = "http://127.0.0.1:{bridge_port}"\nbridge_token = "{BRIDGE_TOKEN}"\nartifact_max_bytes = {LARGE_SIZE}\n[guide_agent]\nenabled = false\nautostart = false\nrestart_if_stopped = false\n''',
        encoding='utf-8',
    )


def write_bridge_config(path: Path, daemon_id: str, daemon_port: int, peer_id: str, peer_bridge_port: int):
    path.write_text(
        f'''[daemon]\ndaemon_id = "{daemon_id}"\nbridge_token = "{BRIDGE_TOKEN}"\n[wrapper]\ndaemon_url = "http://127.0.0.1:{daemon_port}"\n[[peer]]\nname = "{peer_id}"\nendpoint = "http://127.0.0.1:{peer_bridge_port}"\ntoken = "{PEER_TOKEN}"\n''',
        encoding='utf-8',
    )


def start(cmd, log_path: Path):
    return subprocess.Popen(cmd, cwd=str(ROOT), stdout=log_path.open('w'), stderr=subprocess.STDOUT, text=True)


def stop(proc):
    if proc and proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=10)


def main():
    daemon = daemon_bin()
    bridge = bridge_bin()
    temp_dir = Path(tempfile.mkdtemp(prefix='bridge-artifact-large-'))
    procs = []
    try:
        daemon_a_port, daemon_b_port = free_port(), free_port()
        bridge_a_port, bridge_b_port = free_port(), free_port()
        cfg_da = temp_dir / 'daemon-a.toml'
        cfg_db = temp_dir / 'daemon-b.toml'
        cfg_ba = temp_dir / 'bridge-a.toml'
        cfg_bb = temp_dir / 'bridge-b.toml'
        write_daemon_config(cfg_da, daemon_a_port, 'fed-a', bridge_a_port, temp_dir / 'data-a')
        write_daemon_config(cfg_db, daemon_b_port, 'fed-b', bridge_b_port, temp_dir / 'data-b')
        write_bridge_config(cfg_ba, 'fed-a', daemon_a_port, 'fed-b', bridge_b_port)
        write_bridge_config(cfg_bb, 'fed-b', daemon_b_port, 'fed-a', bridge_a_port)

        procs.append(start([daemon, '--config', str(cfg_da)], temp_dir / 'daemon-a.log'))
        procs.append(start([daemon, '--config', str(cfg_db)], temp_dir / 'daemon-b.log'))
        base_a = f'http://127.0.0.1:{daemon_a_port}'
        base_b = f'http://127.0.0.1:{daemon_b_port}'
        wait_for_health(base_a)
        wait_for_health(base_b)
        procs.append(start([bridge, '--config', str(cfg_ba), '--port', str(bridge_a_port), '--peer-auth-token', PEER_TOKEN], temp_dir / 'bridge-a.log'))
        procs.append(start([bridge, '--config', str(cfg_bb), '--port', str(bridge_b_port), '--peer-auth-token', PEER_TOKEN], temp_dir / 'bridge-b.log'))

        operator_a = request(base_a, '/user-client/register', 'POST', {'user_id': 'operator@local', 'client_instance_id': 'ui-a', 'client_token': ''})['client_token']
        operator_b = request(base_b, '/user-client/register', 'POST', {'user_id': 'operator@local', 'client_instance_id': 'ui-b', 'client_token': ''})['client_token']
        reviewer = request(base_b, '/register', 'POST', {'agent_instance_id': 'reviewer@s-b', 'display_name': 'reviewer'})['agent_token']

        wait_for(lambda: request(base_a, '/federation/peers', headers={'Authorization': f'Bearer {operator_a}'})['peers'][0]['status'] == 'linked', 'bridge A did not link')
        wait_for(lambda: request(base_b, '/federation/peers', headers={'Authorization': f'Bearer {operator_b}'})['peers'][0]['status'] == 'linked', 'bridge B did not link')

        bind = request(base_a, '/federation/proxies/bind', 'POST', {
            'peer_id': 'fed-b',
            'origin_daemon_id': 'fed-b',
            'remote_agent_instance_id': 'reviewer@s-b',
            'display_name': 'Remote Reviewer',
            'template_id': 'reviewer',
            'template_id': 'reviewer',
        }, headers={'Authorization': f'Bearer {operator_a}'})
        proxy_id = bind['agent']['agent_instance_id']
        chain_id = request(base_a, '/task-chains/create', 'POST', {'agent_token': operator_a, 'title': 'Large artifact chain', 'description': 'x', 'status': 'in_progress', 'kind': 'coding'})['chain_id']
        task_id = request(base_a, '/tasks/create', 'POST', {'agent_token': operator_a, 'chain_id': chain_id, 'title': 'Large artifact task', 'description': 'x', 'status': 'in_progress'})['task_id']
        request(base_a, '/tasks/participant', 'POST', {'agent_token': operator_a, 'task_id': task_id, 'chain_id': chain_id, 'agent_instance_id': proxy_id, 'role': 'lgtm_required'})
        request(base_a, '/tasks/status', 'POST', {'agent_token': operator_a, 'task_id': task_id, 'chain_id': chain_id, 'status': 'review_ready', 'body': 'ready'})
        wait_for(lambda: request(base_b, '/tasks/next', 'POST', {'agent_token': reviewer}).get('task'), 'remote task missing')

        prefix = b'# large bridge artifact\n'
        artifact_bytes = prefix + b'a' * (LARGE_SIZE - len(prefix))
        expected_sha = hashlib.sha256(artifact_bytes).hexdigest()
        request(base_b, '/tasks/comment', 'POST', {
            'agent_token': reviewer,
            'task_id': task_id,
            'chain_id': chain_id,
            'body': 'large artifact attached',
            'artifact_name': 'large.md',
            'artifact_kind': 'markdown',
            'artifact_content_base64': base64.b64encode(artifact_bytes).decode('ascii'),
        }, expect=202, timeout=90)

        comments = wait_for(lambda: request(base_a, '/tasks/comments', 'POST', {'agent_token': operator_a, 'task_id': task_id}).get('comments'), 'owner comments missing')
        bodies = [c['body'] for c in comments if c.get('body', '').startswith('large artifact attached')]
        require(bodies, 'owner did not receive remote artifact reference')
        artifact_id = ARTIFACT_RE.search(bodies[0]).group(1)
        meta = request(base_a, f'/artifacts/{artifact_id}', headers={'Authorization': f'Bearer {operator_a}'})['artifact']
        require(meta.get('origin_kind') == 'federation_remote', f'expected remote origin metadata: {meta}')
        fetched = request(base_a, f'/artifacts/{artifact_id}/content?token={operator_a}', timeout=120, raw=True)
        require(len(fetched) == LARGE_SIZE, f'fetched length mismatch: {len(fetched)}')
        require(hashlib.sha256(fetched).hexdigest() == expected_sha, 'fetched bytes sha mismatch')
        print(f'bridge_artifact_fetch_large_e2e: ok bytes={len(fetched)} artifact_id={artifact_id}')
    finally:
        for proc in procs:
            stop(proc)
        print(f'logs: {temp_dir}')


if __name__ == '__main__':
    main()
