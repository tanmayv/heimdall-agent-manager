---
name: heimdall-prod-deploy
description: >
  Step-by-step runbook for deploying heimdall-agent-manager to the production VPS
  (heimdall.mundus.in). Use whenever you are asked to ship a rev to prod — committing
  + pushing new code, pinning the flake input, building on dawnstar, switching the VPS,
  and verifying the deploy. NOT for dawnstar-only switches (use
  dawnstar-bridge-crash-safe-nixos-rebuild-switch for those).
type: core
---

# Heimdall Production Deploy (VPS)

## When to use this skill

- You are asked to deploy / ship / release the current changes to production.
- You need to pin a specific commit of `heimdall-agent-manager` on the VPS.
- You are verifying what is currently running in production.
- You are rolling back a bad deploy.

## Key facts

| Thing | Value |
|---|---|
| All commands run on | **dawnstar** |
| Prod flake input name | `heimdall-agent-manager` (NOT `heimdall-agent-manager-qa`) |
| Flake file | `~/nix-homelab-config/flake.nix` |
| VPS SSH | `root@vps` (key auth; `ssh root@vps` is root — needed for `systemctl restart`) |
| Hub service | `heimdall-hub-prod.service` → port `8113` |
| Web service | `heimdall-hub-prod-web.service` → port `8114` (Caddy) |
| Public UI | `https://heimdall.mundus.in` |
| Public API | `https://hub.mundus.in` |
| Database | `/var/lib/heimdall-hub-prod/hub.sqlite` on VPS |

> **The VPS has no `sqlite3`, `python3`, `strings`, or `openssl`.** Copy files back to
> dawnstar to inspect them.

---

## Step 1 — Commit and push (if local changes are uncommitted)

```bash
cd ~/heimdall-agent-manager
git status --short           # confirm which files changed
git diff --stat HEAD         # review the diff
git add <files>
git commit -m "<imperative summary of changes>"
git push origin main
```

Capture the pushed commit hash — this is your `<REV>`:

```bash
git rev-parse HEAD
```

---

## Step 2 — Find the live production baseline (rollback anchor)

```bash
# Running hub store path (resolve to commit in Step 3 if needed)
ssh root@vps 'systemctl show heimdall-hub-prod -p ExecStart --value | grep -o "/nix/store/[^/]*-ham-hub-[^/]*" | head -1'

# Current generation number — write this down for rollback
ssh root@vps 'nix-env --list-generations -p /nix/var/nix/profiles/system | tail -3'
```

To find which commit the running store path corresponds to:

```bash
cd ~/heimdall-agent-manager && git fetch origin -q
RUNNING_HASH="<hash-from-above>"
for r in $(git log --format=%h -15 origin/main); do
  p=$(nix build "github:tanmayv/heimdall-agent-manager/$r#ham-hub" --no-link --print-out-paths 2>/dev/null)
  case "$p" in *${RUNNING_HASH}*) echo "live = $r";; esac
done
```

---

## Step 3 — Know what you are shipping

```bash
cd ~/heimdall-agent-manager
LIVE_REV=<commit from Step 2>
REV=<commit you are shipping>

git log --oneline ${LIVE_REV}..${REV}                                           # commits going out
git diff --name-status ${LIVE_REV}..${REV} -- src/hub/repository/sqlite/migrations/  # new migrations?
git diff --stat      ${LIVE_REV}..${REV} -- src/bridge/                         # bridge protocol changes?
```

- **New migrations?** → Do Step 4 (migration dry-run). Never skip it.
- **`src/bridge` changed?** → Read the diff. The prod bridge runs on dawnstar and is only
  updated when *dawnstar* is switched. Additive changes (new optional fields, new routes)
  are safe. Removed or renamed fields are not.
- **Prefer a QA-tested rev.** Check QA: `systemctl show heimdall-hub-qa -p ExecStart` on
  dawnstar. Ship past QA only intentionally and say so in the commit message.

---

## Step 4 — Snapshot DB and dry-run migrations on a prod copy

**Skip this step only if `git diff` confirmed zero new migration files.**

```bash
REV=<your rev>
S=/tmp/deploy-scratch-${REV}
mkdir -p $S

# 1. Snapshot on the VPS (your restore point)
ssh root@vps "cp -a /var/lib/heimdall-hub-prod/hub.sqlite /var/lib/heimdall-hub-prod/hub.sqlite.pre-${REV}"

# 2. Pull a copy to dawnstar
ssh root@vps 'cat /var/lib/heimdall-hub-prod/hub.sqlite' > $S/prod.sqlite

# 3. Build the new hub and dev-proxy
H=$(nix build "github:tanmayv/heimdall-agent-manager/${REV}#ham-hub"       --no-link --print-out-paths)
DP=$(nix build "github:tanmayv/heimdall-agent-manager/${REV}#ham-dev-proxy" --no-link --print-out-paths)

# 4. Run new hub against the prod copy
HEIMDALL_HOME=$S $H/bin/ham-hub \
  --migrations-dir $H/share/ham-hub/migrations \
  --listen 127.0.0.1:19311 --db $S/prod.sqlite \
  --trusted-proxy-cidr 127.0.0.1/32 &
HUB_PID=$!
HEIMDALL_HOME=$S $DP/bin/ham-dev-proxy \
  --listen 127.0.0.1:19310 --hub-url http://127.0.0.1:19311 \
  --default-user tanmay &
PROXY_PID=$!
sleep 3

# 5. Exercise it
for p in /api/v1/health /api/v1/me /api/v1/task-chains "/api/v1/search?q=deploy"; do
  curl -s -o /dev/null -w "%{http_code} %{time_total}s  $p\n" --max-time 60 "http://127.0.0.1:19310$p"
done

# 6. Stop the test processes
kill $HUB_PID $PROXY_PID 2>/dev/null
```

Confirm: hub starts, all endpoints return in milliseconds (not 116 s), `pragma
integrity_check` is `ok`, new migration appears in `schema_migrations`.

---

## Step 5 — Pin only the prod flake input

```bash
cd ~/nix-homelab-config
REV=<your rev>

nix flake lock --override-input heimdall-agent-manager "github:tanmayv/heimdall-agent-manager/${REV}"

# Verify: prod pin changed, QA pin unchanged
python3 -c "
import json
l = json.load(open('flake.lock'))['nodes']
for k in ['heimdall-agent-manager', 'heimdall-agent-manager-qa']:
    print(k, l[k]['locked']['rev'])
"
```

If `--override-input` accidentally moved the QA pin, put it back:

```bash
nix flake lock --override-input heimdall-agent-manager-qa "github:tanmayv/heimdall-agent-manager/<OLD-QA-REV>"
```

---

## Step 6 — Build on dawnstar

```bash
cd ~/nix-homelab-config
nixos-rebuild build --flake .#vps                  # must exit 0
nix-store -qR result | grep ham-hub-0              # confirm this is the rev you dry-ran
```

---

## Step 7 — Switch the VPS

> **Do NOT use `switch-vps` or `--build-host vps`.** Building on the VPS has taken the
> box down. Always build on dawnstar and push the closure.

```bash
cd ~/nix-homelab-config
nixos-rebuild switch --flake .#vps --target-host root@vps
```

Expect a few seconds of 502 while `heimdall-hub-prod` and `heimdall-hub-prod-web`
restart. The switch does not touch nginx or Authentik.

---

## Step 8 — Verify (all checks required)

```bash
ssh root@vps '
  nix-env --list-generations -p /nix/var/nix/profiles/system | tail -2
  systemctl is-active heimdall-hub-prod heimdall-hub-prod-web nginx podman-authentik-server
  journalctl -u heimdall-hub-prod --since "-3min" --no-pager | grep -iE "FTS|migrat|listening|error" | tail
  curl -fsS -o /dev/null -w "api %{http_code} %{time_total}s\n" --max-time 15 http://127.0.0.1:8113/api/v1/health
  curl -fsS -o /dev/null -w "web %{http_code} %{time_total}s\n" --max-time 15 http://127.0.0.1:8114/api/v1/health
  curl -s    -o /dev/null -w "me  %{http_code} %{time_total}s\n" --max-time 15 http://127.0.0.1:8114/api/v1/me
  cat /sys/fs/cgroup/system.slice/heimdall-hub-prod.service/memory.swap.max'
for u in https://heimdall.mundus.in/ https://hub.mundus.in/api/v1/health https://auth.mundus.in/; do
  printf '%-40s %s\n' "$u" "$(curl -sk -o /dev/null -w '%{http_code}' --max-time 45 "$u")"
done
journalctl --user -u heimdall-bridge --since "-5min" --no-pager | grep -i "runtime ready" | tail -1
```

**Expected healthy state:**
- New generation number on the VPS.
- All units `active`.
- API health `200` in milliseconds; `/me` returns `401` (no session).
- `memory.swap.max` = `0`.
- Public endpoints: `heimdall.mundus.in` → `302`, `hub.mundus.in/api/v1/health` → `200`,
  `auth.mundus.in` → `302`.
- Bridge log: `bridge hub runtime ready` within ~1 min of the restart.

**Prove hub AND UI are the rev you meant to ship:**

```bash
REV=<your rev>
nix build "github:tanmayv/heimdall-agent-manager/${REV}#ham-hub"    --no-link --print-out-paths
nix build "github:tanmayv/heimdall-agent-manager/${REV}#heimdall"   --no-link --print-out-paths
ssh root@vps '
  systemctl show heimdall-hub-prod -p ExecStart --value | grep -o "/nix/store/[^/]*-ham-hub-[^/]*" | head -1
  CF=$(systemctl show heimdall-hub-prod-web -p ExecStart --value | grep -o "/nix/store/[^ ]*caddyfile" | head -1)
  grep -o "/nix/store/[^/]*-heimdall-[^/]*" "$CF" | sort -u'
```

Both local build paths must match the paths reported by the running VPS units.

---

## Step 9 — Commit the lock file

```bash
cd ~/nix-homelab-config
git add flake.lock
git commit -m "flake.lock: bump heimdall PROD input to <REV> (<one-line summary>)"
```

Note in the commit message which commits were QA-tested and which were not.

---

## Rollback

Use the generation number from Step 2:

```bash
ssh root@vps "nix-env --switch-generation <N> -p /nix/var/nix/profiles/system && \
              /nix/var/nix/profiles/system/bin/switch-to-configuration switch"
```

**Migrations do not roll back.** If the old binary misbehaves on the migrated DB,
restore the snapshot from Step 4:

```bash
ssh root@vps 'systemctl stop heimdall-hub-prod && \
  cp -a /var/lib/heimdall-hub-prod/hub.sqlite.pre-<REV> /var/lib/heimdall-hub-prod/hub.sqlite && \
  systemctl start heimdall-hub-prod heimdall-hub-prod-web'
```

> Always restart **both** units together. `heimdall-hub-prod-web` (Caddy on `:8114`)
> binds to the hub — stopping the hub also stops the web front, but starting the hub
> alone does NOT bring the web front back, leaving the public site returning `502`.
> Always: `systemctl start heimdall-hub-prod heimdall-hub-prod-web`.

---

## Diagnosing a wedged hub (unit active but not serving)

`systemctl is-active` only tells you the process exists. The hub can be wedged:
unit `active`, `NRestarts=0`, answering nothing. Always check with a real request:

```bash
ssh root@vps 'curl -fsS -o /dev/null -w "%{http_code} %{time_total}s\n" --max-time 10 http://127.0.0.1:8113/api/v1/health'
```

`200` in milliseconds = healthy. Timeout with unit `active` = wedged. Diagnose before
restarting (a restart destroys evidence):

```bash
ssh root@vps '
  ss -ltn | grep -E "8113|8114"
  ps -o pid,etime,rss,stat,nlwp -C .ham-hub-wrapped
  grep VmSwap /proc/$(pgrep -f .ham-hub-wrapped | head -1)/status
  free -m; uptime
  journalctl -u heimdall-hub-prod --since "-3h" --no-pager | grep -v "ham-push DEBUG" | tail -20'
```

Fix: `ssh root@vps 'systemctl restart heimdall-hub-prod heimdall-hub-prod-web'`

Memory guard rails in `ai-managed-module.nix` (confirm still in place):
- `MemoryHigh=512M` / `MemoryMax=768M`
- `MemorySwapMax=0` — **critical**: without this, cgroup v2 swaps the hub out instead
  of OOM-killing it, which takes down the whole machine while systemd reports it healthy.

```bash
ssh root@vps 'cat /sys/fs/cgroup/system.slice/heimdall-hub-prod.service/memory.swap.max \
                  /sys/fs/cgroup/system.slice/heimdall-hub-prod.service/memory.max'
# expect: 0  and  805306368
```
