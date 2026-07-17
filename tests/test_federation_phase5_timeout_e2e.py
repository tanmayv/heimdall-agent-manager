#!/usr/bin/env python3
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
SHARED_TOKEN = 'shared-peer-secret'


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
    return json.loads(payload)


def wait_for_health(base: str):
    for _ in range(100):
        try:
            if request_json(base, '/health').get('ok'):
                return
        except Exception:
            time.sleep(0.1)
    raise RuntimeError(f'daemon {base} did not become healthy')


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


def user_client(base: str) -> str:
    data = request_json(base, '/user-client/register', method='POST', body={
        'user_id': 'operator@local',
        'client_instance_id': f'ui-timeout-{int(time.time() * 1000)}',
        'client_token': '',
    })
    return data['client_token']


def run_hanging_peer(port: int, stop_event: threading.Event):
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(('127.0.0.1', port))
    server.listen(8)
    server.settimeout(0.2)
    try:
        while not stop_event.is_set():
            try:
                conn, _ = server.accept()
            except socket.timeout:
                continue
            conn.settimeout(0.2)
            try:
                while not stop_event.is_set():
                    time.sleep(0.2)
            finally:
                conn.close()
    finally:
        server.close()


def main():
    daemon_bin = bin_path()
    temp_dir = Path(tempfile.mkdtemp(prefix='fed-phase5-timeout-'))
    port_a = free_port()
    port_hang = free_port()
    base_a = f'http://127.0.0.1:{port_a}'
    cfg_a = temp_dir / 'a.toml'
    write_config(cfg_a, 'fed-a', port_a, temp_dir / 'data-a', 'peer-hang', f'http://127.0.0.1:{port_hang}')

    stop_event = threading.Event()
    hang_thread = threading.Thread(target=run_hanging_peer, args=(port_hang, stop_event), daemon=True)
    hang_thread.start()

    proc_a = subprocess.Popen([daemon_bin, '--config', str(cfg_a)], cwd=str(ROOT), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        wait_for_health(base_a)
        operator_a = user_client(base_a)
        start = time.time()
        response = request_json(base_a, '/federation/peers/reconnect', method='POST', body={'peer_id': 'peer-hang'}, headers={'Authorization': f'Bearer {operator_a}'})
        elapsed = time.time() - start
        require(elapsed < 8.0, f'federation reconnect should timeout promptly, took {elapsed:.2f}s')
        require(response.get('peer', {}).get('status') == 'unreachable', f'peer should surface unreachable after timeout: {response}')
        print('federation_phase5_timeout_e2e: ok')
    finally:
        proc_a.terminate()
        try:
            proc_a.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc_a.kill()
            proc_a.wait(timeout=10)
        stop_event.set()
        hang_thread.join(timeout=2)
        shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == '__main__':
    main()
