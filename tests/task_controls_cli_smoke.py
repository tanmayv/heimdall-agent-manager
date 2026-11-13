"""Exercise the built CLI against an isolated JSONL endpoint; no live Hub mutations."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading

def call(binary, args, response=None):
    with tempfile.TemporaryDirectory(prefix="ctl-controls-") as directory:
        endpoint = str(Path(directory) / "rpc.sock")
        server = socket.socket(socket.AF_UNIX)
        server.bind(endpoint)
        server.listen(1)
        server.settimeout(10)
        received = []
        errors = []
        def serve():
            try:
                with server.accept()[0] as connection:
                    request = connection.makefile("rb").readline()
                    received.append(json.loads(request))
                    reply = response or {"v": 1, "id": "ham-ctl-agent", "ok": True, "data": {}}
                    connection.sendall((json.dumps(reply, separators=(",", ":")) + "\n").encode())
            except Exception as error:
                errors.append(error)
        thread = threading.Thread(target=serve)
        thread.start()
        env = {key: value for key, value in os.environ.items()
               if not key.startswith(("HEIMDALL_", "HAM_"))}
        env.update(HEIMDALL_VAULT_KEYRING="invalid-isolated-test-key",
                   HEIMDALL_AGENT_TOKEN="isolated-test-token",
                   HEIMDALL_BRIDGE_ENDPOINT="unix:" + endpoint)
        result = subprocess.run([binary, *args], env=env, text=True, capture_output=True, timeout=15)
        thread.join(12)
        server.close()
        assert not errors and not thread.is_alive(), errors
        assert len(received) == 1, result.stdout + result.stderr
        return received[0], result

def main():
    binary = sys.argv[1]
    count = 0
    common = ["--reason", "integration check", "--request-id", "request-7", "--expected-generation", "7"]
    for flags in [common, []]:
        request, result = call(binary, ["task", "cancel", "task_test", "--chain", "chain_test", *flags])
        assert result.returncode == 0, result.stdout + result.stderr
        assert request["method"] == "agent.rest.request", request
        params = request["params"]
        assert params["http_method"] == "POST" and params["path"].endswith("/task-chains/chain_test/tasks/task_test/cancel"), params
        body = json.loads(params["body"])
        assert body["reason"] and body["request_id"], body
        assert body.get("expected_generation", 0) == (7 if flags else 0), body
        if flags:
            assert body["request_id"] == "request-7" and body["reason"] == "integration check", body
        count += 1
    generated = set()
    for verb in ["claim", "transfer"]:
        for flags in [common, []]:
            args = ["lease", "task_test"] if verb == "claim" else ["lease", "transfer", "task_test", "--instance", "inst_target"]
            request, result = call(binary, [*args, *flags])
            assert result.returncode == 0, result.stdout + result.stderr
            assert request["method"] == "agent.lease." + verb, request
            params = request["params"]
            assert params["task_id"] == "task_test" and params["reason"] and params["request_id"], request
            assert params.get("expected_generation", 0) == (7 if flags else 0), request
            if verb == "transfer":
                assert params["instance_id"] == "inst_target", request
            if not flags:
                generated.add(params["request_id"])
            count += 1
    assert len(generated) == 2
    env = {key: value for key, value in os.environ.items() if not key.startswith(("HEIMDALL_", "HAM_"))}
    env.update(HEIMDALL_AGENT_TOKEN="isolated-test-token", HEIMDALL_BRIDGE_ENDPOINT="unix:/nonexistent-controls-test.sock")
    removed = [["task", verb, "task_test"] for verb in ["control", "inspect", "reopen", "release-owner", "rereview", "force-complete", "resume"]]
    removed.append(["lease", "recover", "task_test", "--instance", "inst_target"])
    for args in removed:
        result = subprocess.run([binary, *args], env=env, text=True, capture_output=True, timeout=5)
        assert result.returncode != 0, result
        assert "unsupported task command" in result.stdout or "unknown lease command" in result.stdout, result
        count += 1
    request, result = call(binary, ["lease", "task_test"],
        {"v": 1, "id": "ham-ctl-agent", "ok": False, "error": {"code": "conflict", "message": "use explicit transfer"}})
    assert result.returncode != 0 and "use explicit transfer" in result.stdout, result
    print(f"{count + 1} CLI control/claim/refusal checks passed (isolated JSONL endpoint)")

if __name__ == "__main__":
    main()
