#!/usr/bin/env python3
"""Canonical Teams v1 UI-driven E2E runner for Task 18.

The runner is intentionally stdlib-only. User-visible actions are executed through
Electron's debug UI HTTP endpoints (`/click`, `/type`, `/select`, `/state`, etc.).
CLI/HTTP calls are limited to isolated setup/teardown, passive assertions,
preflight checks, and transcript collection.

Real pi/Codex scenarios are never faked: canonical execution fails preflight
if the local machine cannot launch pi with the Codex model mapping from
`config-test.toml`.
Use `--preflight --allow-external-blockers` when developing the harness on a
machine without those external credentials.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import shutil
import signal
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

ROOT = Path(__file__).resolve().parents[2]
CONFIG_TEST = ROOT / "config-test.toml"
TRANSCRIPT_ROOT = ROOT / "tests" / "e2e" / "transcripts"
DEFAULT_PORT = 49422
USER_ID = "operator@local"
CLIENT_ID = "task18-canonical-ui"


@dataclass
class Step:
    name: str
    ok: bool
    detail: dict[str, Any] = field(default_factory=dict)
    ts_unix_ms: int = field(default_factory=lambda: int(time.time() * 1000))


@dataclass
class ScenarioResult:
    scenario_id: str
    title: str
    ok: bool
    status: str
    steps: list[Step] = field(default_factory=list)
    blockers: list[str] = field(default_factory=list)
    artifacts: dict[str, str] = field(default_factory=dict)


@dataclass
class Scenario:
    scenario_id: str
    title: str
    run: Callable[["Harness", "Scenario"], ScenarioResult]
    requires_ui: bool = True
    requires_real_codex: bool = False
    task18_requirement: str = ""


class HarnessError(RuntimeError):
    pass


class Harness:
    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.daemon_port = args.daemon_port
        self.daemon_url = f"http://127.0.0.1:{self.daemon_port}"
        self.run_id = time.strftime("%Y%m%d-%H%M%S")
        self.out_dir = Path(args.artifacts_dir or TRANSCRIPT_ROOT / self.run_id)
        self.out_dir.mkdir(parents=True, exist_ok=True)
        self.temp_dir = Path(tempfile.mkdtemp(prefix="heimdall-task18-e2e-"))
        self.data_dir = self.temp_dir / "data"
        self.config_path = self.temp_dir / "config.toml"
        self.daemon_log = self.out_dir / "daemon.log"
        self.ui_log = self.out_dir / "electron.log"
        self.credentials_source = runner_credentials_source(args)
        self.credentials_path = self.out_dir / "isolated" / "wrapper-credentials.json"
        self.daemon_proc: subprocess.Popen[str] | None = None
        self.ui_proc: subprocess.Popen[str] | None = None
        self.debug_port: int | None = None
        self.client_token = ""
        self.agent_token = ""
        self.ham_daemon = ""
        self.ham_wrapper = ""
        self.ham_ctl = ""
        self.precreated: dict[str, Any] = {}
        self.wrapper_procs: list[subprocess.Popen[str]] = []

    def close(self) -> None:
        for proc in self.wrapper_procs:
            try:
                proc.terminate()
                proc.wait(timeout=8)
            except Exception:
                try:
                    proc.kill()
                except Exception:
                    pass
        for proc in (self.ui_proc, self.daemon_proc):
            if not proc:
                continue
            try:
                proc.terminate()
                proc.wait(timeout=8)
            except Exception:
                try:
                    proc.kill()
                except Exception:
                    pass
        if not self.args.keep_temp:
            shutil.rmtree(self.temp_dir, ignore_errors=True)

    def record_json(self, name: str, payload: Any) -> str:
        path = self.out_dir / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        return str(path)

    def run_cmd(self, cmd: list[str], *, timeout: int = 120, cwd: Path = ROOT) -> subprocess.CompletedProcess[str]:
        return subprocess.run(cmd, cwd=str(cwd), text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)

    def nix_out(self, attr: str) -> str:
        res = self.run_cmd(["nix", "build", "--no-link", "--print-out-paths", f".#${attr}".replace("#$", "#")], timeout=240)
        if res.returncode != 0:
            raise HarnessError(f"nix build .#{attr} failed:\n{res.stdout}")
        return res.stdout.strip().splitlines()[-1]

    def prepare_binaries(self) -> None:
        self.ham_daemon = str(Path(self.nix_out("ham-daemon")) / "bin" / "ham-daemon")
        self.ham_wrapper = str(Path(self.nix_out("ham-wrapper")) / "bin" / "ham-wrapper")
        self.ham_ctl = str(Path(self.nix_out("ham-ctl")) / "bin" / "ham-ctl")

    def prepare_isolated_credentials(self) -> None:
        self.credentials_path.parent.mkdir(parents=True, exist_ok=True)
        if self.credentials_source:
            shutil.copyfile(self.credentials_source, self.credentials_path)
        elif not self.credentials_path.exists():
            self.credentials_path.write_text("{}\n", encoding="utf-8")


    def requires_real_codex(self) -> bool:
        selected = set(self.args.scenario or [s.scenario_id for s in SCENARIOS])
        return "all" in selected or "coding-two-teams-real-pi" in selected

    def write_isolated_config(self) -> None:
        self.prepare_isolated_credentials()
        text = CONFIG_TEST.read_text(encoding="utf-8")
        text = replace_toml_value(text, "port", str(self.daemon_port), section="daemon")
        text = replace_toml_value(text, "data_dir", quote(str(self.data_dir)), section="daemon")
        text = replace_toml_value(text, "wrapper_bin", quote(self.ham_wrapper), section="daemon")
        text = replace_toml_value(text, "daemon_url", quote(self.daemon_url), section="ctl")
        text = replace_toml_value(text, "daemon_url", quote(self.daemon_url), section="wrapper")
        text = replace_toml_value(text, "credentials_path", quote(str(self.credentials_path)), section="wrapper")
        text = replace_toml_value(text, "agent_run_dir", quote(str(self.temp_dir / "agent-runs")), section="wrapper")
        text = replace_toml_value(text, "ham_ctl_bin", quote(self.ham_ctl), section="wrapper")
        text = replace_toml_value(text, "tmux_session", quote(f"task18-e2e-{self.run_id}"), section="wrapper")
        text = replace_toml_value(text, "starter_prompt", quote(f"First, run: {self.ham_ctl} --config {self.config_path} --daemon-url {self.daemon_url} --token {{token}} start-success. For every later ham-ctl command in this isolated E2E, include both --config {self.config_path} and --daemon-url {self.daemon_url}. Then read AGENTS.md for context and claim assigned work if present."), section="wrapper.agent-cmd.pi")
        # Speed up nudge/idle scenarios in the isolated daemon only.
        text = replace_toml_value(text, "nudge_cooldown_seconds", "15", section="daemon")
        text = replace_toml_value(text, "nudge_interval_seconds", "15", section="daemon")
        text = replace_toml_value(text, "nudge_ready_after_seconds", "15", section="daemon")
        text = replace_toml_value(text, "nudge_review_after_seconds", "15", section="daemon")
        text = replace_toml_value(text, "nudge_restart_grace_seconds", "15", section="daemon")
        idle_seconds = "1200" if self.requires_real_codex() else "2"
        text = replace_toml_value(text, "team_idle_shutdown_seconds", idle_seconds, section="daemon", append=True)
        self.config_path.write_text(text, encoding="utf-8")

    def start_daemon(self) -> None:
        if port_open(self.daemon_port):
            raise HarnessError(f"port {self.daemon_port} is already in use; refusing to touch a live daemon")
        log = self.daemon_log.open("w", encoding="utf-8")
        self.daemon_proc = subprocess.Popen([self.ham_daemon, "--config", str(self.config_path)], cwd=str(ROOT), text=True, stdout=log, stderr=subprocess.STDOUT)
        wait_http(f"{self.daemon_url}/health", timeout=20)

    def register_client_and_seed_agent(self) -> None:
        client = self.http_post("/user-client/register", {"user_id": USER_ID, "client_instance_id": CLIENT_ID})
        self.client_token = client.get("client_token", "")
        if not self.client_token:
            raise HarnessError(f"missing client token: {client}")
        # Do NOT /register any agent for setup. Two reasons learned via interactive debugging:
        #  1. /register marks the identity connected=true in the registry; if that identity is the
        #     coordinator, the autoscaler thinks it is already live and never warm-starts it.
        #  2. The setup helper endpoints (/projects/create, /tasks/create, /memory/*, and
        #     `ham-ctl task-chains show`) authenticate via auth_db_get_identity, which accepts the
        #     user *client_token* just fine. So no agent token is needed at all.
        # Use the client_token as the setup auth token; create the coordinator as an OFFLINE record.
        self.agent_token = self.client_token

    def seed_offline_coordinator(self, agent_instance_id: str = "pi@task18-e2e", project_id: str = "default") -> None:
        # Offline coordinator record (connection_state=offline; eligible in UI coordinator pool).
        # Created AFTER the project exists so association is valid. Must NOT be /register'd, or the
        # autoscaler will treat it as already-connected and never warm-start it.
        created = self.http_post("/agents/create", {
            "agent_instance_id": agent_instance_id,
            "display_name": "Task18 Coordinator",
            "template_id": "lead",
            "provider_profile": "pi",
            "project_id": project_id,
            "model_tier": "cheap",
        })
        if not created.get("ok"):
            raise HarnessError(f"failed to create offline coordinator record: {created}")

    def http_post(self, path: str, payload: dict[str, Any]) -> Any:
        req = urllib.request.Request(self.daemon_url + path, data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"}, method="POST")
        with urllib.request.urlopen(req, timeout=20) as res:
            return json.loads(res.read().decode() or "{}")

    def http_get(self, path: str) -> Any:
        with urllib.request.urlopen(self.daemon_url + path, timeout=20) as res:
            return json.loads(res.read().decode() or "{}")

    def create_project_setup(self, name: str, vcs_kind: str = "none", repo: str = "", project_id: str = "") -> str:
        anchors = [{"type": "vcs_kind", "value": vcs_kind, "note": "task18 isolated e2e"}]
        if repo:
            anchors.append({"type": "git_repo", "value": repo, "note": "task18 isolated e2e"})
            anchors.append({"type": "worktree_root", "value": str(self.temp_dir / "worktrees"), "note": "task18 isolated e2e"})
            anchors.append({"type": "base_ref", "value": "main", "note": "task18 isolated e2e"})
        body = {"agent_token": self.agent_token, "name": name, "description": "Task 18 isolated UI E2E project", "anchors": anchors}
        if project_id:
            body["project_id"] = project_id
        res = self.http_post("/projects/create", body)
        return res.get("project_id", project_id or "")

    def capture_real_pi_pane(self, name: str = "real-pi-pane.txt", agent_instance_id: str = "pi@task18-e2e") -> str:
        path = self.out_dir / name
        session = f"task18-e2e-{self.run_id}"
        cmd = ["tmux", "capture-pane", "-t", f"{session}:agent-{agent_instance_id}", "-p", "-S", "-4000"]
        res = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        path.write_text(res.stdout, encoding="utf-8", errors="ignore")
        return str(path)

    def ham_ctl_chain_coordinator(self, chain_id: str) -> str:
        """Resolve the chain's coordinator_agent_instance_id via ham-ctl (independent of UI)."""
        if not chain_id or not self.ham_ctl:
            return ""
        cmd = [self.ham_ctl, "--config", str(self.config_path), "--daemon-url", self.daemon_url,
               "task-chains", "show", "--token", self.agent_token, "--chain-id", chain_id]
        res = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        coordinator = ""
        for line in (res.stdout or "").splitlines():
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                data = json.loads(line)
            except Exception:
                continue
            chain = data.get("chain") or data
            cid = chain.get("coordinator_agent_instance_id", "")
            if cid:
                coordinator = cid
        return coordinator

    def ham_ctl_chain_status(self, chain_id: str) -> tuple[str, str]:
        """Read chain status via ham-ctl against the isolated daemon (independent of the UI)."""
        if not chain_id or not self.ham_ctl:
            return "", ""
        cmd = [self.ham_ctl, "--config", str(self.config_path), "--daemon-url", self.daemon_url,
               "task-chains", "show", "--token", self.agent_token, "--chain-id", chain_id]
        res = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        out = res.stdout or ""
        status = ""
        for line in out.splitlines():
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                data = json.loads(line)
            except Exception:
                continue
            chain = data.get("chain") or data
            status = chain.get("status", "") or status
            if data.get("chain_id") == chain_id or chain.get("chain_id") == chain_id:
                status = chain.get("status", status)
        return status, out[-1200:]

    def tmux_window_names(self) -> list[str]:
        session = f"task18-e2e-{self.run_id}"
        res = subprocess.run(["tmux", "list-windows", "-t", session, "-F", "#{window_name}"], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if res.returncode != 0:
            return []
        return [line.strip() for line in (res.stdout or "").splitlines() if line.strip()]

    def tmux_pane_exists(self, agent_instance_id: str) -> bool:
        window = f"agent-{agent_instance_id}"
        return window in self.tmux_window_names()

    def tmux_kill_windows_with_prefix(self, prefix: str) -> list[str]:
        session = f"task18-e2e-{self.run_id}"
        killed: list[str] = []
        for name in self.tmux_window_names():
            if name.startswith(prefix):
                subprocess.run(["tmux", "kill-window", "-t", f"{session}:{name}"], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                killed.append(name)
        return killed

    def coordinator_liveness(self, agent_instance_id: str) -> dict[str, Any]:
        """Assess whether the product has warm-started the coordinator agent.

        Uses passive daemon /agents state plus an isolated tmux-pane existence check.
        No prelaunch and no UI action is performed here; this only observes.
        """
        agents = self.http_get("/agents").get("agents", [])
        rec = next((a for a in agents if a.get("agent_instance_id") == agent_instance_id), {})
        connected = bool(rec.get("connected"))
        conn_state = rec.get("connection_state", "")
        startup_status = rec.get("startup_status", "")
        pane = self.tmux_pane_exists(agent_instance_id)
        live = bool(pane and (connected or conn_state in {"connected", "registered"} or startup_status in {"starting", "ready"}))
        return {
            "agent_instance_id": agent_instance_id,
            "live": live,
            "tmux_pane_present": pane,
            "connected": connected,
            "connection_state": conn_state,
            "startup_status": startup_status,
        }

    def start_real_pi_wrapper(self) -> str:
        # The generated config may still contain deprecated wrapper.project = "default".
        # Keep the isolated wrapper happy by ensuring that project exists in the isolated DB.
        try:
            self.create_project_setup("Default project", "none", project_id="default")
        except Exception:
            pass
        log_path = self.out_dir / "real-pi-wrapper.log"
        log = log_path.open("w", encoding="utf-8")
        proc = subprocess.Popen([self.ham_wrapper, "--config", str(self.config_path), "--agent", "pi", "pi@task18-e2e"], cwd=str(ROOT), text=True, stdout=log, stderr=subprocess.STDOUT)
        self.wrapper_procs.append(proc)
        deadline = time.time() + 180
        last = ""
        while time.time() < deadline:
            if log_path.exists():
                last = log_path.read_text(encoding="utf-8", errors="ignore")
                if "ws connected" in last and ("startup_status\":\"ready\"" in last or "Startup detection disabled; assuming ready" in last):
                    return str(log_path)
                if "wrapper startup aborted" in last or proc.poll() is not None:
                    raise HarnessError(f"real pi wrapper exited before ready; see {log_path}: {last[-1200:]}")
            time.sleep(0.5)
        raise HarnessError(f"timed out waiting for real pi wrapper readiness; see {log_path}: {last[-1200:]}")

    def build_ui(self) -> None:
        res = self.run_cmd(["npm", "run", "build"], timeout=240)
        if res.returncode != 0:
            raise HarnessError(f"npm run build failed:\n{res.stdout}")

    def start_ui(self) -> None:
        if sys.platform.startswith("linux") and not os.environ.get("DISPLAY") and not os.environ.get("WAYLAND_DISPLAY"):
            raise HarnessError("no DISPLAY/WAYLAND_DISPLAY; Electron UI automation unavailable")
        electron = ROOT / "node_modules" / ".bin" / ("electron.cmd" if os.name == "nt" else "electron")
        if not electron.exists():
            raise HarnessError("Electron binary missing; run npm ci first")
        env = os.environ.copy()
        env["HEIMDALL_DAEMON_URL"] = self.daemon_url
        env["HEIMDALL_UI_DEBUG"] = "1"
        env["ELECTRON_DISABLE_SECURITY_WARNINGS"] = "1"
        log = self.ui_log.open("w", encoding="utf-8")
        self.ui_proc = subprocess.Popen([str(electron), "."], cwd=str(ROOT), env=env, text=True, stdout=log, stderr=subprocess.STDOUT)
        deadline = time.time() + 30
        while time.time() < deadline:
            text = self.ui_log.read_text(encoding="utf-8", errors="ignore") if self.ui_log.exists() else ""
            marker = "debug_server_port="
            if marker in text:
                tail = text.split(marker, 1)[1].splitlines()[0].strip()
                self.debug_port = int(tail)
                wait_http(f"http://127.0.0.1:{self.debug_port}/info", timeout=10)
                return
            if self.ui_proc.poll() is not None:
                raise HarnessError(f"Electron exited early; see {self.ui_log}")
            time.sleep(0.25)
        raise HarnessError(f"timed out waiting for Electron debug server; see {self.ui_log}")

    def ui(self, method: str, path: str, payload: dict[str, Any] | None = None) -> Any:
        if not self.debug_port:
            raise HarnessError("UI debug server is not running")
        url = f"http://127.0.0.1:{self.debug_port}{path}"
        data = None if payload is None else json.dumps(payload).encode()
        req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"}, method=method)
        with urllib.request.urlopen(req, timeout=20) as res:
            body = res.read().decode()
            return json.loads(body or "{}")

    def ui_wait_for_debug_id(self, debug_id: str, timeout: int = 15) -> dict[str, Any]:
        deadline = time.time() + timeout
        while time.time() < deadline:
            elems = self.ui("GET", "/elements")
            for elem in elems:
                if elem.get("debugId") == debug_id and elem.get("visible"):
                    return elem
            time.sleep(0.25)
        raise HarnessError(f"UI element {debug_id!r} did not become visible")

    def screenshot(self, name: str) -> str:
        data = self.ui("GET", "/screenshot")
        path = self.out_dir / name
        if data.get("ok") and data.get("dataUrl", "").startswith("data:image/png;base64,"):
            path.write_bytes(base64.b64decode(data["dataUrl"].split(",", 1)[1]))
        return str(path)


def replace_toml_value(text: str, key: str, value: str, *, section: str, append: bool = False) -> str:
    lines = text.splitlines()
    in_section = False
    section_header = f"[{section}]"
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            if in_section and append:
                lines.insert(i, f"{key} = {value}")
                return "\n".join(lines) + "\n"
            in_section = stripped == section_header
            continue
        if in_section and (stripped.startswith(f"{key} ") or stripped.startswith(f"{key}=")):
            lines[i] = f"{key} = {value}"
            return "\n".join(lines) + "\n"
    if append:
        lines.append(section_header)
        lines.append(f"{key} = {value}")
        return "\n".join(lines) + "\n"
    raise HarnessError(f"missing [{section}] {key} in config-test.toml")


def quote(value: str) -> str:
    return json.dumps(value)


def port_open(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.settimeout(0.2)
        return s.connect_ex(("127.0.0.1", port)) == 0


def wait_http(url: str, timeout: int) -> None:
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=2) as res:
                if res.status < 500:
                    return
        except Exception as exc:
            last = exc
            time.sleep(0.25)
    raise HarnessError(f"timed out waiting for {url}: {last}")


def wait_port_closed(port: int, timeout: int = 10) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if not port_open(port):
            return
        time.sleep(0.25)
    raise HarnessError(f"port {port} did not close after stopping isolated daemon")


def runner_credentials_source(args: argparse.Namespace) -> Path | None:
    raw = args.wrapper_credentials_path or os.environ.get("HEIMDALL_E2E_WRAPPER_CREDENTIALS", "")
    if not raw:
        return None
    return Path(os.path.expanduser(raw)).resolve()


def planned_credentials_path(args: argparse.Namespace) -> Path:
    if args.artifacts_dir:
        return Path(args.artifacts_dir).resolve() / "isolated" / "wrapper-credentials.json"
    return TRANSCRIPT_ROOT / "<timestamp>" / "isolated" / "wrapper-credentials.json"


def preflight(args: argparse.Namespace) -> tuple[list[str], dict[str, Any]]:
    blockers: list[str] = []
    requested = set(args.scenario or ["all"])
    needs_all = "all" in requested
    needs_real_codex = needs_all or "coding-two-teams-real-pi" in requested
    non_ui = {"legacy-migration-copy", "coordinator-contact-invariants"}
    needs_ui = needs_all or any(s not in non_ui for s in requested)
    credentials_source = runner_credentials_source(args)
    details: dict[str, Any] = {"root": str(ROOT), "config_test": str(CONFIG_TEST), "required_port": args.daemon_port, "requested_scenarios": sorted(requested), "needs_real_codex": needs_real_codex, "needs_ui": needs_ui, "credentials_source": str(credentials_source) if credentials_source else "generated-isolated-empty", "credentials_path": str(planned_credentials_path(args)), "uses_global_wrapper_credentials": False}
    if not CONFIG_TEST.exists():
        blockers.append("config-test.toml missing")
    text = CONFIG_TEST.read_text(encoding="utf-8") if CONFIG_TEST.exists() else ""
    if needs_real_codex:
        for model in ["openai-codex/gpt-5.3-codex-spark", "openai-codex/gpt-5.4", "openai-codex/gpt-5.5"]:
            if model not in text:
                blockers.append(f"Codex model mapping missing from config-test.toml: {model}")
        details["pi_on_path"] = shutil.which("pi") or ""
        if not details["pi_on_path"]:
            blockers.append("pi executable not found on PATH; real pi/Codex scenario cannot run")
        if credentials_source and not credentials_source.exists():
            blockers.append(f"explicit wrapper credentials path does not exist: {credentials_source}")
        details["credentials_source_exists"] = bool(credentials_source and credentials_source.exists())
    if port_open(args.daemon_port):
        blockers.append(f"required isolated port {args.daemon_port} is already in use")
    if needs_ui:
        if sys.platform.startswith("linux") and not os.environ.get("DISPLAY") and not os.environ.get("WAYLAND_DISPLAY"):
            blockers.append("DISPLAY/WAYLAND_DISPLAY not set; Electron UI automation cannot run")
        details["node_modules_electron"] = str(ROOT / "node_modules" / ".bin" / "electron")
        if not (ROOT / "node_modules" / ".bin" / ("electron.cmd" if os.name == "nt" else "electron")).exists():
            blockers.append("node_modules Electron binary missing; run npm ci")
    return blockers, details


def step(steps: list[Step], name: str, fn: Callable[[], Any]) -> Any:
    try:
        value = fn()
        steps.append(Step(name=name, ok=True, detail={"result": value}))
        return value
    except Exception as exc:
        steps.append(Step(name=name, ok=False, detail={"error": str(exc)}))
        raise


def ui_create_chain(h: Harness, steps: list[Step], *, title: str, goal: str, kind: str, wants_vcs: bool, project_id: str = "") -> dict[str, Any]:
    step(steps, "wait for Home new-chain button", lambda: h.ui_wait_for_debug_id("home-new-chain-btn"))
    step(steps, f"open new-chain modal for {title}", lambda: h.ui("POST", "/click", {"query": '[data-debug-id="home-new-chain-btn"]'}))
    if project_id:
        def wait_project_option() -> dict[str, Any]:
            deadline = time.time() + 15
            query = f'[data-debug-id="new-chain-project-select"] option[value="{project_id}"]'
            while time.time() < deadline:
                found = h.ui("POST", "/query-selector", {"query": query})
                if found:
                    return {"query": query, "found": found}
                time.sleep(0.25)
            raise HarnessError(f"project option did not appear in NewChainModal: {project_id}")
        step(steps, f"wait for project option {project_id}", wait_project_option)
        selected_project = step(steps, f"select project {project_id}", lambda: h.ui("POST", "/select", {"query": '[data-debug-id="new-chain-project-select"]', "value": project_id}))
        if selected_project.get("value") != project_id:
            raise HarnessError(f"project selection did not stick: wanted {project_id}, got {selected_project.get('value')}")
    step(steps, f"enter title for {title}", lambda: h.ui("POST", "/type", {"query": '[data-debug-id="new-chain-title-input"]', "text": title}))
    step(steps, f"enter goal for {title}", lambda: h.ui("POST", "/type", {"query": '[data-debug-id="new-chain-goal-textarea"]', "text": goal}))
    step(steps, f"select {kind} kind", lambda: h.ui("POST", "/select", {"query": '[data-debug-id="new-chain-kind-select"]', "value": kind}))
    if not wants_vcs:
        step(steps, "turn VCS off via UI", lambda: h.ui("POST", "/select", {"query": '[data-debug-id="new-chain-vcs-checkbox"]'}))
    step(steps, f"submit chain {title} via UI", lambda: h.ui("POST", "/click", {"query": '[data-debug-id="new-chain-submit-btn"]'}))
    time.sleep(1.0)
    state = step(steps, f"read Redux after creating {title}", lambda: h.ui("GET", "/state"))
    chains_by_id = (((state or {}).get("tasks") or {}).get("chainsById") or {})
    chains = list(chains_by_id.values())
    match = next((c for c in chains if title in (c.get("title") or "")), None)
    if not match:
        raise HarnessError(f"created chain {title!r} was not visible in Redux task chains")
    return match


def scenario_ui_no_vcs_user_proxy(h: Harness, sc: Scenario) -> ScenarioResult:
    steps: list[Step] = []
    artifacts: dict[str, str] = {}
    try:
        project_id = step(steps, "setup project through isolated HTTP helper", lambda: h.create_project_setup("Task18 no-vcs project", "none"))
        chain = ui_create_chain(h, steps, title="Task18 UI no-vcs smart approval", goal="Create a no-VCS solo chain and approve the user_proxy review from Needs attention with a smart reply.", kind="solo", wants_vcs=False, project_id=project_id)
        chain_id = chain.get("chainId")
        if not chain_id:
            raise HarnessError("created no-vcs chain has no chainId")
        task = step(steps, "setup user_proxy review_ready task through isolated helper", lambda: h.http_post("/tasks/create", {"agent_token": h.agent_token, "chain_id": chain_id, "title": "Task18 user_proxy smart approval", "assignee_agent_instance_id": chain.get("coordinatorAgentInstanceId"), "status": "review_ready"}))
        task_id = task.get("task_id")
        if not task_id:
            raise HarnessError(f"task create failed: {task}")
        step(steps, "add user_proxy required reviewer", lambda: h.http_post("/tasks/participant", {"agent_token": h.agent_token, "task_id": task_id, "chain_id": chain_id, "agent_instance_id": "user_proxy", "role": "lgtm_required"}))
        step(steps, "open Attention surface via UI", lambda: h.ui("POST", "/click", {"query": '[data-debug-id="nav-attention-btn"]'}))
        time.sleep(1.0)
        elems = step(steps, "collect Needs attention elements before approval", lambda: h.ui("GET", "/elements"))
        state = step(steps, "passively read Redux state before approval", lambda: h.ui("GET", "/state"))
        artifacts["before_approval_state"] = h.record_json(f"{sc.scenario_id}/before-approval-state.json", state)
        artifacts["elements"] = h.record_json(f"{sc.scenario_id}/elements.json", elems)
        artifacts["screenshot"] = h.screenshot(f"{sc.scenario_id}/attention-before-approval.png")
        approve_id = f"attention-approval-{task_id}-approve-btn"
        approve_present = any(e.get("debugId") == approve_id for e in elems)
        step(steps, "assert smart approval button is visible", lambda: {"expected_debug_id": approve_id, "present": approve_present})
        if not approve_present:
            raise HarnessError(f"user_proxy smart approval button missing: {approve_id}")
        step(steps, "approve user_proxy item through UI", lambda: h.ui("POST", "/click", {"query": f'[data-debug-id="{approve_id}"]'}))
        def wait_approved() -> dict[str, Any]:
            deadline = time.time() + 10
            last_task: dict[str, Any] = {}
            while time.time() < deadline:
                current = h.ui("GET", "/state")
                last_task = (((current or {}).get("tasks") or {}).get("tasksById") or {}).get(task_id, {})
                if last_task.get("status") in {"approved", "completed", "done"}:
                    return current
                time.sleep(0.25)
            raise HarnessError(f"user_proxy approval did not update UI task status, got {last_task.get('status')!r}")
        after = step(steps, "wait for approved UI state after smart approval", wait_approved)
        artifacts["after_approval_state"] = h.record_json(f"{sc.scenario_id}/after-approval-state.json", after)
        return ScenarioResult(sc.scenario_id, sc.title, True, "passed", steps, artifacts=artifacts)
    except Exception as exc:
        return ScenarioResult(sc.scenario_id, sc.title, False, "failed", steps, blockers=[str(exc)], artifacts=artifacts)


def scenario_redux_freshness(h: Harness, sc: Scenario) -> ScenarioResult:
    steps: list[Step] = []
    artifacts: dict[str, str] = {}
    try:
        elems = step(steps, "collect Home elements without manual refresh", lambda: h.ui("GET", "/elements"))
        hidden = {"home-http-load-evidence", "home-periodic-evidence", "home-ws-evidence", "home-local-action-evidence"}
        present = {e.get("debugId") for e in elems}
        visible_debug = sorted(hidden & present)
        if visible_debug:
            raise HarnessError(f"operator-facing freshness diagnostics should be hidden: {visible_debug}")
        visible_text = "\n".join(str(e.get("text") or "") for e in elems)
        forbidden_text = ["HTTP load:", "Periodic revalidation:", "Last WS refetch:", "Local action:"]
        leaked = [text for text in forbidden_text if text in visible_text]
        if leaked:
            raise HarnessError(f"operator-facing freshness diagnostic text leaked: {leaked}")
        def wait_freshness() -> dict[str, Any]:
            deadline = time.time() + 30
            last: dict[str, Any] = {}
            while time.time() < deadline:
                current = h.ui("GET", "/state")
                home = (current or {}).get("home") or {}
                last = {
                    "state": current,
                    "freshness": {
                        "http_load": bool(home.get("lastHttpLoadUnixMs")),
                        "periodic_configured": True,
                        "ws_or_local_update": bool(home.get("lastWsRefreshReason") and home.get("lastWsRefreshReason") != "none yet") or bool(home.get("lastLocalAction") and home.get("lastLocalAction") != "none yet"),
                    },
                }
                if last["freshness"]["http_load"] and last["freshness"]["ws_or_local_update"]:
                    return last
                time.sleep(0.25)
            raise HarnessError(f"Redux freshness evidence incomplete without manual refresh: {last.get('freshness')}")
        waited = step(steps, "wait for no-refresh Redux freshness evidence", wait_freshness)
        state = waited["state"]
        freshness = waited["freshness"]
        artifacts["redux_state"] = h.record_json(f"{sc.scenario_id}/redux-state.json", state)
        artifacts["elements"] = h.record_json(f"{sc.scenario_id}/elements.json", elems)
        artifacts["screenshot"] = h.screenshot(f"{sc.scenario_id}/freshness.png")
        step(steps, "assert no-refresh Redux evidence is populated", lambda: freshness)
        return ScenarioResult(sc.scenario_id, sc.title, True, "passed", steps, artifacts=artifacts)
    except Exception as exc:
        return ScenarioResult(sc.scenario_id, sc.title, False, "failed", steps, blockers=[str(exc)], artifacts=artifacts)


def make_git_repo(root: Path) -> str:
    repo = root / "repo"
    repo.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "init", "-b", "main"], cwd=repo, check=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    (repo / "README.md").write_text("# Task 18 E2E repo\n", encoding="utf-8")
    subprocess.run(["git", "add", "README.md"], cwd=repo, check=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    subprocess.run(["git", "-c", "user.name=Task18", "-c", "user.email=task18@example.invalid", "commit", "-m", "initial"], cwd=repo, check=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return str(repo)


def scenario_coding_two_teams_real_pi(h: Harness, sc: Scenario) -> ScenarioResult:
    steps: list[Step] = []
    artifacts: dict[str, str] = {}
    try:
        precreated = h.precreated.get(sc.scenario_id, {})
        repo = step(steps, "use isolated git repo", lambda: precreated.get("repo") or make_git_repo(h.temp_dir / "coding-two-teams"))
        project_id = step(steps, "use git-backed project prepared before UI load", lambda: precreated.get("project_id") or h.create_project_setup("Task18 real pi coding project", "git", repo))
        # Do NOT prelaunch the coordinator. Product lifecycle must boot the chain coordinator
        # (pi@task18-e2e) via UI chain activation / focus / coordinator message. This validates
        # the coordinator warm-start path rather than a tester workaround.
        first = ui_create_chain(h, steps, title="Task18 real pi coding flow", goal="Use real pi/Codex agents to make a tiny README change and complete review/merge flow.", kind="coding", wants_vcs=True, project_id=project_id)
        first_chain_id = first.get("chainId")
        # Assert the chain is ACTIVATED (planning -> in_progress) after UI actions, cross-checked
        # via both the UI Redux state and ham-ctl (independent daemon-side source of truth).
        def wait_chain_activated() -> dict[str, Any]:
            deadline = time.time() + 60
            last: dict[str, Any] = {}
            active = {"in_progress", "reviewing", "completed"}
            while time.time() < deadline:
                ui_state = h.ui("GET", "/state")
                ui_chain = (((ui_state or {}).get("tasks") or {}).get("chainsById") or {}).get(first_chain_id, {})
                ui_status = ui_chain.get("status")
                ctl_status, ctl_raw = h.ham_ctl_chain_status(first_chain_id)
                last = {"ui_status": ui_status, "ham_ctl_status": ctl_status, "ham_ctl_source": ctl_raw}
                if ui_status in active and ctl_status in active:
                    return last
                time.sleep(2)
            raise HarnessError(f"chain was not activated after UI actions (ui vs ham-ctl): {last}")
        activation_evidence = step(steps, "assert chain activated after UI actions (UI Redux + ham-ctl)", wait_chain_activated)
        artifacts["chain_activation"] = h.record_json(f"{sc.scenario_id}/chain-activation.json", activation_evidence)
        # Resolve the ACTUAL coordinator identity from the chain (do not hardcode). This must be
        # the single coordinator identity used by chain-level coordinator, scaffold assignment,
        # UI chat/focus/boot target, and nudges.
        coordinator_id = step(steps, "resolve chain coordinator identity via ham-ctl", lambda: h.ham_ctl_chain_coordinator(first_chain_id))
        if not coordinator_id:
            raise HarnessError("could not resolve chain coordinator_agent_instance_id from ham-ctl")
        # Product-lifecycle assertion: chain activation must warm-start the coordinator agent
        # WITHOUT any tester prelaunch and BEFORE any coordinator chat message is sent.
        def wait_coordinator_booted_on_activation() -> dict[str, Any]:
            deadline = time.time() + 180
            last_boot: dict[str, Any] = {}
            while time.time() < deadline:
                boot = h.coordinator_liveness(coordinator_id)
                last_boot = boot
                if boot.get("live"):
                    return boot
                time.sleep(2)
            raise HarnessError(f"coordinator was not booted by product on chain activation (no prelaunch): {last_boot}")
        boot_evidence = step(steps, "assert product boots coordinator on chain activation (no prelaunch)", wait_coordinator_booted_on_activation)
        artifacts["coordinator_boot_on_activation"] = h.record_json(f"{sc.scenario_id}/coordinator-boot-on-activation.json", boot_evidence)
        def open_chain_until_composer() -> dict[str, Any]:
            # The chain-view render can lag behind the click (focus + workspace fetches). Retry using
            # the Home row when visible, and fall back to the persistent sidebar chain selector. The
            # click result is checked so a selector/harness miss cannot masquerade as product failure.
            deadline = time.time() + 90
            attempts = 0
            last: dict[str, Any] = {}
            home_selector = f'[data-debug-id="home-chain-open-btn-{first_chain_id}"]'
            sidebar_selector = f'[data-debug-id="sidebar-chain-{first_chain_id}"]'
            while time.time() < deadline:
                attempts += 1
                elems_before = h.ui("GET", "/elements") or []
                visible_ids = {e.get("debugId") for e in elems_before if e.get("visible")}
                if f"home-chain-open-btn-{first_chain_id}" in visible_ids:
                    click = h.ui("POST", "/click", {"query": home_selector})
                    clicked_selector = home_selector
                elif f"sidebar-chain-{first_chain_id}" in visible_ids:
                    click = h.ui("POST", "/click", {"query": sidebar_selector})
                    clicked_selector = sidebar_selector
                else:
                    click = {"found": False, "message": "no chain open selector visible"}
                    clicked_selector = ""
                sub_deadline = time.time() + 15
                while time.time() < sub_deadline:
                    st = h.ui("GET", "/state") or {}
                    surface = ((st.get("home") or {}).get("surface"))
                    selected = ((st.get("home") or {}).get("selectedChainId"))
                    elems = h.ui("GET", "/elements") or []
                    composer = next((e for e in elems if e.get("debugId") == "chain-coordinator-composer-input"), None)
                    last = {"attempts": attempts, "clicked_selector": clicked_selector, "click": click, "surface": surface, "selectedChainId": selected, "composer": composer, "visible_chain_ids": sorted([e.get("debugId") for e in elems if e.get("visible") and "chain" in str(e.get("debugId"))])[:40]}
                    if composer and composer.get("visible"):
                        return last
                    time.sleep(0.5)
            h.record_json(f"{sc.scenario_id}/composer-open-failure.json", last)
            raise HarnessError(f"coordinator composer did not appear after opening chain (retried): {last}")
        step(steps, "open first coding chain from UI and confirm composer", open_chain_until_composer)
        coordinator_msg = "Please coordinate the tiny README change, review, and merge-ready handoff. If the coordinator-owned Plan/control-plane review gate blocks progress, use the explicit audited coordinator --force path to advance it; do not wait indefinitely for reviewer LGTM, and do not fabricate votes."
        step(steps, "send coding instruction to coordinator via UI", lambda: h.ui("POST", "/type", {"query": '[data-debug-id="chain-coordinator-composer-input"]', "text": coordinator_msg}))
        step(steps, "submit coordinator message via UI", lambda: h.ui("POST", "/click", {"query": '[data-debug-id="chain-coordinator-send-btn"]'}))
        # Regression assertion for the fixed duplicate-message bug: the sent coordinator message
        # must render exactly once after the persisted server copy arrives (no lingering optimistic dupe).
        def wait_coordinator_message_rendered_once() -> dict[str, Any]:
            deadline = time.time() + 60
            last: dict[str, Any] = {}
            while time.time() < deadline:
                st = h.ui("GET", "/state") or {}
                cv = (st.get("chainView") or {})
                chat = ((cv.get("chatByChainId") or {}).get(first_chain_id) or [])
                optimistic = ((cv.get("optimisticMessagesByChainId") or {}).get(first_chain_id) or [])
                server_count = sum(1 for m in chat if (m.get("body") or "") == coordinator_msg)
                optimistic_count = sum(1 for m in optimistic if (m.get("body") or "") == coordinator_msg)
                total = server_count + optimistic_count
                last = {"server_count": server_count, "optimistic_count": optimistic_count, "total_rendered": total}
                # Persisted server copy present and no lingering optimistic duplicate.
                if server_count == 1 and optimistic_count == 0:
                    return last
                time.sleep(2)
            raise HarnessError(f"coordinator message did not render exactly once (duplicate-chat regression): {last}")
        render_once = step(steps, "assert coordinator message renders exactly once (no duplicate)", wait_coordinator_message_rendered_once)
        artifacts["coordinator_message_render"] = h.record_json(f"{sc.scenario_id}/coordinator-message-render.json", render_once)
        # CRITICAL: assert the coordinator actually RECEIVED and acted on the instruction, not just
        # that the message was sent/rendered. Guards against the user-chat unread read-race where the
        # coordinator is notified of a message, fetches empty unread, and goes idle without acting.
        # Product-observable signals that the instruction was consumed:
        #   - the coordinator's initial Plan task advances past its first in_progress claim, OR
        #   - a worker/reviewer team member gets booted (autoscaler launched due to progression), OR
        #   - the coordinator posts a task comment (plan handoff).
        def wait_coordinator_acted_on_instruction() -> dict[str, Any]:
            deadline = time.time() + 300
            baseline_workers = {coordinator_id}
            last: dict[str, Any] = {}
            while time.time() < deadline:
                st = h.ui("GET", "/state") or {}
                t = st.get("tasks") or {}
                byid = t.get("tasksById") or {}
                cti = (t.get("chainTaskIds") or {}).get(first_chain_id) or []
                statuses = [(byid.get(i) or {}).get("status") for i in cti]
                # A non-coordinator team member became live (worker/reviewer booted) => flow progressed.
                agents = h.http_get("/agents").get("agents", [])
                live_non_coord = [a.get("agent_instance_id") for a in agents
                                  if a.get("agent_instance_id") not in baseline_workers
                                  and a.get("connection_state") in {"connected", "registered"}]
                # Any scaffold task advanced beyond the initial planning/in_progress claim.
                advanced = any(s in {"review_ready", "approved", "completed", "done"} for s in statuses)
                last = {"task_statuses": statuses, "live_non_coordinator_agents": live_non_coord, "advanced": advanced}
                if advanced or live_non_coord:
                    return last
                time.sleep(5)
            raise HarnessError(f"coordinator did not act on the delivered instruction (possible user-chat unread read-race): {last}")
        acted = step(steps, "assert coordinator received and acted on the instruction", wait_coordinator_acted_on_instruction)
        artifacts["coordinator_acted"] = h.record_json(f"{sc.scenario_id}/coordinator-acted.json", acted)
        # Coordinator-authoritative scaffold gate regression: Plan keeps its visible review gate, but
        # the coordinator may explicitly force-advance with an audited FORCE_REVIEW_BYPASS event.
        def wait_plan_force_approved_and_implement_unblocked() -> dict[str, Any]:
            deadline = time.time() + 240
            last: dict[str, Any] = {}
            reviewer_started_once = False
            while time.time() < deadline:
                st = h.ui("GET", "/state") or {}
                t = st.get("tasks") or {}
                byid = t.get("tasksById") or {}
                cti = (t.get("chainTaskIds") or {}).get(first_chain_id) or []
                plan, implement = None, None
                for i in cti:
                    tk = byid.get(i) or {}
                    title = (tk.get("title") or "").lower()
                    if title.startswith("plan"):
                        plan = tk
                    if title.startswith("implement"):
                        implement = tk
                def required_reviewers(task: dict[str, Any] | None) -> list[str]:
                    if not task:
                        return []
                    return [p.get("agentInstanceId") or p.get("agent_instance_id") for p in (task.get("participants") or []) if p.get("role") == "lgtm_required"]
                plan_reviewers = required_reviewers(plan)
                # Deterministically hold normal reviewer LGTM so the coordinator must exercise the
                # explicit audited force path. We still count reviewer startup as evidence once seen.
                agents = h.http_get("/agents").get("agents", [])
                reviewer_live = [a.get("agent_instance_id") for a in agents if (a.get("agent_instance_id") or "").startswith("reviewer-") and (a.get("connection_state") in {"connected", "registered"} or a.get("startup_status") in {"starting", "ready"})]
                reviewer_started_once = reviewer_started_once or bool(reviewer_live) or any(name.startswith("agent-reviewer-") for name in h.tmux_window_names())
                killed_windows: list[str] = []
                if plan_reviewers and not reviewer_started_once:
                    reviewer_started_once = any(name.startswith("agent-reviewer-") for name in h.tmux_window_names())
                if plan_reviewers:
                    killed_windows = h.tmux_kill_windows_with_prefix("agent-reviewer-")
                audit_found = False
                audit_body = ""
                force_reason_seen = False
                plan_events: list[dict[str, Any]] = []
                if plan:
                    log = h.http_post("/user-rpc", {"action": "task_log", "client_instance_id": CLIENT_ID, "client_token": h.client_token, "task_id": plan.get("taskId") or plan.get("task_id")})
                    plan_events = log.get("events", [])
                    for e in plan_events:
                        body = e.get("body") or ""
                        if e.get("kind") == "Task_Status_Changed" and "FORCE_REVIEW_BYPASS" in body:
                            audit_found = True
                            audit_body = body
                            force_reason_seen = "--force" in coordinator_msg or "explicit audited coordinator --force path" in coordinator_msg or "force" in body.lower()
                            break
                plan_votes = (plan or {}).get("votes") or []
                last = {
                    "plan_status": (plan or {}).get("status"),
                    "plan_required_reviewers": plan_reviewers,
                    "plan_votes": plan_votes,
                    "force_audit_found": audit_found,
                    "force_audit_body": audit_body,
                    "implement_status": (implement or {}).get("status"),
                    "implement_required_reviewers": required_reviewers(implement),
                    "reviewer_started_once": reviewer_started_once,
                    "reviewer_live": reviewer_live,
                    "killed_reviewer_windows": killed_windows,
                }
                if any(v.get("approved") for v in plan_votes):
                    raise HarnessError(f"Plan advanced via reviewer LGTM before coordinator force; deterministic force branch not exercised: {last}")
                if (last["plan_status"] in {"approved", "done", "completed"}
                    and last["plan_required_reviewers"]
                    and not last["plan_votes"]
                    and last["force_audit_found"]
                    and last["implement_status"] in {"queued", "in_progress", "review_ready", "approved", "done", "completed"}
                    and last["implement_required_reviewers"]
                    and last["reviewer_started_once"]):
                    return last
                time.sleep(1)
            raise HarnessError(f"coordinator Plan did not use audited force bypass/unblock Implement: {last}")
        plan_gate = step(steps, "assert coordinator Plan force-bypasses review and Implement unblocks", wait_plan_force_approved_and_implement_unblocked)
        artifacts["coordinator_plan_gate"] = h.record_json(f"{sc.scenario_id}/coordinator-plan-gate.json", plan_gate)
        # Regression assertion for the send_to_user NOT NULL/empty-bind bug: the coordinator must be
        # able to reply to the user. We assert a coordinator agent_to_user message becomes visible
        # to the user (persisted + fetchable), proving reply delivery works end-to-end.
        def wait_coordinator_reply_visible() -> dict[str, Any]:
            deadline = time.time() + 240
            last: dict[str, Any] = {}
            while time.time() < deadline:
                st = h.ui("GET", "/state") or {}
                cv = (st.get("chainView") or {})
                chat = ((cv.get("chatByChainId") or {}).get(first_chain_id) or [])
                agent_to_user = [m for m in chat if (m.get("direction") == "agent_to_user" or m.get("author") == "agent")]
                last = {"agent_to_user_count": len(agent_to_user)}
                if agent_to_user:
                    return last
                time.sleep(5)
            raise HarnessError(f"coordinator reply to user was never delivered (possible send_to_user NOT NULL/empty-bind regression): {last}")
        reply_visible = step(steps, "assert coordinator reply to user is delivered", wait_coordinator_reply_visible)
        artifacts["coordinator_reply"] = h.record_json(f"{sc.scenario_id}/coordinator-reply.json", reply_visible)
        # Division-of-labor assertion: the coordinator must delegate, not do implementation/review
        # itself. Verify real worker agents (coder + reviewer team members) actually START, and that
        # implementation/review tasks are assigned to those workers (not to the coordinator).
        def wait_worker_agents_started() -> dict[str, Any]:
            deadline = time.time() + 420
            last: dict[str, Any] = {}
            coder_seen, reviewer_seen = set(), set()
            while time.time() < deadline:
                st = h.ui("GET", "/state") or {}
                t = st.get("tasks") or {}
                byid = t.get("tasksById") or {}
                cti = (t.get("chainTaskIds") or {}).get(first_chain_id) or []
                agents = h.http_get("/agents").get("agents", [])
                def is_live(aid: str) -> bool:
                    a = next((x for x in agents if x.get("agent_instance_id") == aid), None)
                    return bool(a and (a.get("connection_state") in {"connected", "registered"} or a.get("startup_status") in {"starting", "ready"}))
                # Identify implementation/review tasks and their assignees.
                impl_assignees, review_assignees = set(), set()
                for i in cti:
                    tk = byid.get(i) or {}
                    title = (tk.get("title") or "").lower()
                    asg = tk.get("assigneeAgentInstanceId") or ""
                    if title.startswith("implement") or title.startswith("validate"):
                        impl_assignees.add(asg)
                    if title.startswith("review"):
                        review_assignees.add(asg)
                for a in agents:
                    aid = a.get("agent_instance_id") or ""
                    if aid.startswith("coder-") and is_live(aid):
                        coder_seen.add(aid)
                    if aid.startswith("reviewer-") and is_live(aid):
                        reviewer_seen.add(aid)
                for name in h.tmux_window_names():
                    if name.startswith("agent-coder-"):
                        coder_seen.add(name[len("agent-"):])
                    if name.startswith("agent-reviewer-"):
                        reviewer_seen.add(name[len("agent-"):])
                last = {
                    "impl_assignees": sorted(impl_assignees),
                    "review_assignees": sorted(review_assignees),
                    "coder_agents_started": sorted(coder_seen),
                    "reviewer_agents_started": sorted(reviewer_seen),
                }
                # Implementation/review must NOT be assigned to the coordinator.
                coordinator_did_impl = coordinator_id in impl_assignees
                coordinator_did_review = coordinator_id in review_assignees
                if coordinator_did_impl or coordinator_did_review:
                    raise HarnessError(f"coordinator was assigned implementation/review work (should delegate): {last}")
                # Require both a coder and reviewer worker agent to have actually started at some point in this run.
                if coder_seen and reviewer_seen:
                    return last
                time.sleep(5)
            raise HarnessError(f"real coder/reviewer worker agents did not both start (coordinator should not do the work): {last}")
        workers = step(steps, "assert real coder and reviewer worker agents start (coordinator delegates)", wait_worker_agents_started)
        artifacts["worker_agents"] = h.record_json(f"{sc.scenario_id}/worker-agents.json", workers)
        def wait_after_coordinator_message() -> dict[str, Any]:
            deadline = time.time() + 900
            last = h.ui("GET", "/state")
            # Terminal-ish chain states that satisfy "merge-ready / completed" for the flow.
            done_statuses = {"completed", "approved", "merge_pending", "reviewing"}
            pane_idx = 0
            next_pane_capture = time.time()
            while time.time() < deadline:
                last = h.ui("GET", "/state")
                chains_by_id = (((last or {}).get("tasks") or {}).get("chainsById") or {})
                first_status = (chains_by_id.get(first.get("chainId")) or {}).get("status")
                # Periodically capture the real-agent pane so long runs leave behavior evidence
                # even if the daemon later restarts/reconnects agents.
                if time.time() >= next_pane_capture:
                    try:
                        h.capture_real_pi_pane(f"{sc.scenario_id}/real-pi-pane-{pane_idx}.txt", agent_instance_id=coordinator_id)
                    except Exception:
                        pass
                    pane_idx += 1
                    next_pane_capture = time.time() + 30
                # Only chain status decides completion. Do NOT exit on transient agent
                # offline/reconnect: product lifecycle may restart agents mid-flow.
                if first_status in done_statuses:
                    return last
                time.sleep(5)
            return last
        state = step(steps, "capture Redux status after coordinator message and real-agent wait", wait_after_coordinator_message)
        artifacts["redux_state"] = h.record_json(f"{sc.scenario_id}/redux-state.json", state)
        artifacts["real_pi_pane"] = h.capture_real_pi_pane(f"{sc.scenario_id}/real-pi-pane.txt", agent_instance_id=coordinator_id)
        artifacts["screenshot"] = h.screenshot(f"{sc.scenario_id}/coordinator-chat.png")
        first_id = first.get("chainId")
        if not first_id:
            raise HarnessError("coding chain must be visible with a chain ID")
        chains_by_id = (((state or {}).get("tasks") or {}).get("chainsById") or {})
        agent = next((a for a in (((state or {}).get("chat") or {}).get("agents") or []) if a.get("id") == coordinator_id), {})
        completion = {
            "first_status": (chains_by_id.get(first_id) or {}).get("status"),
            "coordinator_id": coordinator_id,
            "real_pi_status": agent.get("status"),
            "real_pi_startup_status": agent.get("startupStatus"),
            "workspace_ui_present": bool(((state or {}).get("chainView") or {}).get("workspaceByChainId")),
            "coordinator_message_sent": bool((((state or {}).get("chainView") or {}).get("optimisticMessagesByChainId") or {}).get(first_id) or (((state or {}).get("chainView") or {}).get("chatByChainId") or {}).get(first_id)),
        }
        step(steps, "assert real pi/Codex coding flow reached merge-ready/completed UI state", lambda: completion)
        done_statuses = {"completed", "approved", "merge_pending", "reviewing"}
        if completion["first_status"] not in done_statuses:
            raise HarnessError(f"real pi/Codex coding chain did not reach merge-ready/completed UI state: {completion}")
        return ScenarioResult(sc.scenario_id, sc.title, True, "passed", steps, artifacts=artifacts)
    except Exception as exc:
        return ScenarioResult(sc.scenario_id, sc.title, False, "failed", steps, blockers=[str(exc)], artifacts=artifacts)


def scenario_research_report_memory_restart(h: Harness, sc: Scenario) -> ScenarioResult:
    steps: list[Step] = []
    artifacts: dict[str, str] = {}
    try:
        project_id_setup = step(steps, "setup non-VCS research project", lambda: h.create_project_setup("Task18 research memory project", "none"))
        chain = ui_create_chain(h, steps, title="Task18 research report memory restart", goal="Create report scaffold and verify Team_Project memory remains after daemon restart.", kind="research", wants_vcs=False, project_id=project_id_setup)
        chain_id, team_id, project_id = chain.get("chainId"), chain.get("teamId"), chain.get("projectId")
        if not chain_id or not team_id or not project_id:
            raise HarnessError(f"research chain missing IDs: chain={chain_id} team={team_id} project={project_id}")
        proposed = step(steps, "create Team_Project memory proposal through isolated helper", lambda: h.http_post("/memory/propose/new", {"agent_token": h.agent_token, "scope": "team_project", "team_id": team_id, "project_id": project_id, "type": "fact", "title": "Task18 research memory", "body": "Team_Project memory must survive isolated daemon restart.", "reason": "Task18 canonical E2E"}))
        memory_id = proposed.get("memory_id")
        proposal_id = proposed.get("proposal_id")
        if not memory_id or not proposal_id:
            raise HarnessError(f"memory proposal failed: {proposed}")
        step(steps, "approve Team_Project memory proposal", lambda: h.http_post("/memory/decide", {"agent_token": h.agent_token, "proposal_id": proposal_id, "decision": "approve", "reason": "Task18 canonical E2E setup"}))
        before_mem = step(steps, "list Team_Project memory before restart", lambda: h.http_post("/memory/list", {"agent_token": h.agent_token, "scope": "team_project", "team_id": team_id, "project_id": project_id}))
        before = step(steps, "capture Redux before isolated daemon restart", lambda: h.ui("GET", "/state"))
        artifacts["before_restart_memory"] = h.record_json(f"{sc.scenario_id}/before-restart-memory.json", before_mem)
        artifacts["before_restart_state"] = h.record_json(f"{sc.scenario_id}/before-restart-state.json", before)
        # Restart only the isolated daemon owned by this harness. The UI reconnects to the same daemon URL.
        if h.daemon_proc:
            h.daemon_proc.terminate(); h.daemon_proc.wait(timeout=10); wait_port_closed(h.daemon_port)
        h.start_daemon()
        time.sleep(2.0)
        after_mem = step(steps, "list Team_Project memory after restart", lambda: h.http_post("/memory/list", {"agent_token": h.agent_token, "scope": "team_project", "team_id": team_id, "project_id": project_id}))
        after = step(steps, "capture Redux after isolated daemon restart without manual browser refresh", lambda: h.ui("GET", "/state"))
        artifacts["after_restart_memory"] = h.record_json(f"{sc.scenario_id}/after-restart-memory.json", after_mem)
        artifacts["after_restart_state"] = h.record_json(f"{sc.scenario_id}/after-restart-state.json", after)
        artifacts["screenshot"] = h.screenshot(f"{sc.scenario_id}/after-restart.png")
        records = after_mem.get("records") or []
        if not any(r.get("memory_id") == memory_id and r.get("scope") == "Team_Project" for r in records):
            raise HarnessError(f"Team_Project memory {memory_id} did not survive restart")
        return ScenarioResult(sc.scenario_id, sc.title, True, "passed", steps, artifacts=artifacts)
    except Exception as exc:
        return ScenarioResult(sc.scenario_id, sc.title, False, "failed", steps, blockers=[str(exc)], artifacts=artifacts)


def scenario_legacy_migration_copy(h: Harness, sc: Scenario) -> ScenarioResult:
    steps: list[Step] = []
    artifacts: dict[str, str] = {}
    try:
        source = h.temp_dir / "legacy-source"
        copy = h.temp_dir / "legacy-copy"
        source.mkdir(parents=True, exist_ok=True)
        (source / "README-legacy.txt").write_text("synthetic legacy copy fixture for isolated migration preflight\n", encoding="utf-8")
        step(steps, "copy legacy data_dir fixture", lambda: str(shutil.copytree(source, copy)))
        if not copy.exists() or copy == Path.home():
            raise HarnessError("legacy migration copy fixture was not isolated")
        artifacts["copied_legacy_dir"] = str(copy)
        if h.daemon_proc:
            h.daemon_proc.terminate(); h.daemon_proc.wait(timeout=10); h.daemon_proc = None
        migration_config = h.temp_dir / "migration-copy.toml"
        cfg_text = replace_toml_value(h.config_path.read_text(encoding="utf-8"), "data_dir", quote(str(copy)), section="daemon")
        migration_config.write_text(cfg_text, encoding="utf-8")
        env = os.environ.copy(); env["HEIMDALL_MIGRATE_V1"] = "1"
        log_path = h.out_dir / f"{sc.scenario_id}" / "migration-daemon.log"
        log_path.parent.mkdir(parents=True, exist_ok=True)
        log = log_path.open("w", encoding="utf-8")
        proc = subprocess.Popen([h.ham_daemon, "--config", str(migration_config)], cwd=str(ROOT), env=env, text=True, stdout=log, stderr=subprocess.STDOUT)
        h.daemon_proc = proc
        step(steps, "start migration daemon on isolated copy", lambda: wait_http(f"{h.daemon_url}/health", timeout=20) or {"daemon_url": h.daemon_url})
        proc.terminate(); proc.wait(timeout=10); h.daemon_proc = None
        reports = sorted((copy / "migrations").glob("teams-v1-*.report.md"))
        artifacts["migration_log"] = str(log_path)
        artifacts["migration_reports"] = h.record_json(f"{sc.scenario_id}/migration-reports.json", [str(p) for p in reports])
        if not reports:
            raise HarnessError("migration on isolated copy did not produce a teams-v1 report")
        if not (copy / "migrations" / "teams-v1.complete").exists():
            raise HarnessError("migration marker missing on isolated copy")
        return ScenarioResult(sc.scenario_id, sc.title, True, "passed", steps, artifacts=artifacts)
    except Exception as exc:
        return ScenarioResult(sc.scenario_id, sc.title, False, "failed", steps, blockers=[str(exc)], artifacts=artifacts)


def scenario_idle_shutdown_auto_boot(h: Harness, sc: Scenario) -> ScenarioResult:
    steps: list[Step] = []
    artifacts: dict[str, str] = {}
    try:
        project_id = step(steps, "setup no-VCS idle/nudge project", lambda: h.create_project_setup("Task18 idle nudge project", "none"))
        chain = ui_create_chain(h, steps, title="Task18 idle shutdown auto boot", goal="Validate idle shutdown then nudge/auto-boot on first ready task.", kind="solo", wants_vcs=False, project_id=project_id)
        chain_id = chain.get("chainId")
        if not chain_id:
            raise HarnessError("idle/nudge chain missing chainId")
        step(steps, "activate chain so queued work is executable", lambda: h.http_post("/task-chains/activate", {"agent_token": h.agent_token, "chain_id": chain_id}))
        task = step(steps, "setup queued task eligible for scheduled nudge", lambda: h.http_post("/tasks/create", {"agent_token": h.agent_token, "chain_id": chain_id, "title": "Task18 nudge target", "assignee_agent_instance_id": "pi@task18-e2e", "status": "queued"}))
        task_id = task.get("task_id")
        step(steps, "open Attention surface for nudge/status validation", lambda: h.ui("POST", "/click", {"query": '[data-debug-id="nav-attention-btn"]'}))
        time.sleep(4.0)
        elems = step(steps, "collect Attention elements after nudge interval", lambda: h.ui("GET", "/elements"))
        state = step(steps, "capture Redux status after nudge interval", lambda: h.ui("GET", "/state"))
        artifacts["elements"] = h.record_json(f"{sc.scenario_id}/elements.json", elems)
        artifacts["redux_state"] = h.record_json(f"{sc.scenario_id}/redux-state.json", state)
        artifacts["screenshot"] = h.screenshot(f"{sc.scenario_id}/attention-nudge.png")
        def nudge_events() -> list[str]:
            db_path = h.data_dir / "tasks" / "task.db"
            conn = sqlite3.connect(db_path)
            try:
                return [row[0] for row in conn.execute("SELECT event_json FROM task_events WHERE (event_json LIKE '%Task_Nudged%' OR event_json LIKE '%Task_Nudge_Failed%') AND event_json LIKE ?", (f"%{task_id}%",))]
            finally:
                conn.close()
        nudges = step(steps, "assert scheduled nudge outcome was persisted", nudge_events)
        artifacts["nudge_events"] = h.record_json(f"{sc.scenario_id}/nudge-events.json", nudges)
        if not nudges:
            raise HarnessError(f"no scheduled nudge outcome persisted for {task_id}")
        tasks = ((state or {}).get("tasks") or {}).get("tasksById") or {}
        if task_id not in tasks:
            raise HarnessError(f"UI state does not include nudge target task {task_id}")
        return ScenarioResult(sc.scenario_id, sc.title, True, "passed", steps, artifacts=artifacts)
    except Exception as exc:
        return ScenarioResult(sc.scenario_id, sc.title, False, "failed", steps, blockers=[str(exc)], artifacts=artifacts)


def scenario_coordinator_contact_invariants(h: Harness, sc: Scenario) -> ScenarioResult:
    steps: list[Step] = []
    artifacts: dict[str, str] = {}
    try:
        wrapper = (ROOT / "src" / "wrapper" / "main.odin").read_text(encoding="utf-8")
        prompt = (ROOT / "src" / "prompts" / "bootstrap_profile_guidance.md").read_text(encoding="utf-8")
        ui = (ROOT / "src" / "ui" / "components" / "App.tsx").read_text(encoding="utf-8")
        checks = {
            "BS-6 non-coordinator no direct send-to-user": "Do not use direct `chat send-to-user` for normal user contact" in wrapper and "If you are not the coordinator, do not use direct `chat send-to-user`" in prompt,
            "BS-6 coordinator owns contact": "You are the coordinator for free-form user contact" in wrapper and "If you are the coordinator" in prompt,
            "UI-5 coordinator composer": "chain-coordinator-composer-input" in ui and "sendCoordinatorMessage" in ui,
            "API-4 Needs attention allowed": "Needs attention" in prompt and "Needs attention" in wrapper,
        }
        step(steps, "evaluate BS-6/UI-5/API-4 source invariants", lambda: checks)
        failed = [name for name, ok in checks.items() if not ok]
        artifacts["invariants"] = h.record_json(f"{sc.scenario_id}/invariants.json", checks)
        if failed:
            raise HarnessError(f"invariant checks failed: {failed}")
        return ScenarioResult(sc.scenario_id, sc.title, True, "passed", steps, artifacts=artifacts)
    except Exception as exc:
        return ScenarioResult(sc.scenario_id, sc.title, False, "failed", steps, blockers=[str(exc)], artifacts=artifacts)


SCENARIOS: list[Scenario] = [
    Scenario("coding-two-teams-real-pi", "Single coding chain on a git-backed project progresses with real pi/Codex agents", scenario_coding_two_teams_real_pi, requires_real_codex=True, task18_requirement="real pi+Codex simple coding flow, clean merge, nudges, UI status"),
    Scenario("solo-user-proxy", "Solo vcs_kind=none chain approved via user_proxy smart-reply", scenario_ui_no_vcs_user_proxy, task18_requirement="UI-driven no-VCS chain creation and user_proxy/Needs attention approval surface"),
    Scenario("research-report-memory-restart", "Research/report scaffold with Team_Project memory surviving daemon restart", scenario_research_report_memory_restart, task18_requirement="research report + memory survives restart"),
    Scenario("legacy-migration-copy", "Legacy migration on fresh copy of live data_dir", scenario_legacy_migration_copy, requires_ui=False, task18_requirement="migration copy, never live DB"),
    Scenario("idle-shutdown-auto-boot", "Idle shutdown after 30 min then auto-boot/nudge on first ready task", scenario_idle_shutdown_auto_boot, task18_requirement="nudges, auto-boot, UI status correctness"),
    Scenario("redux-ui-freshness", "Rewritten UI stays synchronized without manual refresh", scenario_redux_freshness, task18_requirement="Redux no-refresh freshness evidence"),
    # UI-5 canonical selector: chain-coordinator-composer-input sends only to coordinator.
    Scenario("coordinator-contact-invariants", "Coordinator-only user-contact invariants BS-6/UI-5/API-4", scenario_coordinator_contact_invariants, requires_ui=False, task18_requirement="BS-6/UI-5/API-4: non-coordinators route through coordinator; Needs attention allowed"),
]


def run_harness(args: argparse.Namespace) -> int:
    blockers, details = preflight(args)
    out_dir = Path(args.artifacts_dir or TRANSCRIPT_ROOT / time.strftime("%Y%m%d-%H%M%S"))
    out_dir.mkdir(parents=True, exist_ok=True)
    preflight_path = out_dir / "preflight.json"
    preflight_path.write_text(json.dumps({"ok": not blockers, "blockers": blockers, "details": details}, indent=2) + "\n")
    if args.preflight and (not blockers or args.allow_external_blockers):
        print(f"PREFLIGHT_TRANSCRIPT={preflight_path}")
        if blockers:
            print("PREFLIGHT_EXTERNAL_BLOCKERS=" + json.dumps(blockers))
        return 0
    if blockers:
        print(f"PREFLIGHT_TRANSCRIPT={preflight_path}")
        print("PREFLIGHT_FAILED=" + json.dumps(blockers))
        return 2

    h = Harness(args)
    results: list[ScenarioResult] = []
    try:
        selected = set(args.scenario or [s.scenario_id for s in SCENARIOS])
        selected_scenarios = [s for s in SCENARIOS if s.scenario_id in selected or "all" in selected]
        needs_ui = any(s.requires_ui for s in selected_scenarios)
        h.prepare_binaries()
        h.write_isolated_config()
        h.start_daemon()
        h.register_client_and_seed_agent()
        if "coding-two-teams-real-pi" in selected or "all" in selected:
            repo = make_git_repo(h.temp_dir / "coding-two-teams")
            project_id = h.create_project_setup("Task18 real pi coding project", "git", repo, project_id="default")
            h.seed_offline_coordinator("pi@task18-e2e", project_id)
            h.precreated["coding-two-teams-real-pi"] = {"repo": repo, "project_id": project_id}
        if needs_ui:
            h.build_ui()
            h.start_ui()
        for sc in SCENARIOS:
            if sc.scenario_id not in selected and "all" not in selected:
                continue
            result = sc.run(h, sc)
            results.append(result)
            h.record_json(f"{sc.scenario_id}/transcript.json", result_to_json(result, sc))
        ok = all(r.ok for r in results)
        summary = {"ok": ok, "task": "task-19f4b590d38", "runner_task": "task-19f4effc9ca", "artifacts_dir": str(h.out_dir), "isolated_daemon_url": h.daemon_url, "isolated_data_dir": str(h.data_dir), "isolated_config": str(h.config_path), "isolated_credentials_path": str(h.credentials_path), "credentials_source": str(h.credentials_source) if h.credentials_source else "generated-isolated-empty", "uses_global_wrapper_credentials": False, "results": [result_to_json(r, find_scenario(r.scenario_id)) for r in results]}
        summary_path = h.record_json("runner-transcript.json", summary)
        print(f"RUNNER_TRANSCRIPT={summary_path}")
        return 0 if ok else 1
    finally:
        h.close()


def find_scenario(scenario_id: str) -> Scenario:
    for sc in SCENARIOS:
        if sc.scenario_id == scenario_id:
            return sc
    raise KeyError(scenario_id)


def result_to_json(result: ScenarioResult, sc: Scenario) -> dict[str, Any]:
    return {
        "scenario_id": result.scenario_id,
        "title": result.title,
        "ok": result.ok,
        "status": result.status,
        "task18_requirement": sc.task18_requirement,
        "requires_ui": sc.requires_ui,
        "requires_real_codex": sc.requires_real_codex,
        "blockers": result.blockers,
        "artifacts": result.artifacts,
        "steps": [s.__dict__ for s in result.steps],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--preflight", action="store_true", help="validate prerequisites and write preflight transcript only")
    parser.add_argument("--allow-external-blockers", action="store_true", help="return 0 for preflight-only runs even when external pi/UI prerequisites are missing")
    parser.add_argument("--scenario", action="append", help="scenario id to run; repeatable; default all")
    parser.add_argument("--daemon-port", type=int, default=DEFAULT_PORT, help="isolated daemon port; default 49422")
    parser.add_argument("--artifacts-dir", help="where transcripts/artifacts are written")
    parser.add_argument("--wrapper-credentials-path", default=os.environ.get("HEIMDALL_E2E_WRAPPER_CREDENTIALS", ""), help="optional source credentials file copied into the runner-owned isolated credentials path; env HEIMDALL_E2E_WRAPPER_CREDENTIALS is also honored")
    parser.add_argument("--keep-temp", action="store_true", help="keep isolated daemon data/temp directory")
    args = parser.parse_args()
    return run_harness(args)


if __name__ == "__main__":
    raise SystemExit(main())
