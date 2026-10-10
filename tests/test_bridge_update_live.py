#!/usr/bin/env python3
"""Opt-in update smoke against a temporary systemd user service (no Hub needed).
Run: HEIMDALL_LIVE_UPDATE_TEST=1 python3 tests/test_bridge_update_live.py
"""
import json
import os
from pathlib import Path
import socket
import shutil
import subprocess
import tempfile
import time
import unittest
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(os.environ.get('HEIMDALL_LIVE_UPDATE_TEST') == '1', 'requires an actual systemd user session')
class LiveBridgeUpdateTest(unittest.TestCase):
    @unittest.skipUnless(os.environ.get('HEIMDALL_PTY_TEST_BINARY'), 'set HEIMDALL_PTY_TEST_BINARY to a built ham-pty-host')
    def test_service_stop_cleans_real_live_and_stale_hosts_without_touching_other_bridge(self):
        with tempfile.TemporaryDirectory(prefix='heimdall-live-pty-cleanup-') as temporary:
            root = Path(temporary)
            target, other = root/'bridges/brg_target', root/'bridges/brg_other'
            for directory in (target, other):
                (directory/'bin').mkdir(parents=True)
                shutil.copy2(os.environ['HEIMDALL_PTY_TEST_BINARY'], directory/'bin/ham-pty-host')
            processes = []
            name = 'heimdall-pty-cleanup-smoke-'+uuid.uuid4().hex+'.service'
            unit = Path.home()/'.config/systemd/user'/name
            unit.parent.mkdir(parents=True, exist_ok=True)
            unit.write_text('[Service]\nExecStart=/bin/sleep 120\nKillMode=process\nExecStopPost=bash "'+str(ROOT/'scripts/apply-bridge-update.sh')+'" --data-dir "'+str(target)+'" --stop-pty-hosts-only\n')
            try:
                subprocess.run(['systemctl','--user','daemon-reload'], check=True)
                subprocess.run(['systemctl','--user','start',name], check=True)
                for directory, socket_name in ((target,'live.sock'),(target,'stale.sock'),(other,'other.sock')):
                    socket_path = root/socket_name
                    process = subprocess.Popen([str(directory/'bin/ham-pty-host'),'daemon','--socket',str(socket_path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    processes.append(process)
                    for _ in range(50):
                        if socket_path.exists(): break
                        time.sleep(0.02)
                    self.assertTrue(socket_path.exists(), 'PTY host failed to start')
                subprocess.run(['systemctl','--user','stop',name], check=True, timeout=20)
                self.assertIsNotNone(processes[0].poll(), 'live host survived service stop')
                self.assertIsNotNone(processes[1].poll(), 'stale host survived service stop')
                self.assertIsNone(processes[2].poll(), 'another bridge was stopped')
            finally:
                for process in processes:
                    if process.poll() is None: process.kill()
                    process.wait()
                subprocess.run(['systemctl','--user','stop',name], check=False)
                unit.unlink(missing_ok=True)
                subprocess.run(['systemctl','--user','daemon-reload'], check=False)
                subprocess.run(['systemctl','--user','reset-failed',name], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def test_managed_release_update_keeps_launch_arguments_and_cli_shim(self):
        with tempfile.TemporaryDirectory(prefix='heimdall-live-update-') as temporary:
            root = Path(temporary)
            data, stage = root/'data with spaces', root/'stage'
            for path in (data/'bin', stage/'bin'):
                path.mkdir(parents=True)
            with socket.socket() as probe:
                probe.bind(('127.0.0.1', 0))
                port = probe.getsockname()[1]
            source = '''#!/usr/bin/env python3
import http.server, json, sys
assert sys.argv[1:] == ['--port', 'PORT', '--instance', 'isolated-bridge']
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers()
        self.wfile.write(json.dumps({'ok':True,'version':'VERSION'}).encode())
class Server(http.server.HTTPServer): allow_reuse_address=True
Server(('127.0.0.1', PORT), Handler).serve_forever()
'''.replace('PORT', str(port))
            for directory, version in ((data, 'old'), (stage, 'new')):
                bridge = directory/'bin/ham-bridge'
                bridge.write_text(source.replace('VERSION', version)); bridge.chmod(0o755)
                ctl = directory/'bin/ham-ctl'
                ctl.write_text('#!/bin/sh\nprintf "'+version+'\\n"\n'); ctl.chmod(0o755)
            shim = data/'bin/ham-ctl-brg_smoke'
            shim.write_text('#!/bin/sh\nexec "'+str(data/'bin/ham-ctl')+'" "$@"\n'); shim.chmod(0o755)
            name = 'heimdall-update-smoke-'+uuid.uuid4().hex+'.service'
            unit = Path.home()/'.config/systemd/user'/name
            unit.parent.mkdir(parents=True, exist_ok=True)
            unit.write_text('[Service]\nType=simple\nExecStart="'+str(data/'bin/ham-bridge')+'" --port '+str(port)+' --instance isolated-bridge\nRestart=on-failure\nKillMode=process\n')
            url = f'http://127.0.0.1:{port}/api/v1/health'
            try:
                subprocess.run(['systemctl','--user','daemon-reload'], check=True)
                subprocess.run(['systemctl','--user','start',name], check=True)
                for _ in range(50):
                    try:
                        with urllib.request.urlopen(url, timeout=1) as response:
                            self.assertEqual(json.load(response)['version'], 'old')
                        break
                    except OSError: time.sleep(0.1)
                else: self.fail('temporary bridge did not start')
                pid = subprocess.check_output(['systemctl','--user','show',name,'-p','MainPID','--value'], text=True).strip()
                env = os.environ.copy()
                for key in ('SERVICE_NAME','HEIMDALL_BRIDGE_SERVICE_NAME','STOP_HOOK','RESTART_HOOK'):
                    env.pop(key, None)
                result = subprocess.run(['bash',str(ROOT/'scripts/apply-bridge-update.sh'),
                                         '--data-dir',str(data),'--stage-dir',str(stage),
                                         '--bridge-pid',pid,'--health-url',url,'--health-timeout','10'],
                                        env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
                self.assertEqual(result.returncode, 0, result.stdout)
                with urllib.request.urlopen(url, timeout=2) as response:
                    self.assertEqual(json.load(response)['version'], 'new')
                self.assertEqual(subprocess.check_output([str(shim)], text=True).strip(), 'new')
                self.assertEqual(subprocess.check_output(['systemctl','--user','is-active',name], text=True).strip(), 'active')
            finally:
                subprocess.run(['systemctl','--user','stop',name], check=False)
                unit.unlink(missing_ok=True)
                subprocess.run(['systemctl','--user','daemon-reload'], check=False)
                subprocess.run(['systemctl','--user','reset-failed',name], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == '__main__':
    unittest.main()
