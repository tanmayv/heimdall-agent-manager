#!/usr/bin/env python3
"""Task 16 acceptance check: merge lifecycle on chain completion.

Runs an isolated ham-daemon on a temp data_dir + non-default port and asserts:

  Non-VCS chain (docs/teams-v1/03-lifecycle.md §3.4):
    - complete chain -> team archives immediately.

  VCS chain (§3.5), simulated by inserting a vcs_workspaces row:
    - complete chain -> team stays bootable (not archived) and a
      Merge_Decision_Pending item shows up in GET /attention.
    - operator abandon (workspace/archive) -> team archives, item gone.

No frameworks; assert-based. Safe: temp data_dir, never touches the live DB.
"""
import json
import os
import shutil
import sqlite3
import subprocess
import tempfile
import time
import urllib.request
from pathlib import Path

HOST = "127.0.0.1"
PORT = 49570
URL = f"http://{HOST}:{PORT}"
ROOT = Path(__file__).resolve().parent.parent


def post(path, body):
    data = json.dumps(body).encode()
    req = urllib.request.Request(URL + path, data=data, headers={"Content-Type": "application/json"})
    return json.loads(urllib.request.urlopen(req, timeout=10).read().decode())


def get(path):
    return json.loads(urllib.request.urlopen(URL + path, timeout=10).read().decode())


def register(agent_instance_id):
    return post("/register", {"protocol_version": 1, "agent_class": agent_instance_id.split("@")[0],
                              "agent_instance_id": agent_instance_id, "display_name": agent_instance_id})


def team_status(chain_id, teams_db):
    con = sqlite3.connect(teams_db)
    row = con.execute("SELECT status FROM teams WHERE chain_id=?", (chain_id,)).fetchone()
    con.close()
    return row[0] if row else None


def main():
    tmp = tempfile.mkdtemp(prefix="heimdall-merge-lifecycle-")
    data = os.path.join(tmp, "data")
    os.makedirs(data, exist_ok=True)
    cfg = os.path.join(tmp, "config.toml")
    Path(cfg).write_text(
        f'[ctl]\ndaemon_url = "{URL}"\n[daemon]\nbind_host = "{HOST}"\nport = {PORT}\n'
        f'data_dir = "{data}"\nwrapper_bin = "{ROOT}/result-1/bin/ham-wrapper"\nnudge_enabled = false\n'
        f'[wrapper]\ndaemon_url = "{URL}"\nham_ctl_bin = "{ROOT}/result-2/bin/ham-ctl"\ncommand = ["pi"]\n'
    )
    daemon = subprocess.Popen([str(ROOT / "result/bin/ham-daemon"), "--config", cfg],
                              stdout=open(os.path.join(tmp, "daemon.log"), "w"), stderr=subprocess.STDOUT)
    try:
        for _ in range(60):
            try:
                if get("/health")["ok"]:
                    break
            except Exception:
                time.sleep(0.5)
        token = register("seed@merge")["agent_token"]
        # Operator (user) token for VCS write ops which require a user identity.
        user_token = post("/user-client/register", {"user_id": "operator@local",
                                                    "client_instance_id": "merge-test"})["client_token"]
        post("/projects/create", {"agent_token": token, "project_id": "mproj", "name": "M", "description": "d"})

        # --- Non-VCS chain: archives immediately on completion (§3.4) ---
        ch = post("/task-chains/create", {"agent_token": token, "project_id": "mproj", "kind": "coding",
                                          "title": "NoVCS Chain", "status": "planning",
                                          "coordinator_agent_instance_id": "seed@merge"})
        chain_a = ch["chain_id"]
        teams_db = os.path.join(data, "teams", "teams.db")
        assert team_status(chain_a, teams_db) not in ("archived", None), "team should exist pre-completion"
        post("/task-chains/status", {"agent_token": token, "chain_id": chain_a,
                                     "status": "completed", "final_summary": "done"})
        assert team_status(chain_a, teams_db) == "archived", \
            f"non-VCS chain team must archive immediately, got {team_status(chain_a, teams_db)}"

        # --- VCS chain: merge decision pending, no immediate archive (§3.5) ---
        ch2 = post("/task-chains/create", {"agent_token": token, "project_id": "mproj", "kind": "coding",
                                           "title": "VCS Chain", "status": "planning",
                                           "coordinator_agent_instance_id": "seed@merge"})
        chain_b = ch2["chain_id"]
        # Simulate a provisioned workspace directly (no real git repo needed for lifecycle).
        vcs_db = os.path.join(data, "vcs", "vcs.db")
        con = sqlite3.connect(vcs_db)
        con.execute(
            "INSERT OR REPLACE INTO vcs_workspaces (workspace_id,chain_id,project_id,vcs_kind,path,"
            "branch_or_change,base_ref,status,keep_on_archive,created_unix_ms,updated_unix_ms) "
            "VALUES (?,?,?,?,?,?,?,?,0,0,0)",
            (f"ws_{chain_b}", chain_b, "mproj", "git", os.path.join(tmp, "ws"),
             f"team/{chain_b}/vcs-chain", "main", "clean"),
        )
        con.commit()
        con.close()

        post("/task-chains/status", {"agent_token": token, "chain_id": chain_b,
                                     "status": "completed", "final_summary": "done"})
        assert team_status(chain_b, teams_db) != "archived", \
            "VCS chain team must stay bootable until merge decision"

        att = get(f"/attention?agent_token={token}")
        assert att["ok"], att
        pending = [m for m in att["merge_decisions"] if m["chain_id"] == chain_b]
        assert len(pending) == 1, f"expected merge decision for {chain_b}, got {att['merge_decisions']}"
        assert pending[0]["branch_or_change"] == f"team/{chain_b}/vcs-chain"

        # Operator abandon (workspace/archive) finalizes the decision -> team archives.
        post(f"/chains/{chain_b}/workspace/archive", {"agent_token": user_token, "force": True})
        assert team_status(chain_b, teams_db) == "archived", "team must archive after merge decision"
        att2 = get(f"/attention?agent_token={token}")
        assert not [m for m in att2["merge_decisions"] if m["chain_id"] == chain_b], \
            "merge decision must clear after operator decision"

        # --- VCS keep-worktree markers (VCS-5) for git + jj archive decisions ---
        for kind in ("git", "jj"):
            ch_keep = post("/task-chains/create", {"agent_token": token, "project_id": "mproj", "kind": "coding",
                                                   "title": f"Keep {kind}", "status": "planning",
                                                   "coordinator_agent_instance_id": "seed@merge"})
            chain_keep = ch_keep["chain_id"]
            keep_path = os.path.join(tmp, f"kept-{kind}")
            os.makedirs(keep_path, exist_ok=True)
            con = sqlite3.connect(vcs_db)
            con.execute(
                "INSERT OR REPLACE INTO vcs_workspaces (workspace_id,chain_id,project_id,vcs_kind,path,"
                "branch_or_change,base_ref,status,keep_on_archive,created_unix_ms,updated_unix_ms) "
                "VALUES (?,?,?,?,?,?,?,?,0,0,0)",
                (f"ws_{kind}_{chain_keep}", chain_keep, "mproj", kind, keep_path,
                 f"team/{chain_keep}/keep-{kind}", "main" if kind == "git" else "trunk()", "clean"),
            )
            con.commit(); con.close()
            post("/task-chains/status", {"agent_token": token, "chain_id": chain_keep,
                                         "status": "completed", "final_summary": "done"})
            keep_res = post(f"/chains/{chain_keep}/workspace/archive", {"agent_token": user_token, "keep": True})
            assert keep_res["ok"], keep_res
            marker = os.path.join(keep_path, ".heimdall-kept")
            assert os.path.exists(marker), f"{kind} keep marker missing at {marker}"
            marker_text = Path(marker).read_text()
            assert f"chain_id={chain_keep}" in marker_text, marker_text
            assert f"workspace_id=ws_{kind}_{chain_keep}" in marker_text, marker_text
            assert f"vcs_kind={kind}" in marker_text, marker_text
            assert "reason=operator keep-worktree archive decision" in marker_text, marker_text
            con = sqlite3.connect(vcs_db)
            keep_status = con.execute("SELECT status FROM vcs_workspaces WHERE chain_id=?", (chain_keep,)).fetchone()[0]
            con.close()
            assert keep_status == "kept", f"kept workspace status must be kept, got {keep_status}"
            assert team_status(chain_keep, teams_db) == "archived", "team must archive after keep decision"

        # --- VCS merge happy path against a REAL git repo ---
        repo = os.path.join(tmp, "repo")
        os.makedirs(repo)
        def git(*a):
            subprocess.run(["git", "-C", repo, *a], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        git("init", "-b", "main")
        git("config", "user.email", "t@t")
        git("config", "user.name", "t")
        Path(repo, "a.txt").write_text("base\n")
        git("add", "."); git("commit", "-m", "base")
        # A real linked worktree on a feature branch with one commit.
        wt = os.path.join(tmp, "wt")
        branch = "team/mergeok/feat"
        subprocess.run(["git", "-C", repo, "worktree", "add", wt, "-b", branch, "main"],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["git", "-C", wt, "config", "user.email", "t@t"], check=True)
        subprocess.run(["git", "-C", wt, "config", "user.name", "t"], check=True)
        Path(wt, "b.txt").write_text("feature\n")
        subprocess.run(["git", "-C", wt, "add", "."], check=True)
        subprocess.run(["git", "-C", wt, "commit", "-m", "feature"], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        ch3 = post("/task-chains/create", {"agent_token": token, "project_id": "mproj", "kind": "coding",
                                           "title": "Merge OK", "status": "planning",
                                           "coordinator_agent_instance_id": "seed@merge"})
        chain_c = ch3["chain_id"]
        con = sqlite3.connect(vcs_db)
        con.execute(
            "INSERT OR REPLACE INTO vcs_workspaces (workspace_id,chain_id,project_id,vcs_kind,path,"
            "branch_or_change,base_ref,status,keep_on_archive,created_unix_ms,updated_unix_ms) "
            "VALUES (?,?,?,?,?,?,?,?,0,0,0)",
            (f"ws_{chain_c}", chain_c, "mproj", "git", wt, branch, "main", "clean"),
        )
        con.commit(); con.close()

        post("/task-chains/status", {"agent_token": token, "chain_id": chain_c,
                                     "status": "completed", "final_summary": "done"})
        assert team_status(chain_c, teams_db) != "archived", "team must stay until merge"
        # Operator clicks merge.
        res = post(f"/chains/{chain_c}/workspace/merge", {"agent_token": user_token})
        assert res["ok"], res
        # Feature commit is now on main.
        log = subprocess.run(["git", "-C", repo, "log", "main", "--oneline"],
                             capture_output=True, text=True).stdout
        assert "feature" in log, f"merge did not land feature commit on main: {log}"
        # Worktree removed, status merged, team archived, attention cleared.
        assert not os.path.exists(os.path.join(wt, "b.txt")), "worktree should be removed after merge"
        con = sqlite3.connect(vcs_db)
        st = con.execute("SELECT status FROM vcs_workspaces WHERE chain_id=?", (chain_c,)).fetchone()[0]
        con.close()
        assert st == "merged", f"workspace status must be merged, got {st}"
        assert team_status(chain_c, teams_db) == "archived", "team must archive after merge"
        att3 = get(f"/attention?agent_token={token}")
        assert not [m for m in att3["merge_decisions"] if m["chain_id"] == chain_c], \
            "merge decision must clear after successful merge"

        print("PASS: merge lifecycle §3.4 (immediate archive), §3.5 (merge decision, VCS-5 keep markers, real merge happy path, abandon finalize)")
    finally:
        daemon.terminate()
        try:
            daemon.wait(timeout=5)
        except Exception:
            daemon.kill()
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
