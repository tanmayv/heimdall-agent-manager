#!/usr/bin/env python3
"""Observe an actual configured CLI on a private PTY; never infer an interrupt pass."""
import hashlib
import shlex
import tomllib
import argparse
import json
import os
import re
from pathlib import Path
import shutil
import socket
import struct
import subprocess
import time
import uuid


def text(value):
    data = value.encode()
    return struct.pack(">I", len(data)) + data


class Reader:
    def __init__(self, data):
        self.data = data
        self.offset = 0

    def take(self, size):
        out = self.data[self.offset:self.offset + size]
        if len(out) != size:
            raise RuntimeError("truncated daemon reply")
        self.offset += size
        return out

    def string(self):
        return self.take(struct.unpack(">I", self.take(4))[0]).decode()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--daemon", required=True)
    parser.add_argument("--provider", required=True, choices=["codex", "claude"])
    parser.add_argument("--model", required=True, help="Existing enabled catalog/profile model")
    parser.add_argument("--seconds", type=int, default=15)
    parser.add_argument("--escape-observe", action="store_true", help="Observe native busy -> ESC -> interruption separately; no notification-profile pass")
    parser.add_argument("--literal", action="store_true", help="Probe literal transport and exact native user transcript; no interrupt")
    parser.add_argument("--native-interrupt", action="store_true", help="Require spawn-fixed Codex profile and typed native acknowledgment through daemon dispatch")
    parser.add_argument("--native-hook", action="store_true", help="Require actual installed native SessionStart callback before lazy binding")
    parser.add_argument("--vetted-fixture-hook", action="store_true", help="Explicitly reviewed disposable project SessionStart hook with one-invocation trust flag; no production proof")
    args = parser.parse_args()
    if args.vetted_fixture_hook and not args.native_hook: parser.error("--vetted-fixture-hook requires --native-hook")
    if args.native_hook and not args.native_interrupt: parser.error("--native-hook requires --native-interrupt")
    if args.native_interrupt and (not args.literal or args.provider!="codex"):
        parser.error("--native-interrupt requires --literal --provider codex")
    if not 1 <= args.seconds <= 60:
        parser.error("--seconds must be between 1 and 60")
    cli = shutil.which(args.provider)
    if not cli:
        raise RuntimeError("selected provider executable unavailable")
    version = subprocess.check_output([cli, "--version"], text=True).strip()
    run_id = uuid.uuid4().hex
    root = Path.home() / ".cache/heimdall-tests" / ("provider-observe-" + run_id)
    root.mkdir(parents=True, mode=0o700)
    address = "/tmp/ham-provider-observe-" + run_id + ".sock"
    instance = "probe_" + run_id
    daemon = subprocess.Popen([args.daemon, "--socket", address, "daemon"],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def exchange(payload):
        with socket.socket(socket.AF_UNIX) as stream:
            stream.settimeout(30 if payload[:1]==b"\x20" else 5)
            stream.connect(address)
            stream.sendall(struct.pack(">I", len(payload)) + payload)

            def read(size):
                out = b""
                while len(out) < size:
                    part = stream.recv(size - len(out))
                    if not part:
                        raise RuntimeError("daemon closed before reply")
                    out += part
                return out
            size = struct.unpack(">I", read(4))[0]
            if size > 4 * 1024 * 1024:
                raise RuntimeError("daemon reply exceeded bound")
            return read(size)

    try:
        for _ in range(100):
            if Path(address).exists():
                break
            if daemon.poll() is not None:
                raise RuntimeError("private daemon exited")
            time.sleep(0.05)
        argv = [cli, "--model", args.model]
        session_id = str(uuid.uuid4())
        if args.provider == "claude":
            argv += ["--session-id", session_id]
        if args.provider == "codex":
            argv += ["--no-alt-screen", "--sandbox", "read-only", "-c", "check_for_update_on_startup=false"]
        # Normal provider auth remains in its own store. The probe receives no
        # production Heimdall credential, routing identity or local endpoint.
        overrides = {name: "" for name in os.environ if name.startswith("HEIMDALL_")}
        overrides.update(HEIMDALL_STARTUP_KEY=run_id, HEIMDALL_NOTIFICATION_EPOCH="probe_epoch",
                         HEIMDALL_NOTIFICATION_RUN_COUNT="1")

        if args.native_hook:
            hook_script=root/"native-session-hook.py"
            hook_source=r"""#!/usr/bin/env python3
import json,socket,struct,sys,time
from pathlib import Path
ROOT=Path(__ROOT__)
ADDRESS=__ADDRESS__
INSTANCE=__INSTANCE__
KEY=__KEY__
def text(s): b=s.encode();return struct.pack(">I",len(b))+b
def exchange(payload):
    with socket.socket(socket.AF_UNIX) as stream:
        stream.settimeout(5);stream.connect(ADDRESS);stream.sendall(struct.pack(">I",len(payload))+payload)
        def read(n):
            data=b""
            while len(data)<n:
                chunk=stream.recv(n-len(data))
                if not chunk:raise RuntimeError("short reply")
                data+=chunk
            return data
        n=struct.unpack(">I",read(4))[0]
        if n>65536:raise RuntimeError("oversized reply")
        return read(n)
def string(data,off):
    size=struct.unpack(">I",data[off:off+4])[0];off+=4
    return data[off:off+size].decode(),off+size
try:
    event=json.load(sys.stdin)
    if event.get("hook_event_name")!="SessionStart":sys.exit(0)
    if event.get("cwd")!=str(ROOT):sys.exit(1)
    session=event.get("session_id","");path=event.get("transcript_path","");source=event.get("source","")
    pid=0
    for _ in range(20):
        reply=exchange(b"\x3b"+text(INSTANCE)+text(KEY))
        if reply[:1]!=b"\xb2":raise RuntimeError("startup query rejected")
        instance,off=string(reply,1);pid=struct.unpack(">i",reply[off:off+4])[0]
        if pid>0:break
        time.sleep(.05)
    existed=Path(path).exists()
    reply=exchange(b"\x42"+text(INSTANCE)+struct.pack(">i",pid)+b"".join(text(s) for s in (KEY,"probe_epoch","1",session,path,source)))
    proof=dict(event="SessionStart",session=session,path=path,source=source,path_existed=existed,accepted=reply[:1]==b"\xb4")
    with (ROOT/"native-hook-proof.jsonl").open("a") as out:out.write(json.dumps(proof)+"\n")
except Exception as error:
    with (ROOT/"native-hook-proof.jsonl").open("a") as out:out.write(json.dumps(dict(error=str(error)))+"\n")
"""
            for name,value in {"__ROOT__":str(root),"__ADDRESS__":address,"__INSTANCE__":instance,"__KEY__":run_id}.items():
                hook_source=hook_source.replace(name,repr(value))
            hook_script.write_text(hook_source);hook_script.chmod(0o700)
            overrides["HEIMDALL_CTL_BIN"]=str(hook_script)
            if args.vetted_fixture_hook:
                # Coordinator explicitly approved this inspected disposable
                # script and invocation only. Never persist native trust/config.
                native_home=Path(os.environ.get("CODEX_HOME",str(Path.home()/".codex")))
                user_config=tomllib.loads((native_home/"config.toml").read_text()) if (native_home/"config.toml").exists() else {}
                if (native_home/"hooks.json").exists() or any(key[:1].isupper() for key in user_config.get("hooks",{})):
                    raise RuntimeError("unreviewed user hook source present; refuse global trust bypass")
                # A session config override avoids a project-local executable
                # config layer and its persisted folder-trust prompt. The hook
                # still requires this exact source to have been reviewed.
                hook_config='hooks.SessionStart=[{hooks=[{type="command",command='+json.dumps(shlex.quote(str(hook_script)))+',timeout=5}]}]'
                hook_file=root/"vetted-session-hook.toml"
                hook_file.write_text(hook_config+"\n")
                argv+=["--dangerously-bypass-hook-trust","-c",hook_config]
                for plugin in user_config.get("plugins",{}):
                    argv+=["-c","plugins."+json.dumps(plugin)+".enabled=false"]
                (root/"vetted-hook-source.json").write_text(json.dumps(dict(
                    hook_sha256=hashlib.sha256(hook_script.read_bytes()).hexdigest(),
                    config_sha256=hashlib.sha256(hook_file.read_bytes()).hexdigest(),
                    argv=argv,scope="disposable_native_callback_mechanics_only")))


        env = list(overrides.items())
        payload = b"\x20" + text(instance) + struct.pack(">H", len(argv))
        payload += b"".join(map(text, argv)) + b"\x01" + text(str(root))
        payload += struct.pack(">H", len(env)) + b"".join(text(k) + text(v) for k, v in env)
        payload += b"\x00" + struct.pack(">HH", 36, 120) + b"\x00" * 5
        payload += b"\x01" + struct.pack(">Q", args.seconds + 30)
        payload += (b"\x01" + text("codex-native-session-v1")) if args.native_interrupt else b"\x00"
        reply = Reader(exchange(payload))
        if reply.take(1) != b"\xa0" or reply.string() != instance:
            raise RuntimeError("provider spawn rejected")
        pid = struct.unpack(">i", reply.take(4))[0]
        def screen():
            capture = Reader(exchange(b"\x34" + text(instance)))
            if capture.take(1) != b"\xa5" or capture.string() != instance:
                raise RuntimeError("provider capture unavailable")
            rows, cols, cursor_row, cursor_col, count = struct.unpack(">HHHHH", capture.take(10))
            return [capture.string() for _ in range(count)]

        def send_only(payload):
            with socket.socket(socket.AF_UNIX) as stream:
                stream.settimeout(5)
                stream.connect(address)
                stream.sendall(struct.pack(">I", len(payload)) + payload)

        time.sleep(args.seconds)
        lines = screen()
        literal_evidence = None
        escape_evidence = None
        native_evidence = None
        if args.escape_observe and not args.literal:
            raise RuntimeError("--escape-observe requires --literal")
        if args.literal:
            view = "\n".join(lines)
            if args.provider == "claude" and str(root) in view and "Yes, I trust this folder" in view:
                # The harness just created this empty fixture. This approves
                # only that exact known workspace, never auth or another path.
                send_only(b"\x31" + text(instance) + b"\x1b[B\r")
                time.sleep(3)
                lines = screen()
                view = "\n".join(lines)
            if any(term in view.lower() for term in ["sign in", "log in", "yes, i trust this folder", "oauth", "update available", "update now", "security notes", "choose your theme", "select a theme"]):
                raise RuntimeError("provider is still at an auth/workspace/update/onboarding gate; no input sent")
            if args.provider=="codex" and ("›" not in view or not any(term in view.lower() for term in ("context left","ask codex to do anything")) or "openai codex" not in view.lower()):
                raise RuntimeError("native Codex input UI readiness not established; no input sent")
            if args.provider=="claude" and ("❯" not in view or not any(name in view.lower() for name in ("opus","sonnet","haiku"))):
                raise RuntimeError("native Claude input UI readiness not established; no input sent")
            marker = "literal_probe_" + run_id
            instruction = ("Do not use tools. Count from 1 to 100000, one integer per line." if args.escape_observe or args.native_interrupt
                           else "Do not use tools. Reply OK only.")
            message = instruction + "\n" + marker + "\n\t€ 日本語 😀"
            operation = "operation_" + run_id
            delivery = "delivery_" + run_id

            interrupt = False
            def notification(mode, ticket=""):
                return (b"\x3c" + bytes([mode]) + text(ticket) + text(instance) + struct.pack(">i", pid)
                        + b"".join(text(v) for v in [run_id, "probe_epoch", "1", operation, delivery])
                        + bytes([int(interrupt)]) + message.encode())

            def receipt(payload):
                r = Reader(exchange(payload))
                tag = r.take(1)
                if tag == b"\xa8":
                    raise RuntimeError("notification rejected: " + r.string() + " " + r.string())
                if tag != b"\xb3" or r.string() != instance or r.string() != delivery:
                    raise RuntimeError("wrong notification receipt identity")
                ticket = r.string()
                esc = bool(r.take(1)[0])
                written = struct.unpack(">i", r.take(4))[0]
                enter = bool(r.take(1)[0])
                status = r.take(1)[0]
                profile = r.string()
                retry = struct.unpack(">i", r.take(4))[0]
                return dict(ticket=ticket, esc=esc, written=written, enter=enter, status=status, profile=profile, retry=retry)

            prepared = receipt(notification(0))
            if prepared["status"] != 0 or not prepared["ticket"]:
                raise RuntimeError("Prepare did not retain a ticket")
            (root / "intent.json").write_text(json.dumps(dict(message=message, intent=delivery, receipt=prepared), ensure_ascii=False))
            # Deliberately lose the dispatch reply, then use only the saved
            # ticket. Never Prepare a replacement effect.
            send_only(notification(1, prepared["ticket"]))
            time.sleep(0.25)
            for _ in range(30):
                delivered = receipt(notification(2, prepared["ticket"]))
                if delivered["status"] == 1:
                    break
                if delivered["status"] != 0:
                    raise RuntimeError("delivery requires explicit recovery")
                receipt(notification(1, prepared["ticket"]))
                time.sleep(0.2)
            if delivered["status"] != 1 or delivered["esc"] or not delivered["enter"] or delivered["written"] != len(message.encode()):
                raise RuntimeError("literal delivery did not finish exactly")
            duplicate = receipt(notification(1, prepared["ticket"]))
            if duplicate != delivered:
                raise RuntimeError("same-ticket duplicate changed receipt")
            deadline = time.monotonic() + 30
            matching = []
            transcript_path = None
            while time.monotonic() < deadline:
                candidates = []
                if args.provider == "claude":
                    candidates = list((Path.home() / ".claude/projects").glob("*/" + session_id + ".jsonl"))
                else:
                    # Inspect only fresh session metadata; read bodies only for
                    # the exact fixture cwd, never unrelated conversations.
                    for candidate in (Path.home() / ".codex/sessions").rglob("*.jsonl"):
                        if candidate.stat().st_mtime < root.stat().st_ctime - 2:
                            continue
                        with candidate.open() as stream:
                            first = stream.readline()
                        if str(root) in first:
                            candidates.append(candidate)
                matching = []
                for candidate in candidates:
                    events, responses = [], []
                    for line in candidate.read_text().splitlines():
                        try:
                            row = json.loads(line)
                        except ValueError:
                            continue
                        if args.provider == "codex":
                            payload = row.get("payload", {})
                            if row.get("type") == "event_msg" and payload.get("type") == "user_message":
                                events.append(payload.get("message", ""))
                            if row.get("type") == "response_item" and payload.get("role") == "user":
                                responses.append("".join(c.get("text", "") for c in payload.get("content", [])))
                        elif row.get("type") == "user":
                            body = row.get("message", {}).get("content", "")
                            events.append(body if isinstance(body, str) else "".join(c.get("text", "") for c in body))
                    matching += [value for value in (events or responses) if marker in value]
                    if matching:
                        transcript_path = str(candidate)
                if matching:
                    break
                time.sleep(0.5)
            if matching != [message]:
                raise RuntimeError("native transcript does not prove exactly one byte-exact literal submission: count=" + str(len(matching)))
            literal_evidence = dict(status="literal_exact_transcript_and_same_ticket_replay_pass", receipt=delivered,
                                    transcript=transcript_path, message_bytes=len(message.encode()), submissions=len(matching))
            lines = screen()

            if args.native_interrupt:
                # This probe observes its exact fresh fixture session. Production
                # supplies the observation through authenticated SessionStart.
                native_path=Path(transcript_path)
                first=json.loads(native_path.open().readline())["payload"]
                if args.native_hook:
                    proof_path=root/"native-hook-proof.jsonl"
                    proofs=[json.loads(line) for line in proof_path.read_text().splitlines()] if proof_path.exists() else []
                    if not any(proof.get("event")=="SessionStart" and proof.get("session")==first["id"] and proof.get("accepted") for proof in proofs):
                        raise RuntimeError("actual native SessionStart callback did not bind; direct observation bypass forbidden")
                else:
                    bound=Reader(exchange(b"\x42"+text(instance)+struct.pack(">i",pid)+
                                         b"".join(text(v) for v in (run_id,"probe_epoch","1",first["id"],str(native_path),"startup"))))
                    if bound.take(1)!=b"\xb4" or bound.string()!=instance:
                        raise RuntimeError("native session/profile binding refused; no interrupt capability pass")
                native_before=native_path.read_bytes()
                boundary=native_before.rfind(b"\n")+1
                delivery += "_native"
                operation += "_native"
                native_marker="native_interrupt_"+run_id
                message="Do not use tools. Reply OK only.\n"+native_marker+"\n\t€ 日本語 😀"
                interrupt=True
                native_prepared=receipt(notification(0))
                if not native_prepared["profile"].startswith("codex-native-session-v1:"):
                    raise RuntimeError("native profile not bound to prepared ticket")
                (root/"native-intent.json").write_text(json.dumps(dict(message=message,receipt=native_prepared),ensure_ascii=False))
                send_only(notification(1,native_prepared["ticket"]))
                deadline=time.monotonic()+12
                native_result=None
                while time.monotonic()<deadline:
                    time.sleep(0.1)
                    native_result=receipt(notification(2,native_prepared["ticket"]))
                    if native_result["status"]!=0:
                        break
                    native_result=receipt(notification(1,native_prepared["ticket"]))
                    if native_result["status"]!=0:
                        break
                if native_result["status"]!=1 or not native_result["esc"] or not native_result["enter"] or native_result["written"]!=len(message.encode()):
                    raise RuntimeError("native interrupt delivery did not complete under acknowledgment gate: "+str(native_result))
                if receipt(notification(1,native_prepared["ticket"]))!=native_result:
                    raise RuntimeError("native duplicate changed exact receipt")
                deadline=time.monotonic()+20
                native_matches=[]
                while time.monotonic()<deadline:
                    native_events=[];native_responses=[]
                    for line in native_path.read_text().splitlines():
                        row=json.loads(line);body=row.get("payload",{})
                        if row.get("type")=="event_msg" and body.get("type")=="user_message" and native_marker in body.get("message",""):
                            native_events.append(body["message"])
                        if row.get("type")=="response_item" and body.get("role")=="user":
                            value="".join(c.get("text","") for c in body.get("content",[]))
                            if native_marker in value: native_responses.append(value)
                    native_matches=native_events or native_responses
                    if native_matches:
                        break
                    time.sleep(0.2)
                if native_matches!=[message]:
                    raise RuntimeError("native interrupt exact transcript mismatch/count="+str(len(native_matches)))
                tail=native_path.read_bytes()[boundary:].decode()
                aborts=[row for row in map(json.loads,tail.splitlines()) if row.get("type")=="event_msg" and row.get("payload",{}).get("type")=="turn_aborted" and row["payload"].get("reason")=="interrupted"]
                if not aborts:
                    raise RuntimeError("no fresh typed native abort evidence")
                native_evidence=dict(status="native_daemon_interrupt_ack_literal_same_ticket_pass",receipt=native_result,session=first["id"],
                                     cli_version=version,state_version=first["cli_version"],submissions=1,typed_aborts=len(aborts),native_hook=args.native_hook)
                lines=screen()

            if args.escape_observe:
                def plain_view(lines):
                    return re.sub(r"(?:\x1b|\\u001b)\[[0-9;]*[A-Za-z]", "", "\n".join(lines))
                busy = plain_view(lines)
                if "esc to interrupt" not in busy.lower() and "esc to cancel" not in busy.lower():
                    raise RuntimeError("native generating/busy state not observed; no interrupt evidence")
                before_escape = time.monotonic()
                send_only(b"\x31" + text(instance) + b"\x1b")
                while time.monotonic() - before_escape < 8:
                    time.sleep(0.1)
                    lines = screen()
                    view = plain_view(lines)
                    if "interrupted" in view.lower():
                        escape_evidence = dict(status="native_raw_escape_observed_not_notification_profile",
                                               elapsed_ms=round((time.monotonic() - before_escape) * 1000),
                                               busy_screen=busy, interrupted_screen=view)
                        break
                if escape_evidence is None:
                    raise RuntimeError("native interruption acknowledgment was not observed")
                # After an observed native acknowledgment, prove the next
                # literal notice is consumed exactly once. This deliberately
                # does not convert one observed latency into a daemon profile.
                delivery += "_post"
                operation += "_post"
                post_marker = "post_interrupt_" + run_id
                message = "Do not use tools. Reply OK only.\n" + post_marker + "\n\t€ 日本語 😀"
                post_prepared = receipt(notification(0))
                (root / "post-intent.json").write_text(json.dumps(dict(message=message, intent=delivery, receipt=post_prepared), ensure_ascii=False))
                send_only(notification(1, post_prepared["ticket"]))
                time.sleep(0.2)
                post = receipt(notification(2, post_prepared["ticket"]))
                if post["status"] != 1 or post["written"] != len(message.encode()) or not post["enter"]:
                    raise RuntimeError("post-interruption literal delivery incomplete")
                if receipt(notification(1, post_prepared["ticket"])) != post:
                    raise RuntimeError("post-interruption ticket replay changed result")
                deadline = time.monotonic() + 10
                post_submissions = []
                while time.monotonic() < deadline:
                    events, responses = [], []
                    for line in Path(transcript_path).read_text().splitlines():
                        try:
                            row = json.loads(line)
                        except ValueError:
                            continue
                        payload = row.get("payload", {})
                        if args.provider == "codex":
                            if row.get("type") == "event_msg" and payload.get("type") == "user_message":
                                events.append(payload.get("message", ""))
                            if row.get("type") == "response_item" and payload.get("role") == "user":
                                responses.append("".join(c.get("text", "") for c in payload.get("content", [])))
                        elif row.get("type") == "user":
                            body = row.get("message", {}).get("content", "")
                            events.append(body if isinstance(body, str) else "".join(c.get("text", "") for c in body))
                    post_submissions = [value for value in (events or responses) if post_marker in value]
                    if post_submissions:
                        break
                    time.sleep(0.2)
                if post_submissions != [message]:
                    raise RuntimeError("post-interruption native literal submission is not exact and unique")
                escape_evidence["post_interrupt_literal"] = dict(receipt=post, message_bytes=len(message.encode()), submissions=1)
        result = {"provider": args.provider, "version": version, "model": args.model,
                  "executable": cli, "pid": pid, "workdir": str(root),
                  "status": ("native_daemon_interrupt_ack_literal_same_ticket_pass" if native_evidence else ("native_literal_pass_interrupt_profile_unverified" if literal_evidence else "observation_only")),
                  "literal": literal_evidence, "raw_escape": escape_evidence, "native_interrupt": native_evidence, "screen": lines}
        (root / "observation.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
        summary = {k: v for k, v in result.items() if k != "screen"}
        if summary.get("raw_escape"):
            summary["raw_escape"] = {k: v for k, v in summary["raw_escape"].items() if not k.endswith("_screen")}
        summary["evidence"] = str(root / "observation.json")
        print(json.dumps(summary, ensure_ascii=False))
    except Exception as error:
        failure = dict(provider=args.provider, version=version, model=args.model, workdir=str(root), error=str(error))
        try:
            failure["screen"] = screen()
        except (OSError, RuntimeError, UnboundLocalError):
            pass
        (root / "failure.json").write_text(json.dumps(failure, ensure_ascii=False, indent=2) + "\n")
        print(json.dumps({"failure_evidence": str(root / "failure.json"), "error": str(error)}))
        raise
    finally:
        try:
            exchange(b"\x21" + text(instance))
        except (OSError, RuntimeError):
            pass
        daemon.terminate()
        try:
            daemon.wait(timeout=10)
        except subprocess.TimeoutExpired:
            daemon.kill()
            daemon.wait(timeout=5)
        Path(address).unlink(missing_ok=True)


if __name__ == "__main__":
    main()
