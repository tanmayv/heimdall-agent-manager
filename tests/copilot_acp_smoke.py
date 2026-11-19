"""Check pinned native startup with an empty profile; never send a model prompt."""

import argparse
import json
import os
from pathlib import Path
import select
import subprocess
import tempfile
import time


def check(binary, profile):
    env = {key: os.environ[key] for key in
           ("PATH", "HOME", "LANG", "SSL_CERT_FILE", "SSL_CERT_DIR") if key in os.environ}
    env.update(COPILOT_AUTO_UPDATE="false", COPILOT_HOME=str(profile),
               GH_CONFIG_DIR=str(profile / "gh"), XDG_CONFIG_HOME=str(profile / "config"),
               XDG_CACHE_HOME=str(profile / "cache"))
    version = subprocess.run([binary, "--version"], env=env, text=True,
                             capture_output=True, timeout=20, check=True)
    assert version.stdout.splitlines()[0] == "GitHub Copilot CLI 1.0.114."
    child = subprocess.Popen([binary, "--acp", "--stdio"], stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             env=env, cwd=profile, text=True, bufsize=1)

    def rpc(request_id, method, params):
        child.stdin.write(json.dumps(dict(jsonrpc="2.0", id=request_id,
                                         method=method, params=params)) + "\n")
        child.stdin.flush()
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            ready, _, _ = select.select([child.stdout], [], [], max(0, deadline - time.monotonic()))
            if not ready:
                break
            line = child.stdout.readline()
            if not line:
                raise RuntimeError("Copilot exited before RPC reply")
            response = json.loads(line)
            if response.get("id") == request_id:
                return response
        raise TimeoutError(method)

    try:
        initialize = rpc(1, "initialize", dict(protocolVersion=1,
            clientInfo=dict(name="heimdall-c2-smoke", version="1"),
            clientCapabilities=dict(fs=dict(readTextFile=False, writeTextFile=False), terminal=False)))
        assert initialize["result"]["protocolVersion"] == 1
        assert initialize["result"]["agentInfo"]["version"] == "1.0.114"
        session = rpc(2, "session/new", dict(cwd=str(profile), mcpServers=[]))
        assert session.get("error", {}).get("code") == -32000, "Expected auth-required clean profile"
        assert session["error"]["message"] == "Authentication required"
        return dict(version=version.stdout.splitlines()[0], initialize=initialize, clean_session=session)
    finally:
        child.stdin.close()
        try:
            child.wait(timeout=3)
        except subprocess.TimeoutExpired:
            child.terminate()
            try:
                child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=3)
        child.stdout.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="heimdall-copilot-smoke-") as scratch:
        result = check(str(Path(args.binary).resolve(strict=True)), Path(scratch))
    rendered = json.dumps(result, indent=2) + "\n"
    if args.output:
        args.output.write_text(rendered)
    print(rendered, end="")
