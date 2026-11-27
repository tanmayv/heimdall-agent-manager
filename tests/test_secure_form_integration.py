#!/usr/bin/env python3
"""Secure-form browser boundary test with synthetic input and isolated Chromium.

Run with HEIMDALL_TEST_CHROMIUM=/path/to/chromium python3 tests/test_secure_form_integration.py.
Requires Node with built-in WebSocket. No site, live credentials or live profile is used.
"""
import contextlib
from html import escape
import hmac
import http.server
import json
import os
from pathlib import Path
import queue
import secrets
import subprocess
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.parse
import urllib.request


SKILL = (Path(__file__).resolve().parents[1]
         / "src/prompts/skills/credential-and-browser-use/SKILL.md")


@contextlib.contextmanager
def fixture_site(password, outcomes, redirect=None):
    class Site(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def reply(self, code, body=b"", **headers):
            self.send_response(code)
            for key, value in headers.items():
                self.send_header(key.replace("_", "-"), value)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path == "/redirect" and redirect:
                self.reply(302, Location=redirect)
            elif self.path == "/account":
                authenticated = "fixture_session=valid" in self.headers.get("Cookie", "")
                outcomes.put(("account", authenticated))
                self.reply(200 if authenticated else 401)
            elif self.path in ("/login", "/foreign-action"):
                action = redirect if self.path == "/foreign-action" else "/login"
                body = (f'<form id="login" method="post" action="{escape(action)}">'
                        '<input type="password" name="password" required>'
                        '<button type="submit">Sign in</button></form>')
                self.reply(200, body.encode(), Content_Type="text/html")
            else:
                self.reply(404)

        def do_POST(self):
            data = urllib.parse.parse_qs(
                self.rfile.read(int(self.headers["Content-Length"])).decode("ascii"))
            valid = hmac.compare_digest(data.get("password", [""])[0], password)
            # Publish only outcome metadata, never the request body.
            outcomes.put(("submitted", valid))
            if valid:
                self.reply(303, Location="/account", Set_Cookie="fixture_session=valid; HttpOnly")
            else:
                self.reply(401)

    with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Site) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield f"http://127.0.0.1:{server.server_port}"
        finally:
            server.shutdown()
            thread.join()


def eventually(check, child, timeout=10):
    """Wait for Chromium readiness, never repeat an action that supplies input."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline and child.poll() is None:
        try:
            result = check()
            if result:
                return result
        except (FileNotFoundError, urllib.error.URLError, json.JSONDecodeError):
            pass
        threading.Event().wait(0.02)
    raise AssertionError("isolated Chromium did not become ready")


def devtools(endpoint, path, method="GET"):
    request = urllib.request.Request(endpoint + path, method=method)
    with urllib.request.urlopen(request, timeout=2) as response:
        return json.load(response)


class SecureFormBrowserTest(unittest.TestCase):
    def test_skill_script_submits_only_to_verified_origin_and_keeps_profile(self):
        chrome = os.environ["HEIMDALL_TEST_CHROMIUM"]
        password = secrets.token_hex(24)
        payload = json.dumps({"version": 1, "values": {"password": password}}).encode()
        _, body = SKILL.read_text().split("```bash secure-form-fill\n", 1)
        script = body.split("\n```", 1)[0] + "\n"
        trusted, foreign = queue.Queue(), queue.Queue()

        with (tempfile.TemporaryDirectory(prefix="ham-secure-form-") as temporary,
              fixture_site(password, foreign) as other,
              fixture_site(password, trusted, other + "/login") as origin):
            root = Path(temporary).resolve()
            profile = root / "profile"
            env = {
                "PATH": os.environ["PATH"], "HOME": str(root),
                "HEIMDALL_BROWSER_PROFILE_DIR": str(profile),
            }
            (root / "login.sh").write_text(script)
            # Headless is confined to this test, with an isolated profile and listener.
            with (root / "browser.log").open("wb") as browser_log, subprocess.Popen(
                [chrome, "--headless", "--no-sandbox", "--disable-background-networking",
                 "--no-first-run", "--no-default-browser-check", "--disable-component-update",
                 "--enable-automation", "--remote-debugging-address=127.0.0.1",
                 "--remote-debugging-port=0", f"--user-data-dir={profile}", "about:blank"],
                env=env, stdout=browser_log, stderr=browser_log,
            ) as child:
                try:
                    port = eventually(
                        lambda: ((profile / "DevToolsActivePort").read_text().splitlines() or [""])[0],
                        child,
                    )
                    endpoint = f"http://127.0.0.1:{port}"
                    env["HEIMDALL_BROWSER_CDP_PORT"] = port
                    version = eventually(lambda: devtools(endpoint, "/json/version"), child)

                    def new_tab(url):
                        target = devtools(endpoint, "/json/new?" + urllib.parse.quote(url, safe=""),
                                          method="PUT")
                        return target["id"]

                    def wait_for_navigation(target, url):
                        eventually(lambda: any(t["id"] == target and t["url"] == url
                                               for t in devtools(endpoint, "/json/list")), child)

                    def fill(target, expected_code, **overrides):
                        (root / "login-target.json").write_text(
                            json.dumps({"origin": origin, "target_id": target}))
                        run = subprocess.run(
                            ["bash", "login.sh"], cwd=root, env={**env, **overrides},
                            input=payload, capture_output=True, timeout=10, check=False)
                        self.assertFalse(run.stdout or run.stderr, "fill script emitted output")
                        self.assertEqual(run.returncode, expected_code)

                    target = new_tab(origin + "/redirect")
                    wait_for_navigation(target, other + "/login")
                    fill(target, 1)
                    self.assertTrue(foreign.empty(), "redirect destination received a submission")

                    target = new_tab(origin + "/foreign-action")
                    wait_for_navigation(target, origin + "/foreign-action")
                    fill(target, 1)
                    self.assertTrue(foreign.empty(), "cross-origin form action received a submission")

                    target = new_tab(origin + "/login")
                    wait_for_navigation(target, origin + "/login")
                    fill(target, 1, HEIMDALL_BROWSER_PROFILE_DIR=str(root / "wrong-profile"))
                    self.assertTrue(trusted.empty(), "wrong browser profile received a submission")

                    fill(target, 0)
                    self.assertEqual(trusted.get(timeout=5), ("submitted", True))
                    self.assertEqual(trusted.get(timeout=5), ("account", True))
                    new_tab(origin + "/account")
                    self.assertEqual(trusted.get(timeout=5), ("account", True))
                    self.assertTrue(trusted.empty(), "an unsolicited submission occurred")
                    self.assertEqual(devtools(endpoint, "/json/version")["webSocketDebuggerUrl"],
                                     version["webSocketDebuggerUrl"])
                finally:
                    child.terminate()
                    try:
                        child.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        child.kill()
                        child.wait()
            self.assertFalse(password.encode() in (root / "browser.log").read_bytes(),
                             "browser output contained the synthetic value")


if __name__ == "__main__":
    unittest.main()
