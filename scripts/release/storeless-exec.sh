#!/usr/bin/env bash
# REQ-INST-25 / REQ-INST-16: execute a release binary in an environment that
# has no /nix/store and no dynamic loader, to prove it needs neither.
#
# This is the SINGLE implementation of that mechanism. The release workflow and
# tests/test_binary_distribution.py both call it. They used to carry separate
# copies of the same `docker run ... scratch` invocation, and when that
# invocation turned out to be unrunnable ('scratch' is a Docker reserved name,
# valid only as `FROM scratch`) the bug had to be present in both -- and the
# copy inside the negative control silently turned that control into a no-op.
# One implementation cannot diverge from itself.
#
# The mechanism is chosen by EXECUTION, never by availability:
#   * a candidate must run a known-good fully static control to exit code 42
#   * and must FAIL to run a dynamically linked control
# A candidate that cannot do both is not used. If no candidate can do both, we
# exit non-zero. We never skip: a storeless check that quietly does nothing is
# exactly the failure this script exists to prevent.
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: storeless-exec.sh select
       storeless-exec.sh run <binary> [args...]
       storeless-exec.sh write-control <path>

select  Choose and validate a storeless-execution mechanism, print its id on
        stdout (docker-empty-image | unshare-chroot), and exit 0. Exit 1 if no
        mechanism can be validated.
run     Validate a mechanism as above, then execute <binary> with [args...]
        inside the clean environment. Stdout, stderr and the exit code are the
        binary's own.

write-control
        Write the known-good static control binary for this architecture to
        <path> and exit 0. Callers that need the control (the test suite's
        teeth check) take it from here rather than carrying a second copy.

Exit codes for `run`: the binary's own status, except 70 when no mechanism
could be validated. Call `select` first if you need that distinction to be
unambiguous. The static control exits 42.
USAGE
}

NO_MECHANISM=70
CONTROL_RC=42

# A 132-byte freestanding ELF whose entire program is exit(42). It is the
# positive control: fully static, no PT_INTERP, no libc, no syscall beyond
# exit, so nothing but real execution inside the clean rootfs can produce 42.
# A harness that refuses the command yields its own status (Docker uses 125 for
# a bad invocation, 126/127 for exec failures), never 42, which is the
# distinction the old `rc != 0` assertion could not make.
control_b64_x86_64='f0VMRgIBAQAAAAAAAAAAAAIAPgABAAAAeABAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAEAAOAABAEAAAAAAAAEAAAAFAAAAAAAAAAAAAAAAAEAAAAAAAAAAQAAAAAAAhAAAAAAAAACEAAAAAAAAAAAQAAAAAAAAvyoAAAC4PAAAAA8F'
control_b64_aarch64='f0VMRgIBAQAAAAAAAAAAAAIAtwABAAAAeABAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAEAAOAABAEAAAAAAAAEAAAAFAAAAAAAAAAAAAAAAAEAAAAAAAAAAQAAAAAAAhAAAAAAAAACEAAAAAAAAAAAQAAAAAAAAQAWA0qgLgNIBAADU'

log() { printf 'storeless-exec: %s\n' "$*" >&2; }

# Writes the static control for this machine to $1. Fails if the host
# architecture has no control blob -- better to stop than to validate nothing.
write_static_control() {
  local dest="$1" b64
  case "$(uname -m)" in
    x86_64|amd64) b64="$control_b64_x86_64" ;;
    aarch64|arm64) b64="$control_b64_aarch64" ;;
    *) log "FAIL: no static control binary for machine $(uname -m)"; return 1 ;;
  esac
  printf '%s' "$b64" | base64 -d > "$dest"
  chmod +x "$dest"
}

# A dynamically linked binary whose loader is absent from the clean rootfs. Its
# failure is what proves the environment really is bare.
find_dynamic_control() {
  local c
  for c in /bin/sh /bin/ls /usr/bin/env; do
    [ -x "$c" ] || continue
    if readelf -l "$c" 2>/dev/null | grep -q 'Requesting program interpreter'; then
      printf '%s' "$c"
      return 0
    fi
  done
  return 1
}

# ---- candidate mechanisms -----------------------------------------------------
# Each takes a rootfs directory and an in-rootfs command, and runs it with the
# host filesystem (and so /nix/store) invisible.

docker_image=''

docker_available() {
  command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

# `scratch` is NOT usable here: Docker reserves the name and rejects it at the
# daemon with exit 125, so it never executes anything. An empty image has to be
# created, which `docker import` of an empty tar does in one step.
docker_prepare() {
  local tmp="$1" empty="$1/empty.tar"
  tar -cf "$empty" --files-from /dev/null
  docker_image="$(docker import "$empty" 2>/dev/null)" || return 1
  [ -n "$docker_image" ]
}

docker_run() {
  local root="$1"; shift
  docker run --rm --network none -v "$root:/verify:ro" "$docker_image" "$@"
}

docker_cleanup() {
  [ -n "$docker_image" ] && docker rmi -f "$docker_image" >/dev/null 2>&1 || true
}

# Unprivileged user namespaces are restricted by AppArmor on Ubuntu 24.04
# (kernel.apparmor_restrict_unprivileged_userns=1), where `unshare -rm` fails
# with "write failed /proc/self/uid_map: Operation not permitted". It still
# works on hosts that permit it, so it stays as a candidate -- but only ever a
# validated one.
unshare_available() {
  command -v unshare >/dev/null 2>&1 && unshare -rm true >/dev/null 2>&1
}

unshare_prepare() { :; }

unshare_run() {
  local root="$1"; shift
  local cmd="$1"; shift
  unshare -rm chroot "$root" "${cmd#/verify}" "$@"
}

unshare_cleanup() { :; }

# ---- validation ---------------------------------------------------------------

mechanism=''

# Proves a candidate can execute: static control must yield exactly 42, dynamic
# control must fail. Both legs are required. The static leg is what a broken
# harness fails; the dynamic leg is what a non-bare environment fails.
validate_mechanism() {
  local name="$1" tmp="$2" root="$tmp/control-root" rc

  mkdir -p "$root"
  write_static_control "$root/static-control" || return 1
  local dyn
  dyn="$(find_dynamic_control)" || {
    log "FAIL: no dynamically linked control binary on this host"
    return 1
  }
  cp "$dyn" "$root/dyn-control"
  chmod +x "$root/dyn-control"

  "${name}_prepare" "$tmp" || { log "$name: could not prepare clean environment"; return 1; }

  rc=0
  "${name}_run" "$root" /verify/static-control >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne "$CONTROL_RC" ]; then
    log "$name: static control returned $rc, expected $CONTROL_RC -- mechanism cannot execute, not using it"
    "${name}_cleanup"
    return 1
  fi

  rc=0
  "${name}_run" "$root" /verify/dyn-control -c true >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    log "$name: dynamic control RAN inside the supposedly bare environment -- it is not bare, not using it"
    "${name}_cleanup"
    return 1
  fi

  log "$name: validated (static control -> $CONTROL_RC, dynamic control rejected)"
  return 0
}

select_mechanism() {
  local tmp="$1" name
  for name in docker unshare; do
    "${name}_available" || { log "$name: unavailable"; continue; }
    if validate_mechanism "$name" "$tmp"; then
      mechanism="$name"
      return 0
    fi
  done
  log "FAIL: no storeless-execution mechanism could be validated on this host."
  log "      Tried: docker (empty imported image), unshare -rm chroot."
  log "      Refusing to skip the REQ-INST-16 execution gate."
  return 1
}

mechanism_id() {
  case "$1" in
    docker) printf 'docker-empty-image' ;;
    unshare) printf 'unshare-chroot' ;;
  esac
}

# ---- entry points -------------------------------------------------------------

main() {
  local action="${1:-}"
  case "$action" in
    -h|--help) usage; exit 0 ;;
    select|run) shift ;;
    write-control)
      shift
      [ "$#" -eq 1 ] || { usage; exit 2; }
      write_static_control "$1"
      exit 0
      ;;
    *) usage; exit 2 ;;
  esac

  if [ "$action" = run ] && [ "$#" -lt 1 ]; then
    usage
    exit 2
  fi

  local tmp
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064  # $tmp is intentionally expanded now, not at exit.
  trap "docker_cleanup; rm -rf '$tmp'" EXIT

  select_mechanism "$tmp" || exit "$([ "$action" = run ] && echo "$NO_MECHANISM" || echo 1)"

  if [ "$action" = select ]; then
    mechanism_id "$mechanism"
    printf '\n'
    exit 0
  fi

  local binary="$1"; shift
  [ -f "$binary" ] || { log "FAIL: no such binary: $binary"; exit "$NO_MECHANISM"; }
  local root="$tmp/subject-root" name
  name="$(basename "$binary")"
  mkdir -p "$root"
  cp "$binary" "$root/$name"
  chmod +x "$root/$name"

  local rc=0
  "${mechanism}_run" "$root" "/verify/$name" "$@" || rc=$?
  exit "$rc"
}

main "$@"
