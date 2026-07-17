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


def authed_request(base: str, path: str, client_token: str, method: str = 'GET', body=None, expect_status: int = 200):
    return request_json(base, path, method=method, body=body, headers={'Authorization': f'Bearer {client_token}'}, expect_status=expect_status)


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


def conv_id(agent_instance_id: str) -> str:
    out = ['conv_']
    for ch in agent_instance_id:
        if ch.isalnum() or ch in '_-':
            out.append(ch)
        else:
            out.append('_')
    return ''.join(out)


def write_config(home: Path, daemon_id: str, port: int, peer_name: str, peer_endpoint: str):
    home.mkdir(parents=True, exist_ok=True)
    (home / 'config.toml').write_text(
        '\n'.join([
            '[daemon]',
            'bind_host = "127.0.0.1"',
            f'port = {port}',
            'data_dir = "~/data"',
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


def start_daemon(daemon_bin: str, home: Path):
    env = os.environ.copy()
    env['HEIMDALL_HOME'] = str(home)
    return subprocess.Popen([daemon_bin], cwd=str(ROOT), env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)


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


def fetch_messages(base: str, agent_token: str, conversation_id: str, include_read: bool = True):
    return request_json(base, '/agent-rpc', method='POST', body={
        'agent_token': agent_token,
        'action': 'fetch_messages',
        'conversation_id': conversation_id,
        'include_read': include_read,
    }).get('messages', [])


def main():
    daemon_bin = bin_path()
    temp_root = Path(tempfile.mkdtemp(prefix='fed-fresh-home-'))
    home_a = temp_root / 'home-a'
    home_b = temp_root / 'home-b'
    port_a = free_port()
    port_b = free_port()
    base_a = f'http://127.0.0.1:{port_a}'
    base_b = f'http://127.0.0.1:{port_b}'
    write_config(home_a, 'fresh-a', port_a, 'peer-b', base_b)
    write_config(home_b, 'fresh-b', port_b, 'peer-a', base_a)

    proc_a = start_daemon(daemon_bin, home_a)
    proc_b = start_daemon(daemon_bin, home_b)
    try:
        wait_for_health(base_a)
        wait_for_health(base_b)
        operator_a = user_client(base_a, 'a')
        operator_b = user_client(base_b, 'b')
        sender_a = 'sender-a@s-fresh-a'
        sender_b = 'sender-b@s-fresh-b'
        token_a = register_agent(base_a, sender_a)
        token_b = register_agent(base_b, sender_b)

        authed_request(base_a, '/federation/peers/reconnect', operator_a, method='POST', body={'peer_id': 'peer-b'})
        authed_request(base_b, '/federation/peers/reconnect', operator_b, method='POST', body={'peer_id': 'peer-a'})
        peers_a = authed_request(base_a, '/federation/peers', operator_a)
        peers_b = authed_request(base_b, '/federation/peers', operator_b)
        require(peers_a['peers'][0]['status'] == 'linked' and peers_a['peers'][0]['daemon_id'] == 'fresh-b', f'peer A should link to fresh-b: {peers_a}')
        require(peers_b['peers'][0]['status'] == 'linked' and peers_b['peers'][0]['daemon_id'] == 'fresh-a', f'peer B should link to fresh-a: {peers_b}')

        proxy_on_a = authed_request(base_a, '/federation/proxies/bind', operator_a, method='POST', body={
            'peer_id': 'peer-b',
            'origin_daemon_id': 'fresh-b',
            'remote_agent_instance_id': sender_b,
            'display_name': 'Sender B Proxy',
            'template_id': 'reviewer',
            'provider_profile': 'pi',
            'model_tier': 'normal',
            'agent_role': 'reviewer',
        })['agent']['agent_instance_id']
        proxy_on_b = authed_request(base_b, '/federation/proxies/bind', operator_b, method='POST', body={
            'peer_id': 'peer-a',
            'origin_daemon_id': 'fresh-a',
            'remote_agent_instance_id': sender_a,
            'display_name': 'Sender A Proxy',
            'template_id': 'reviewer',
            'provider_profile': 'pi',
            'model_tier': 'normal',
            'agent_role': 'reviewer',
        })['agent']['agent_instance_id']
        require(proxy_on_a and proxy_on_b, 'proxy binds should return local proxy ids')

        body_a_to_b = f'msg-a-to-b-{int(time.time() * 1000)}'
        send_a = request_json(base_a, '/agent-rpc', method='POST', body={
            'agent_token': token_a,
            'action': 'send_message',
            'target_agent_instance_id': proxy_on_a,
            'body': body_a_to_b,
        }, expect_status=202)
        conv_b = conv_id(sender_b)
        fetched_b = wait_for(lambda: fetch_messages(base_b, token_b, conv_b, include_read=False), 'receiver B did not fetch durable body from A')
        exact_b = [m for m in fetched_b if m.get('body') == body_a_to_b]
        require(len(exact_b) == 1, f'A->B durable message body mismatch: {fetched_b}')
        require(exact_b[0].get('from_agent_instance_id') == sender_a and exact_b[0].get('target_agent_instance_id') == sender_b, f'A->B sender/target mismatch: {exact_b[0]}')

        body_b_to_a = f'msg-b-to-a-{int(time.time() * 1000)}'
        send_b = request_json(base_b, '/agent-rpc', method='POST', body={
            'agent_token': token_b,
            'action': 'send_message',
            'target_agent_instance_id': sender_a,
            'body': body_b_to_a,
        }, expect_status=202)
        conv_a = send_a.get('conversation_id') or conv_id(sender_a)
        fetched_a = wait_for(lambda: (msgs := fetch_messages(base_a, token_a, conv_a, include_read=True)) and any(m.get('body') == body_b_to_a for m in msgs) and msgs, 'receiver A did not fetch durable body from B')
        exact_a = [m for m in fetched_a if m.get('body') == body_b_to_a]
        require(len(exact_a) == 1, f'B->A durable message body mismatch: {fetched_a}')
        require(exact_a[0].get('target_agent_instance_id') == sender_a, f'B->A sender/target mismatch: {exact_a[0]}')

        print('federation_fresh_home_peer_messages: ok')
    finally:
        stop_daemon(proc_a)
        stop_daemon(proc_b)
        shutil.rmtree(temp_root, ignore_errors=True)


if __name__ == '__main__':
    main()
