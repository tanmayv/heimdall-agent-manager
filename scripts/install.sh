#!/usr/bin/env bash
# REQ-DIST-5: one-line bootstrap installer for non-hub heimdall nodes.
# Verifies the release checksum BEFORE extracting anything (see fail-fast below).
#
# REQ-INST-4: every executable statement lives inside main(), invoked by the
# final `main "$@"` line. A curl|bash pipe truncated mid-transfer can then only
# ever deliver function definitions — bash hits a parse error or never reaches
# the call, so the received prefix executes nothing instead of half-installing.

GITHUB_REPO="tanmayv/heimdall-agent-manager"

# REQ-INST-7: every network call is bounded, and the two downloader branches are
# bounded EQUIVALENTLY. The old asymmetry (curl retried and had a connect
# timeout, wget had neither) meant the failure mode depended on which tool the
# host happened to have: a stalled mirror hung a wget host forever. These values
# follow src/manager/update.odin:31-32 -- 60s for a tarball, 20-30s for an API
# call -- rather than inventing new numbers for the same two operations.
NET_CONNECT_TIMEOUT=15
# API responses are small: a slow one is a broken one. Unchanged from the
# --max-time that resolve_latest_tag already carried.
NET_API_MAX_TIME=30
# A tarball is multi-MB, so a FLAT total cap would fail a slow-but-healthy
# transfer. Bound the STALL instead: abort only when throughput stays under
# NET_STALL_BYTES_PER_SEC for NET_STALL_SECONDS. curl spells this natively with
# --speed-limit/--speed-time.
#
# wget CANNOT express this, and an earlier version of this comment claimed
# --read-timeout was "the direct analogue", which is false and was measured to be
# false: --read-timeout bounds a single IDLE read, so a server sending one byte
# every 0.5s resets it forever. Real wget 1.25.0 against a 2 B/s trickle -- 0.2%
# of the floor below -- was still running after 25 seconds having moved 50 bytes,
# and wget has no total-duration option either, so NET_DOWNLOAD_MAX_TIME went
# unenforced on that branch entirely. curl states both bounds natively but applies
# --max-time PER ATTEMPT, so with --retry 3 its real ceiling was four times this
# value. run_bounded supplies the operation-wide guarantee for both; see the note
# there.
NET_STALL_SECONDS=60
NET_STALL_BYTES_PER_SEC=1024
# Absolute backstop so a mirror that dribbles just above the stall floor cannot
# hold the installer forever. Generous: 10 minutes is a slow link, not a hang.
# Enforced for the whole operation by run_bounded on both branches, because
# curl's --max-time is per attempt and wget has no equivalent flag at all.
NET_DOWNLOAD_MAX_TIME=600
TELEGRAF_VERSION="${TELEGRAF_VERSION:-1.32.1}"

usage() {
  cat <<'USAGE' >&2
usage: install.sh [--version <tag>] [--hub <url>] [--hub-url <url>] [--dry-run] [--force-service]
                  [--update, --apply-update] [--check] [--bundle <path>] [--uninstall]

Installs prebuilt heimdall binaries (heimdall, ham-bridge, ham-pty-host,
ham-ctl, telegraf), wires PATH, and registers a user-level heimdall-bridge service.
In an interactive terminal, prompts for Hub onboarding, enrollment, and vault setup.

  --version <tag>      install release <tag> instead of the latest GitHub release
  --hub <url>, --hub-url <url> download <url>/heimdall-local-<target>.tar.gz and
                       <url>/SHA256SUMS (self-hosted hub mirror) and start the
                       service with --hub <url> as an explicit override.
                       Without --hub the service reads the hub URL from
                       config.toml ([wrapper] daemon_url, written by
                       'heimdall enroll'); nothing is baked into the unit.
  --dry-run            print every planned action without writing anything
  --force-service      overwrite an existing, differing service file WITHOUT
                       keeping a .bak-<timestamp> backup (default: back up the
                       old file first; skip the write when identical). On Linux
                       it ALSO proceeds when the machine already provides a
                       system-managed heimdall-bridge.service, which this
                       installer otherwise refuses to shadow -- a user unit of
                       the same name silently takes precedence over the system
                       one, and the breakage only appears at the next restart.
  --update, --apply-update Update Heimdall binaries and components to latest version
  --check                  Check for available updates without applying
  --bundle <path>          Path to update bundle (tarball or directory) or download URL
  --force, -f              Force apply update and skip warnings
  --uninstall          remove what this installer put in place: stop the
                       service (best effort), remove the heimdall binaries
                       from the install dir, remove the service file, and
                       remove the PATH lines added to your shell rc files.
                       Honors --dry-run. Enrollment state under
                       ~/.config/heimdall (bridge token, config.toml) is NOT
                       removed.

Platforms: Linux (x86_64, aarch64/arm64), macOS (Intel, Apple Silicon).
Requires socat, the default bridge->hub TLS transport. It is not bundled;
install it with your system package manager (sudo apt install socat /
brew install socat) BEFORE running this installer.
USAGE
}

err() { printf 'error: %s\n' "$*" >&2; }
fail() { err "$*"; exit 1; }
say() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }

# GETs $1, writing the response body to $2, and prints the HTTP status code.
# Prints 000 when no HTTP response arrived at all (DNS failure, refused
# connection, timeout) -- the caller needs that apart from every other outcome,
# because "no response" is the ONLY case that may honestly blame the network.
#
# REQ-INST-6: this goes through curl OR wget. Release resolution used to call
# curl and ONLY curl, even though download() always had a wget fallback and the
# downloader guard further down accepts either. On a wget-only host the curl
# call simply was not found, the empty output was read as a failed lookup, and
# the user was told "api.github.com unreachable?" -- a false statement that
# sends someone to debug DNS and firewalls when the real problem is a missing
# binary. Reordering the guard would not have fixed that case: the guard passes,
# because wget IS present.
#
# $3 is a path the RESPONSE HEADERS are written to, for the caller to read. It
# is a file and not a global on purpose: this function is invoked as
# `code="$(api_fetch ...)"`, so it runs in a SUBSHELL and any variable it set
# would be discarded at the closing paren -- the same trap the $resolved_tag note
# on resolve_latest_tag describes. curl needs -D for this; wget's -S already
# writes them to stderr, which this branch was redirecting to a private file and
# then deleting, so the headers were being thrown away after one sed. Both now
# land in the caller's file in the same shape, and header_value below reads
# either. What needs them: a 403 can only be CALLED a rate limit when
# X-RateLimit-Remaining says so.
#
# The trailing `return 0` states this helper's contract: it REPORTS a failed
# request as a value, and callers read it with `code="$(api_fetch ...)"`, a bare
# assignment that `set -e` would abort on if this ever returned non-zero.
#
# Being precise, because an overstated comment costs the next reader real time:
# TODAY this `return 0` is DEFENSIVE, not load-bearing, for two INDEPENDENT
# reasons, either of which alone would be enough:
#   1. The last statement is `printf`, which always succeeds, so the function
#      already returns 0 on every path.
#   2. `set -e` is not even in force in this call graph. resolve_latest_tag's only
#      caller invokes it as `if resolve_latest_tag; then`, and bash SUSPENDS
#      `set -e` for the whole body of a function whose status is being tested.
#      A failing assignment inside it does not abort anything.
# Both are verified, not assumed. It is kept anyway, and must not be deleted as
# redundant: reason 1 dies the moment someone appends a statement after the
# printf, and reason 2 dies the moment someone calls resolve_latest_tag bare
# instead of in an `if`. Either change silently converts a reported failure into
# a mid-operation abort -- the shape that cost REQ-INST-5 and T2's uninstall.
# The `return 0` is what makes those edits safe to make.
api_fetch() {
  url="$1"; body_out="$2"; hdr_out="$3"
  code=""
  : >"$body_out" 2>/dev/null || true
  : >"$hdr_out" 2>/dev/null || true
  if command -v curl >/dev/null 2>&1; then
    # -f is deliberately ABSENT here, though resolution used to pass it. -f
    # turns every HTTP error into one opaque exit 22 with an empty body, which
    # is exactly what made an exhausted rate limit (403) and a prerelease-only
    # repository (404) indistinguishable from each other and from a dead link.
    code="$(curl -sS -o "$body_out" -D "$hdr_out" -w '%{http_code}' \
      --connect-timeout "$NET_CONNECT_TIMEOUT" --max-time "$NET_API_MAX_TIME" \
      "$url" 2>/dev/null)" || code=""
  elif command -v wget >/dev/null 2>&1; then
    wget -q -S -O "$body_out" --tries=1 \
      --connect-timeout="$NET_CONNECT_TIMEOUT" --read-timeout="$NET_API_MAX_TIME" \
      "$url" 2>"$hdr_out" || true
    # -S writes the response headers to stderr even under -q. Take the LAST
    # status line so a redirect chain reports where it ended up, matching what
    # curl's %{http_code} reports.
    code="$(sed -n 's|^[[:space:]]*HTTP/[0-9.]*[[:space:]]\{1,\}\([0-9][0-9][0-9]\).*|\1|p' \
      "$hdr_out" 2>/dev/null | tail -n 1)" || code=""
  fi
  case "$code" in
    [0-9][0-9][0-9]) : ;;
    *) code="000" ;;
  esac
  printf '%s\n' "$code"
  return 0
}

# Prints the value of response header $1 from the header file $2, or nothing when
# the header is absent. Reads curl's -D output and wget's -S stderr with one
# parser: header names are case-insensitive per RFC 9110, curl keeps the CRLF
# line endings off the wire, and wget indents each line by two spaces. No
# separate CRLF step is needed -- POSIX [[:space:]] includes the carriage return,
# so the trailing-whitespace trim below removes it, and an explicit sub(/\r$/)
# here was dead code that no test could ever fail on. The LAST occurrence wins,
# so a redirect chain reports the headers of the response the status line also
# came from.
header_value() {
  awk -v want="$1" '
    BEGIN { want = tolower(want) }
    {
      line = $0
      colon = index(line, ":")
      if (colon == 0) next
      key = substr(line, 1, colon - 1)
      val = substr(line, colon + 1)
      gsub(/^[[:space:]]+/, "", key); gsub(/[[:space:]]+$/, "", key)
      gsub(/^[[:space:]]+/, "", val); gsub(/[[:space:]]+$/, "", val)
      if (tolower(key) == want) found = val
    }
    END { if (length(found)) print found }
  ' "$2" 2>/dev/null
  return 0
}

# Prints a SHORT single-line excerpt of the response body $1, for diagnoses that
# can report nothing about a cause except what the server actually said. GitHub
# puts a human-readable sentence in the JSON "message" field, so prefer that and
# fall back to the raw head of the body; either way collapse it to one line and
# cap it, because an error body can be long and this goes into a one-line message.
body_excerpt() {
  excerpt="$(sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$1" 2>/dev/null | head -n 1)"
  if [ -z "$excerpt" ]; then
    excerpt="$(head -c 400 "$1" 2>/dev/null | tr '\n\r\t' '   ')"
  fi
  printf '%s' "$excerpt" | tr -s ' ' | sed 's/^ *//; s/ *$//' | cut -c1-160
  return 0
}

# Renders the epoch-seconds timestamp $1 as UTC, or prints nothing. GNU date
# spells this -d @N and BSD/macOS date spells it -r N; when neither works the
# caller simply omits the reset time rather than printing a raw epoch number at
# someone, so every failure path here is silent on purpose.
epoch_utc() {
  case "$1" in
    ''|*[!0-9]*) return 0 ;;
  esac
  date -u -d "@$1" '+%Y-%m-%d %H:%M:%SZ' 2>/dev/null \
    || date -u -r "$1" '+%Y-%m-%d %H:%M:%SZ' 2>/dev/null \
    || true
  return 0
}

# Prints the first "tag_name" value in the JSON body $1, or nothing when there
# is none. GitHub returns /releases newest-first, so the first match is also the
# newest entry.
#
# The trailing `return 0` matters MORE here than in api_fetch, because this
# function can genuinely return non-zero: `head -n 1` exits after the first
# match, sed takes SIGPIPE once its remaining output exceeds the 64K pipe buffer,
# and pipefail propagates that as 141. Measured, not theorised -- a 2500-entry
# release list produces 186K of sed output and the pipeline does return 141.
#
# It is still only DEFENSIVE as the code stands, for the reason spelled out on
# api_fetch above: the sole caller is `if resolve_latest_tag; then`, which
# suspends `set -e` for the entire function body, so the 141 currently goes
# nowhere. Do not conclude from that it can be deleted. The value in
# `tag="$(parse_tag_name ...)"` is correct even at status 141, so the day someone
# calls resolve_latest_tag bare, deleting this line turns a WORKING lookup into a
# silent abort with no diagnosis -- a failure that would look like the installer
# hanging up for no reason on precisely the largest, busiest repositories.
parse_tag_name() {
  sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" 2>/dev/null \
    | head -n 1
  return 0
}

# REQ-INST-6. Resolves the release tag to install into $resolved_tag. Returns 0
# on success; on failure returns 1 with a SPECIFIC diagnosis in $resolve_error.
# $resolve_notice carries a non-fatal remark on an otherwise successful lookup.
#
# FOUR unrelated failures used to produce the single message "could not resolve
# the latest GitHub release (api.github.com unreachable?)": no downloader at
# all; curl absent but wget present; an exhausted API rate limit; and a
# repository whose only releases are prereleases. All four sent the user off to
# debug their network, and for three of them the network was fine. Each now
# names its own cause and its own next step.
#
# It reports through GLOBALS instead of printing the tag, which is not a style
# choice: `tag="$(resolve_latest_tag)"` runs the function in a SUBSHELL, so
# $resolve_error would be discarded at exactly the moment it is needed.
#
# FAIL-CLOSED. Only a tag_name parsed out of a 200 response can ever reach
# $resolved_tag; an error body, an empty body, or a 200 that does not parse is a
# failure and never a tag. A guessed tag becomes a 404 on the tarball download,
# which is a worse and more confusing failure than the one this replaces.
resolve_latest_tag() {
  resolved_tag=""
  resolve_error=""
  resolve_notice=""

  # Diagnosed BEFORE any network attempt: with no downloader installed there is
  # nothing to blame the network for. The curl-or-wget guard in main() cannot
  # cover this -- it deliberately runs after the dry-run exit, so that a dry run
  # stays usable on a machine with neither tool, and resolution happens before
  # it either way.
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    resolve_error="need curl or wget to resolve the latest release; install one, or pass --version <tag> to skip the lookup"
    return 1
  fi

  api_base="https://api.github.com/repos/$GITHUB_REPO/releases"
  body_file="$(mktemp 2>/dev/null)" || body_file=""
  if [ -z "$body_file" ]; then
    resolve_error="could not create a temporary file to read the release list; check TMPDIR (${TMPDIR:-/tmp}) and its free space, or pass --version <tag> to skip the lookup"
    return 1
  fi

  hdr_file="$body_file.hdr"
  from_list=false
  code="$(api_fetch "$api_base/latest" "$body_file" "$hdr_file")"
  if [ "$code" = "404" ]; then
    # /releases/latest EXCLUDES drafts and prereleases by GitHub's definition,
    # and this repository's own workflow defaults BOTH to true
    # (.github/workflows/release-local-binaries.yml:19-27). So for as long as
    # only prereleases are published, /releases/latest 404s for everyone -- which
    # means the bare one-liner advertised in README.md fails for every user,
    # while /releases lists the tags perfectly well. The list endpoint DOES
    # include prereleases, so fall back to it rather than reporting nothing.
    from_list=true
    code="$(api_fetch "$api_base" "$body_file" "$hdr_file")"
  fi
  tag="$(parse_tag_name "$body_file")"
  # Read everything the response can tell us BEFORE cleaning up, so the arms
  # below can quote the server instead of guessing at it. Capturing the excerpt
  # into a variable here -- rather than deferring the rm until after the case --
  # is deliberate: the 200 branch returns from three points above the case, so a
  # deferred rm would leak the temp file on every successful resolution.
  rl_remaining="$(header_value 'X-RateLimit-Remaining' "$hdr_file")"
  rl_reset="$(header_value 'X-RateLimit-Reset' "$hdr_file")"
  api_body="$(body_excerpt "$body_file")"
  rm -f "$body_file" "$hdr_file"

  if [ "$code" = "200" ]; then
    if [ -n "$tag" ]; then
      resolved_tag="$tag"
      if $from_list; then
        resolve_notice="no stable release exists yet; selected the newest PRERELEASE $tag -- pass --version <tag> to pin a different one"
      fi
      return 0
    fi
    if $from_list; then
      # THE LIVE CASE for this project, not a corner case. Releases here are cut
      # through the GitHub UI with the workflow's defaults left ticked, and
      # release-local-binaries.yml:224-233 passes BOTH --draft and --prerelease.
      # A prerelease is merely excluded from /releases/latest, which the fallback
      # above recovers from. A DRAFT is invisible to an unauthenticated caller
      # altogether -- absent from /releases too, with assets that cannot be
      # fetched even given the tag -- so the fallback correctly finds nothing and
      # lands here.
      #
      # The wording reports only what the API ANSWERED from this caller's
      # position; it does not claim to have enumerated the repository, because
      # unauthenticated it cannot see drafts and must not pretend otherwise.
      # Detecting them is not possible without sending a token, so the draft is
      # named as a POSSIBILITY the maintainer can act on, never as a claim about
      # what the repository contains.
      resolve_error="api.github.com lists no published release for this repository; a release that exists but is still a DRAFT is invisible to an unauthenticated lookup and looks identical from here, so if one was cut, publish it -- otherwise pass --version <tag> or --hub <url>"
    else
      # A 200 that does not parse. Fail rather than guess: see FAIL-CLOSED.
      resolve_error="api.github.com answered the latest-release lookup with no tag_name field; pass --version <tag> or --hub <url>"
    fi
    return 1
  fi

  case "$code" in
    403|429)
      # A 403 is NOT proof of an exhausted rate limit, and this arm used to say
      # it was. GitHub answers 403 for secondary (abuse) rate limiting too, and
      # for that mechanism "wait for the window to reset" is not merely unproven
      # but WRONG ADVICE: the hourly window has nothing to do with it and waiting
      # it out does not clear it. The only thing that establishes the primary
      # limit is the server saying so, in X-RateLimit-Remaining. So the confirmed
      # message is now gated on that header, and without it this reports the
      # status, what the body said, and nothing it cannot prove -- the same
      # discipline every other arm here follows.
      #
      # Each branch assigns $resolve_error exactly ONCE, composing its optional
      # clause into a variable first. Appending to $resolve_error across several
      # statements would read the same to a user and break the structural test
      # that every diagnosis carries a next step, which inspects each assignment
      # whole.
      if [ "$rl_remaining" = "0" ]; then
        # A reset timestamp is what turns "wait" into something actionable, so
        # include it whenever the server sent one that renders on this host.
        rl_when=""
        rl_reset_utc="$(epoch_utc "$rl_reset")"
        if [ -n "$rl_reset_utc" ]; then
          rl_when=" and resets at $rl_reset_utc"
        fi
        resolve_error="api.github.com rejected the request with HTTP $code: the unauthenticated rate limit (60 requests/hour/IP) is exhausted$rl_when; this is transient -- wait for the window to reset, or pass --version <tag> to skip the lookup"
      else
        # GitHub's 403 body explains itself, so quote it rather than paraphrase.
        api_said=""
        if [ -n "$api_body" ]; then
          api_said=" -- it answered: $api_body"
        fi
        resolve_error="api.github.com refused the latest-release lookup with HTTP $code and did not report an exhausted rate limit (no X-RateLimit-Remaining: 0), so the cause is not established from here$api_said; pass --version <tag> or --hub <url>"
      fi
      ;;
    000)
      resolve_error="could not reach api.github.com (no HTTP response -- check network, DNS, or proxy); pass --version <tag> or --hub <url>"
      ;;
    *)
      resolve_error="api.github.com returned HTTP $code for the latest-release lookup; pass --version <tag> or --hub <url>"
      ;;
  esac
  return 1
}

# REQ-INST-7: fatal download diagnosis. Names the URL that failed, because the
# installer fetches several and a bare "download failed" does not say which.
download_failed() {
  url="$1"; out="$2"; why="${3:-}"
  # $3 is OPTIONAL and must stay defaulted: main() runs under `set -euo pipefail`
  # and the other call sites pass two arguments, so a bare "$3" aborts the script
  # with "unbound variable" instead of reporting the download failure. Caught by
  # the suite, which is the whole argument for having it.
  #
  # It names the bound that was exceeded when the watchdog stopped the transfer.
  # Without it the user sees "download failed" for a transfer that was still
  # technically alive, which is the same unproven-cause problem REQ-INST-6 is
  # about: a killed download must say it was killed and why.
  # Set off with a dash rather than parentheses: the TMPDIR clause below is already
  # parenthesised, and two adjacent parentheticals read as a stutter.
  detail=""
  if [ -n "$why" ]; then
    detail=" -- $why"
  fi
  tmp_root="${TMPDIR:-/tmp}"
  tmp_root="${tmp_root%/}"
  case "$out" in
    "$tmp_root"/*)
      # main() creates the work dir under TMPDIR with an explicit mktemp
      # template, so the tarball is where TMPDIR points on Linux AND macOS --
      # see the note there for why the template is not optional. On a host where
      # that is a small tmpfs the real failure is running out of space, which
      # looks nothing like a network problem in the output.
      fail "download failed: $url$detail (target $out is under $tmp_root; if that is a small tmpfs the transfer can exhaust it -- set TMPDIR to a larger filesystem and re-run)"
      ;;
  esac
  fail "download failed: $url$detail"
}

# Bytes currently in $1, or 0. `wc -c <file` and not `stat`: stat's size flag is
# -c%s on GNU and -f%z on BSD, and this has to work on both.
file_bytes() {
  # The existence check is not redundant with the redirect's 2>/dev/null: the
  # FAILED REDIRECT is reported by the shell itself, not by wc, so without this the
  # watchdog printed "No such file or directory" on every poll before the
  # downloader had created the file -- a shell error in the middle of a healthy
  # download, which reads like a fault and is not one.
  if [ ! -f "$1" ]; then
    printf '0'
    return 0
  fi
  bytes="$(wc -c <"$1" 2>/dev/null | tr -d ' ')"
  case "$bytes" in
    ''|*[!0-9]*) bytes=0 ;;
  esac
  printf '%s' "$bytes"
}

# REQ-INST-7. Runs the downloader in $@ against output file $1 and enforces the
# two bounds NEITHER downloader can state for itself. Sets $bound_error to the
# bound that was exceeded, or empty; otherwise returns the downloader's status.
#
# WHY A WATCHDOG, FOR BOTH BRANCHES. Neither tool can express a bound on the whole
# operation, and each fails differently:
#
#   wget has NO minimum-throughput option and NO total-duration option.
#   --read-timeout is not the analogue of curl's --speed-time: it bounds one IDLE
#   read, so a byte every 0.5s resets it forever. Measured, not theorised -- real
#   wget 1.25.0 with exactly the flags this branch used to pass was still running
#   after 25s on a 2 B/s trickle, 0.2% of the floor, having moved 50 bytes.
#
#   curl states both bounds natively, but --max-time is PER ATTEMPT, not per
#   operation. Also measured: against an above-floor endless stream,
#   `--retry 3 --max-time 3` took 19s, not 3s -- four attempts plus backoff. So
#   with --retry 3 the real worst case was 4 * NET_DOWNLOAD_MAX_TIME plus backoff,
#   roughly 40 minutes rather than the 10 the constant promises.
#
# The native flags are kept on both branches: they abort a doomed attempt sooner
# and with a better message than a kill. This adds the guarantee they cannot make.
#
# NOT coreutils `timeout`: macOS ships no `timeout` and this installer registers a
# launchd service, so it runs there. Plain POSIX shell plus wc -c.
#
# THE FLOOR IS AN AVERAGE SINCE THE LAST KNOWN-GOOD POINT, not a per-window bucket,
# and that distinction was forced by measurement rather than chosen for elegance.
#
# Progress is observed as bytes landing in the output file, which is what can be seen
# without cooperation from the tool. It is counted as CUMULATIVE DELIVERED BYTES --
# each poll credits max(0, growth since the last poll) -- and NOT as the file's
# current size.
#
# REQ-INST-17 is why. download() calls wget without -c, so a retry RESTARTS FROM
# ZERO and truncates the output file. Measured against the file's size, that
# regression made (current - anchor) negative, which no floor can ever clear: the
# re-anchor branch became unreachable, anchor_time froze, `since` grew without
# bound, and the required byte count (floor * since) ROSE while progress was still
# being compared with a stale pre-truncation anchor. A stall was then declared with
# CERTAINTY at the horizon, on a transfer that was recovering perfectly well. Found
# in a live macos-15-intel CI log: "Read error at byte 8192/100000000 ... Retrying".
# Counting delivered bytes makes a truncation worth zero rather than negative, so a
# recovering transfer keeps re-anchoring on the bytes it is really moving.
#
# WHEN THE FILE NEVER SHRINKS THIS IS ARITHMETICALLY THE OLD CODE: delivered equals
# (current - initial), so (delivered - anchor_delivered) equals the former
# (current - anchor_bytes), exactly. Every property measured below is therefore
# unchanged for every transfer that does not truncate.
#
# AND A DOWNLOADER THAT RETRIES AND TRUNCATES WITHOUT EVER GETTING ANYWHERE IS STILL
# CAUGHT. The previous version of this comment claimed the file-size signal covered
# that case; counting delivered bytes does not give it up. MEASURED, not assumed:
#   - the ordinary futile loop re-fetches the same chunk and keeps returning to the
#     SAME size, so consecutive polls observe no growth, nothing is credited, and the
#     floor fires exactly as before -- measured, delivered plateaued at 13312 bytes
#     across ten polls of a 0.5s truncate/refetch cycle;
#   - a loop that sits EMPTY long enough for a poll to land in its trough does credit
#     about one chunk per cycle -- measured, ~2730 B/s on a 3s cycle -- so it clears
#     the floor and is bounded by NET_DOWNLOAD_MAX_TIME instead, whose message names
#     the total limit, which is what actually happened.
# Either way it is bounded, and neither message asserts a cause the evidence does not
# support. What separates a RECOVERING transfer from both is that it grows past every
# previous poll, so its bytes are credited and it keeps re-anchoring.
#
# The alternative considered and REJECTED was a second predicate on the high-water
# mark: fail when the mark has not advanced within a horizon. It false-fires on the
# very case this fix exists for -- a retry late in a large transfer leaves the mark
# unmoved for as long as it takes to re-fetch what had already arrived. Do not add it.
#
# But the file size LAGS the socket:
# both tools write in bursts, so sampled once a second a healthy 4096 B/s transfer
# produces deltas like wget's 4096,4096,4096,4096,0,8192 and curl's 4096,0,8192,0.
#
# Bucketing those into fixed NET_STALL_SECONDS windows and judging each one fails
# honest transfers. Measured: a server sending 16 KB every 4 seconds -- 4096 B/s,
# FOUR TIMES the floor -- was declared stalled on the wget branch, because two
# consecutive 2-second windows saw no write at all. Requiring two consecutive
# sub-floor windows did not save it; the flaw is the bucket, not the count.
#
# So an ANCHOR is kept at the last moment throughput was demonstrably fine, and the
# test is whether average throughput since that anchor has met the floor. Any sample
# that clears it re-anchors. A stall is declared only when the anchor has gone
# unmoved for a horizon of two full stall periods, because a bursty transfer
# re-anchors on every burst while a genuinely stalled one never does.
#
# THE MEASURED TOLERANCE, so the next reader knows the real edge rather than guessing
# at it. Holding the average at 4x the floor and varying only the gap between bursts,
# with NET_STALL_SECONDS compressed to 2s (horizon 4s): gaps of 0.5s, 1s and 2s are
# correctly carried to the deadline on BOTH branches; at a 3s gap -- 75% of the
# horizon -- wget's write lag makes the anchor look unmoved and a false stall is
# declared. So the floor reliably tolerates burst gaps up to about
# NET_STALL_SECONDS. At the real 60s that is a 60-second gap with nothing arriving,
# which is a stall by any definition worth having, and write buffers are measured in
# seconds rather than minutes. The limitation is real but sits far outside the range
# a healthy transfer occupies.
run_bounded() {
  out="$1"; shift
  bound_error=""
  # Reset explicitly. download() is called more than once per run (tarball, then
  # SHA256SUMS), and leaving a previous non-zero status in this global would fail
  # the SECOND download because the FIRST one failed.
  dl_status=0

  "$@" &
  dl_pid=$!

  now="$(date +%s)"
  deadline=$(( now + NET_DOWNLOAD_MAX_TIME ))
  # Last point at which throughput was demonstrably at or above the floor.
  # anchor_delivered is a position in the monotonic delivered-bytes count, NOT a
  # file size, which is what keeps a truncation from poisoning the comparison.
  anchor_time="$now"
  last_bytes="$(file_bytes "$out")"
  delivered=0
  anchor_delivered=0
  stall_horizon=$(( NET_STALL_SECONDS * 2 ))

  while kill -0 "$dl_pid" 2>/dev/null; do
    sleep 1
    # Re-test liveness AFTER the sleep, before judging any bound. Without this
    # there is a race that fails a SUCCESSFUL download: if the transfer finishes
    # during the sleep on a tick that also crosses a window boundary, the window
    # sees only the bytes from its own final fraction of a second, finds them under
    # the floor, and reports a stall for a download that had already completed.
    # `wait` would then return 0 while $bound_error forced a failure -- the worst
    # shape available, a wrong cause on a working install.
    kill -0 "$dl_pid" 2>/dev/null || break
    now="$(date +%s)"
    if [ "$now" -ge "$deadline" ]; then
      bound_error="exceeded the ${NET_DOWNLOAD_MAX_TIME}s total download limit"
    else
      current="$(file_bytes "$out")"
      # Credit GROWTH ONLY. A truncating retry is worth zero here, never a
      # negative: it delivered nothing new, but it did not un-deliver what the
      # wire had already carried. See REQ-INST-17 in the header.
      if [ "$current" -gt "$last_bytes" ]; then
        delivered=$(( delivered + current - last_bytes ))
      fi
      last_bytes="$current"
      since=$(( now - anchor_time ))
      if [ "$(( delivered - anchor_delivered ))" -ge "$(( NET_STALL_BYTES_PER_SEC * since ))" ]; then
        # Throughput since the anchor meets the floor, so this is the new
        # known-good point. A bursty transfer lands here on every burst.
        anchor_time="$now"
        anchor_delivered="$delivered"
      elif [ "$since" -ge "$stall_horizon" ]; then
        bound_error="stalled below ${NET_STALL_BYTES_PER_SEC} bytes/sec for ${since}s"
      fi
    fi
    if [ -n "$bound_error" ]; then
      # TERM first so the downloader can close the socket, then KILL if it ignores
      # it. The grace loop is bounded, because a watchdog that can itself hang is
      # not one.
      kill "$dl_pid" 2>/dev/null || true
      grace=0
      while [ "$grace" -lt 5 ] && kill -0 "$dl_pid" 2>/dev/null; do
        sleep 1
        grace=$(( grace + 1 ))
      done
      kill -9 "$dl_pid" 2>/dev/null || true
      break
    fi
  done

  # `wait` reaps it and yields its status; after a kill that status is non-zero,
  # which is what the caller needs. The `|| dl_status=$?` form is required rather
  # than stylistic: a bare `wait` would make a non-zero status the function's own
  # exit status at a point where this still has cleanup to decide.
  #
  # The loop above tests liveness with `kill -0`, which reports an exited child as
  # DEAD rather than as a lingering zombie, because bash reaps background children
  # on SIGCHLD and keeps the status in its jobs table for `wait` to return later.
  # Both halves verified on this host, since if `kill -0` had reported a finished
  # child as alive the loop would have run on past a COMPLETED download and then
  # reported a stall for a transfer that had already succeeded.
  wait "$dl_pid" 2>/dev/null || dl_status=$?
  if [ -n "$bound_error" ]; then
    return 1
  fi
  return "$dl_status"
}

download() {
  url="$1"; out="$2"
  if command -v curl >/dev/null 2>&1; then
    # --max-time was missing here entirely: --connect-timeout bounds only the
    # handshake, so a connection that established and then trickled one byte a
    # minute was bounded by nothing at all. It is PER ATTEMPT though, so
    # run_bounded is what caps the whole operation across --retry.
    run_bounded "$out" \
      curl -fL --retry 3 --connect-timeout "$NET_CONNECT_TIMEOUT" \
        --speed-limit "$NET_STALL_BYTES_PER_SEC" --speed-time "$NET_STALL_SECONDS" \
        --max-time "$NET_DOWNLOAD_MAX_TIME" \
        -o "$out" "$url" \
      || download_failed "$url" "$out" "$bound_error"
  else
    # Was a bare `wget -O "$out" "$url"`: no retries, no connect timeout, no read
    # timeout. It now has all three, and run_bounded supplies the two bounds wget
    # cannot express as flags at all -- the total cap and the throughput floor.
    # That is what makes this branch's promise the same as the curl branch's,
    # rather than a comment claiming it is.
    run_bounded "$out" \
      wget -O "$out" --tries=3 \
        --connect-timeout="$NET_CONNECT_TIMEOUT" \
        --read-timeout="$NET_STALL_SECONDS" \
        "$url" \
      || download_failed "$url" "$out" "$bound_error"
  fi
}

# Hashes $1, or prints nothing when no checksum tool exists or the file cannot
# be read. Callers that MUST have a hash wrap this in sha256_of; the uninstall
# path deliberately uses the empty answer instead, because aborting a removal
# that is already half-done is worse than leaving one file behind.
#
# The trailing `return 0` is load-bearing, not tidiness. Under
# `set -euo pipefail` an EMPTY ANSWER IS NOT THE SAME AS A SUCCESSFUL ONE: a
# failing sha256sum (unreadable file, a symlink to something root-only) poisons
# the pipeline through pipefail, and when neither tool exists the `elif` test
# itself is the function's exit status. Either way the function returns
# non-zero, and `current="$(sha256_or_empty x)"` is a bare assignment, so `set
# -e` kills the script on the spot. Inside do_uninstall that aborts BETWEEN the
# binaries and the service file — the same failure shape as the REQ-INST-5 bug
# this script was fixed for, just on the removal side. Returning 0 makes "I
# could not hash it" a value the caller decides about, which is the whole point
# of this function existing separately from sha256_of.
sha256_or_empty() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  fi
  return 0
}

# Fail-closed hash for the download-verification path: no tool, no unverified
# install. The fail below is only REACHABLE because sha256_or_empty returns 0
# on an empty answer; without that it aborted first and this message never
# printed.
sha256_of() {
  sum="$(sha256_or_empty "$1")"
  [ -n "$sum" ] || fail "need sha256sum or shasum -a 256 to hash $1"
  printf '%s\n' "$sum"
}

# --- socat preflight (REQ-INST-14) ---------------------------------------------
# socat is the DEFAULT bridge->hub TLS transport. src/lib/ws/ws.odin's
# tls_client_command (:286-297) returns openssl_s_client_command ONLY when
# HAM_TLS_BACKEND is exactly "s_client"; for every other value -- including
# unset, the default -- it returns socat_openssl_command, which spawns an argv
# literally named "socat" (:341). The same rule is duplicated in
# src/lib/http_client/http_client.odin and in the bridge's
# bridge_tls_backend_is_socat.
#
# socat is NOT in the release tarball (it is GPL-2.0, so bundling it is not an
# engineering call) and a bundled bin/openssl does NOT cover this path -- it
# only serves the s_client fallback. Without this preflight a socat-less host
# installs cleanly, is told it succeeded, and then never reaches a wss:// hub,
# with no error anywhere naming the cause.
#
# Why this went unnoticed for so long: the published bin/ham-bridge is a Nix
# wrapProgram SHELL SCRIPT that prepends nix store paths for socat and openssl
# onto PATH before exec'ing the real binary. On a Nix host the wrapper supplies
# socat silently. Off Nix there is no wrapper and no socat -- so this is not a
# corner case, it is the ordinary case for anyone installing from the tarball.
#
# Keep this vocabulary in sync with the "tls_dependency" field that
# scripts/release/package-local-binary-tarball.sh writes into METADATA.json:
# one defect, two places, one story.

have_socat() { command -v socat >/dev/null 2>&1; }

# Whether the hub the unit will be started with terminates TLS at all.
# parse_ws_url (src/lib/ws/ws.odin:347) sets secure=true only for wss://, so
# the plain-HTTP, VPN-only deployment documented in SELF_HOSTING.md genuinely
# needs no socat. An UNKNOWN hub -- no --hub, which is the common case since
# the unit reads [wrapper] daemon_url from config.toml -- is treated as NEEDING
# socat: at install time we usually cannot know the eventual hub, and it is
# overwhelmingly a remote TLS one.
hub_is_plaintext() {
  case "${1:-}" in
    http://*|ws://*) return 0 ;;
    *) return 1 ;;
  esac
}

socat_required_message() {
  cat <<'SOCAT'
socat is not installed. Install socat FIRST, then re-run this installer.

  Debian/Ubuntu:  sudo apt install socat
  macOS:          brew install socat
  Fedora/RHEL:    sudo dnf install socat
  Arch:           sudo pacman -S socat

socat is the default bridge->hub TLS transport: the bridge spawns
'socat OPENSSL-CONNECT' to terminate TLS for the wss:// control channel. It is
deliberately NOT bundled in the release tarball, and a bundled bin/openssl --
where one is present at all -- does NOT satisfy that default path: openssl
serves only the legacy fallback. You do not need to install openssl separately
for this: socat links libssl itself, and your package manager installs that
along with socat.
Installing without socat would leave a bridge that cannot reach a TLS hub, so
this stops here rather than reporting a successful install.

Nothing has been installed; no files were written.

If your hub is plain HTTP with no TLS, say so explicitly and this check is
skipped: install.sh --hub http://<host>:<port>

Advanced: HAM_TLS_BACKEND=s_client switches the bridge to the legacy
'openssl s_client' transport, which needs no socat but tears down on multi-read
bursts above 16 KB (large file reads and artifact transfers). There is
deliberately no automatic fallback to it -- set it only if you knowingly accept
that limitation.
SOCAT
}

# --- service templates (mirrors SELF_HOSTING.md sections 2.8 and 2.9) -------
# REQ-INST-1: the unit carries --hub ONLY when the operator passed it
# explicitly. Otherwise the bridge reads [wrapper] daemon_url from config.toml
# (written by 'heimdall enroll') — the single source of truth — instead of a
# baked-in URL beating the enrolled config on every start.

service_hub_flags_systemd() {
  if [ -n "$hub_url" ]; then printf ' \\\n    --hub "%s"' "$hub_url"; fi
}

service_hub_flags_plist() {
  if [ -n "$hub_url" ]; then
    printf '    <string>--hub</string>\n    <string>%s</string>\n' "$hub_url"
  fi
}

# --- REQ-INST-23: the SYSTEM-wide user-unit search path ------------------------
# The directories systemd searches for USER units that the MACHINE provides, in
# systemd's own precedence order (systemd.unit(5), "User Unit Search Path").
# ~/.config/systemd/user is deliberately absent: that is where WE write, and it
# sits ABOVE all of these, which is the whole problem this list exists to detect.
# Emitted one per line by a function rather than pasted at the call site so the
# test suite can re-derive the list from this single source instead of keeping a
# hand-typed copy that silently drifts.
system_unit_dirs() {
  printf '%s\n' /etc/systemd/user \
                /run/systemd/user \
                /usr/local/lib/systemd/user \
                /usr/lib/systemd/user \
                /lib/systemd/user
}

# --- REQ-INST-26: the PATH the bridge SERVICE runs with ------------------------
# The bridge spawns several tools by BARE NAME, and Odin resolves a slashless
# argv[0] against the spawning process's OWN PATH -- core/os/process_linux.odin
# (:425-455) reads get_env("PATH"), stats each entry, and returns a hard
# .Not_Exist on a miss; process_posix.odin does the same on darwin. So whatever
# PATH this unit sets is the only thing standing between the bridge and a
# "command not found" it cannot report usefully.
#
# Neither service manager's default is enough:
#   systemd --user : a compiled-in default, typically
#                    /usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin
#   launchd        : /usr/bin:/bin:/usr/sbin:/sbin
# Neither contains $install_dir. And on Apple Silicon launchd's default excludes
# /opt/homebrew/bin -- which is exactly where `brew install socat` puts socat.
# That is the load-bearing case: the REQ-INST-14 preflight above runs in the
# INSTALLER's shell with the user's full PATH, so it could pass while the bridge
# still cannot spawn socat. A check that validates something other than what it
# claims to guarantee. Setting PATH here is what makes that preflight BIND.
#
# Composition order:
#   1. $install_dir         -- the binaries this installer just wrote.
#   2. discovered dirs      -- where THIS host actually keeps the bare-name
#                              tools, from `command -v`.
#   3. platform static tail -- the boot-time net for when discovery finds
#                              nothing.
#
# Two deliberate choices, both measured rather than assumed:
#
# * The discovered dirs are NOT canonicalised. `command -v` reports the
#   directory as it appears on the user's PATH, which is the STABLE one -- a
#   ~/.nix-profile/bin or /opt/homebrew/bin symlink dir. `readlink -f` would
#   instead bake a garbage-collectable /nix/store/<hash> path into a unit that
#   outlives it; on the dev host it also renames the target (socat -> socat1),
#   so the resolved path is not even a drop-in for the name we looked up.
# * We do NOT bake the installer's whole $PATH. That would capture a venv,
#   nix-shell or temp-dir entry into a boot unit, and an installer invoked from
#   cron would bake a PATH narrower than the static tail.
#
# A stale entry is harmless, not fatal: the resolver skips a directory whose
# statx fails and keeps going, so a dead entry costs one failed syscall. What no
# static tail can do is rescue a tool that only ever lived in a store path that
# was then collected -- on Nix hosts the published ham-bridge is a wrapProgram
# script that prepends its own store paths anyway (see the preflight above).
#
# DELIBERATELY NOT COVERED: the agent CLIs (`claude`, `codex`, ... --
# src/bridge/provider_seeds.odin:21 spawns a literal {"claude"}). They never
# resolve against this PATH. src/lib/tmux/tmux.odin's build_shell_command
# (:346-376) wraps every agent command in `exec $SHELL -l -c`, a LOGIN shell,
# specifically so they resolve against the user's own PATH -- which is what
# wire_path()'s rc lines below provide. Only `tmux` itself has to be reachable
# from this unit; the pane's login shell does the rest.
#
# Emitted from functions rather than pasted into both writers so the test suite
# can re-derive the set from this single source instead of keeping a hand-typed
# copy that silently drifts (same reason as system_unit_dirs above).

# The tools the bridge spawns by bare name, so they must resolve on this PATH:
#   socat   src/lib/ws/ws.odin:341, src/lib/http_client/http_client.odin:468
#   tmux    src/lib/tmux/tmux.odin (every os.process_exec there)
#   git     src/lib/vcs/git.odin, src/bridge/vcs_provider.odin
#   sh      src/bridge/hub_runtime_client.odin:2251/:2529, bridge/shell_cmd.odin:94
#   setsid  src/bridge/shell_cmd.odin:96 -- linux only; that spawn is guarded by
#           `when ODIN_OS == .Darwin` (:93-97), which drops setsid on macOS where
#           it does not exist. Listing it is therefore safe on both: discovery
#           simply finds nothing to contribute on darwin.
service_path_tools() {
  printf '%s\n' socat tmux git sh setsid
}

# The fallback tail, per platform. Mirrors each service manager's own default
# plus the prefixes that manager omits (homebrew on darwin, sbin on linux).
service_path_tail() {
  if [ "$os" = "darwin" ]; then
    printf '%s\n' /opt/homebrew/bin /opt/homebrew/sbin /usr/local/bin \
                  /usr/bin /bin /usr/sbin /sbin
  else
    printf '%s\n' /usr/local/bin /usr/bin /bin \
                  /usr/local/sbin /usr/sbin /sbin
  fi
}

# The systemd writer QUOTES this value -- Environment="PATH=..." -- because
# systemd splits an unquoted Environment= on whitespace and discards what
# follows. With a space in $install_dir, `systemd-analyze verify` on the
# unquoted form reports:
#     Invalid environment assignment, ignoring: home/.local/bin:/usr/bin:...
# i.e. PATH would silently become the fragment before the space. The launchd
# writer needs no such care: a plist <string> carries spaces literally.
service_path_value() {
  service_path_acc="$install_dir"
  for service_path_tool in $(service_path_tools); do
    service_path_hit="$(command -v "$service_path_tool" 2>/dev/null || true)"
    # A shell builtin or function resolves with no slash; only a real file has a
    # directory to contribute.
    case "$service_path_hit" in
      */*) service_path_dir="${service_path_hit%/*}" ;;
      *)   continue ;;
    esac
    [ -n "$service_path_dir" ] || continue
    case ":$service_path_acc:" in *":$service_path_dir:"*) continue ;; esac
    service_path_acc="$service_path_acc:$service_path_dir"
  done
  for service_path_dir in $(service_path_tail); do
    case ":$service_path_acc:" in *":$service_path_dir:"*) continue ;; esac
    service_path_acc="$service_path_acc:$service_path_dir"
  done
  printf '%s' "$service_path_acc"
}

render_systemd_unit() {
  cat <<UNIT
[Unit]
Description=Heimdall Bridge
After=network-online.target

[Service]
Type=simple
ExecStart="$install_dir/ham-bridge" \\
    --bridge-token-file "%h/.config/heimdall/bridge-token" \\
    --port 49323 \\
    --local-endpoint-port 49324 \\
    --local-run-dir /tmp/heimdall-bridge-local$(service_hub_flags_systemd)
Environment="PATH=$(service_path_value)"
Environment="HEIMDALL_HAM_PTY_HOST_BIN=$install_dir/ham-pty-host"
Environment=HEIMDALL_BRIDGE_PTY_HOST=true
Environment="HEIMDALL_HAM_CTL_BIN=$install_dir/ham-ctl"
Restart=on-failure
RestartSec=5s
KillMode=process

[Install]
WantedBy=default.target
UNIT
}

render_launchd_plist() {
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>works.earendil.heimdall-bridge</string>
  <key>ProgramArguments</key>
  <array>
    <string>$install_dir/ham-bridge</string>
$(service_hub_flags_plist)    <string>--bridge-token-file</string>
    <string>$service_home/.config/heimdall/bridge-token</string>
    <string>--port</string>
    <string>49323</string>
    <string>--local-endpoint-port</string>
    <string>49324</string>
    <string>--local-run-dir</string>
    <string>/tmp/heimdall-bridge-local</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>$(service_path_value)</string>
    <key>HEIMDALL_HAM_PTY_HOST_BIN</key>
    <string>$install_dir/ham-pty-host</string>
    <key>HEIMDALL_BRIDGE_PTY_HOST</key>
    <string>true</string>
    <key>HEIMDALL_HAM_CTL_BIN</key>
    <string>$install_dir/ham-ctl</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>Crashed</key>
    <true/>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>StandardOutPath</key>
  <string>/tmp/heimdall-logs/heimdall-bridge.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/heimdall-logs/heimdall-bridge.err.log</string>
</dict>
</plist>
PLIST
}

print_onboarding() {
  hub_display="<your-hub-url>"
  if [ -n "$hub_url" ]; then hub_display="$hub_url"; fi
  cat <<EOF

Installed heimdall $effective_version for $target.

Next steps:

1. On the HUB, create a one-time enrollment token:
     ham-ctl bridge enroll-token --new

2. On THIS machine, enroll this node:
     heimdall enroll hbe_... --hub $hub_display
   Underlying engine (compatibility): ham-bridge enroll --hub $hub_display --enrollment-token hbe_... --bridge-token-file ~/.config/heimdall/bridge-token
EOF
  if [ -n "$hub_url" ]; then
    cat <<EOF
   The registered service starts the bridge with --hub $hub_url (explicit
   operator override passed to install.sh).
EOF
  else
    cat <<EOF
   No hub URL is baked into the service file: after enrolling, the bridge
   reads the hub from config.toml ([wrapper] daemon_url), which this step
   writes.
EOF
  fi
  cat <<EOF

3. Start the bridge service:
EOF
  if [ "$os" = "linux" ]; then
    cat <<'EOF'
     systemctl --user enable --now heimdall-bridge
     systemctl --user status heimdall-bridge
EOF
  else
    cat <<'EOF'
     launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/works.earendil.heimdall-bridge.plist
     launchctl kickstart -k gui/$(id -u)/works.earendil.heimdall-bridge
EOF
  fi
  cat <<EOF

Service file: $service_file (registered but not started; enrollment comes first)
EOF
  if [ -n "$service_user" ]; then
    cat <<EOF
Registered for user: $service_user (home: $service_home) — run step 3 as that user.
EOF
  fi
  cat <<EOF
Logs: macOS /tmp/heimdall-logs/heimdall-bridge.*.log; Linux 'journalctl --user -u heimdall-bridge -f'
EOF
  # REQ-INST-5: a shell rc file that could not be written is not an install
  # failure. Say so plainly, so a NixOS/home-manager user is not left guessing
  # whether the run half-worked.
  if "${path_needs_action:-false}"; then
    cat <<EOF

NOTE: the install SUCCEEDED — the binaries and the service file are in place.
Only PATH still needs your action: no shell config file could be written, so
add the line from the snippet above to your own shell configuration.
EOF
  fi
}

# REQ-INST-ENROLL-5: determine whether running in an interactive terminal.
# In non-interactive contexts (no TTY, CI pipelines, automated tests),
# --dry-run, or --uninstall, skip interactive prompts and fall back cleanly
# to instructions without blocking or hanging.
is_interactive() {
  if "${dry_run:-false}" || "${uninstall:-false}"; then
    return 1
  fi
  if [ "${HEIMDALL_NON_INTERACTIVE:-0}" = "1" ] || [ "${DEBIAN_FRONTEND:-}" = "noninteractive" ]; then
    return 1
  fi
  if [ "${HEIMDALL_INTERACTIVE:-0}" = "1" ] || [ "${HEIMDALL_FORCE_INTERACTIVE:-0}" = "1" ]; then
    return 0
  fi
  [ -t 0 ] && [ -t 1 ]
}

# REQ-INST-ENROLL-1 through REQ-INST-ENROLL-4: interactive onboarding ceremony.
run_interactive_onboarding() {
  say "Starting interactive onboarding and node setup..."
  echo ""

  # --- REQ-INST-ENROLL-1: Hub URL Support & Prompt ---
  if [ -z "$hub_url" ]; then
    printf 'Enter Hub URL: '
    IFS= read -r input_hub || input_hub=""
    input_hub="$(printf '%s' "$input_hub" | tr -d '[:space:]')"
    input_hub="${input_hub%/}"
    if [ -n "$input_hub" ]; then
      hub_url="$input_hub"
    else
      warn "No Hub URL provided; skipping interactive enrollment."
      print_onboarding
      return 0
    fi
  fi

  # --- REQ-INST-ENROLL-2: Bridge Token Pre-check ---
  token_file="$service_home/.config/heimdall/bridge-token"
  already_enrolled=false
  if [ -s "$token_file" ]; then
    existing_token="$(tr -d '[:space:]' < "$token_file" 2>/dev/null || true)"
    if [ -n "$existing_token" ]; then
      already_enrolled=true
      say "Found existing bridge token at $token_file; node is already enrolled."
    fi
  fi

  # --- REQ-INST-ENROLL-3: Enrollment Ceremony & Bridge Startup ---
  if ! "$already_enrolled"; then
    cat <<EOF

To enroll this node with Hub ($hub_url):
1. On the HUB, create a one-time enrollment token:
     ham-ctl bridge enroll-token --new

EOF
    printf 'Enter one-time enrollment token (hbe_...): '
    IFS= read -r enroll_token || enroll_token=""
    enroll_token="$(printf '%s' "$enroll_token" | tr -d '[:space:]')"
    if [ -z "$enroll_token" ]; then
      warn "No enrollment token provided; skipping automatic enrollment."
      print_onboarding
      return 0
    fi

    say "Enrolling node with Hub ($hub_url)..."
    enroll_bin="$install_dir/heimdall"
    if [ ! -x "$enroll_bin" ]; then
      enroll_bin="$(command -v heimdall 2>/dev/null || true)"
    fi

    enroll_ok=false
    if [ -n "$enroll_bin" ] && [ -x "$enroll_bin" ]; then
      enroll_cmd=("$enroll_bin" enroll "$enroll_token" --hub "$hub_url")
      if [ -n "$service_user" ]; then
        enroll_cmd+=(--config "$service_home/.config/heimdall/config.toml")
      fi
      if "${enroll_cmd[@]}"; then
        enroll_ok=true
      fi
    elif [ -x "$install_dir/ham-bridge" ]; then
      if "$install_dir/ham-bridge" enroll --hub "$hub_url" --enrollment-token "$enroll_token" --bridge-token-file "$token_file"; then
        enroll_ok=true
      fi
    fi

    if "$enroll_ok"; then
      say "Node successfully enrolled."
      if [ -n "$service_user" ]; then
        take_ownership "$service_home/.config/heimdall"
      fi
    else
      warn "Enrollment failed. You can retry manually with:"
      warn "  $install_dir/heimdall enroll <token> --hub $hub_url"
      print_onboarding
      return 0
    fi
  fi

  # Start registered bridge service
  say "Starting bridge service..."
  if [ "$os" = "linux" ]; then
    if [ -n "$service_user" ]; then
      say "Bridge service registered for user $service_user."
      say "Start it as $service_user: systemctl --user enable --now heimdall-bridge"
    elif command -v systemctl >/dev/null 2>&1; then
      if systemctl --user enable --now heimdall-bridge 2>/dev/null; then
        say "Bridge service started via systemctl --user."
      else
        warn "Could not start bridge service via 'systemctl --user enable --now heimdall-bridge'."
      fi
    fi
  else
    launchctl bootstrap "gui/$(id -u)" "$service_file" 2>/dev/null || launchctl load "$service_file" 2>/dev/null || true
    launchctl kickstart -k "gui/$(id -u)/works.earendil.heimdall-bridge" 2>/dev/null || true
    say "Bridge service started via launchctl."
  fi

  # Verify bridge is running and enrolled
  say "Verifying bridge service and enrollment..."
  if [ -s "$token_file" ]; then
    say "Enrollment verified: bridge token is present at $token_file."
  else
    warn "Bridge token not found at $token_file."
  fi

  if [ "$os" = "linux" ] && [ -z "$service_user" ] && command -v systemctl >/dev/null 2>&1; then
    if systemctl --user is-active heimdall-bridge >/dev/null 2>&1; then
      say "Bridge service is running (active)."
    else
      warn "Bridge service is not reporting active; check: systemctl --user status heimdall-bridge"
    fi
  elif [ "$os" = "darwin" ]; then
    if launchctl list 2>/dev/null | grep -q "works.earendil.heimdall-bridge"; then
      say "Bridge service is running (active)."
    fi
  fi

  # --- REQ-INST-ENROLL-4: Encryption & Master Password Setup ---
  echo ""
  printf 'Do you wish to enable client vault encryption? [y/N]: '
  IFS= read -r enable_vault || enable_vault=""
  case "$enable_vault" in
    [yY]|[yY][eE][sS])
      # Check whether master password setup is supported by local tooling
      vault_tool=""
      if [ -x "$install_dir/heimdall" ]; then
        vault_tool="$install_dir/heimdall"
      elif command -v heimdall >/dev/null 2>&1; then
        vault_tool="$(command -v heimdall)"
      fi

      vault_supports_master_pwd=false
      vault_help=""
      if [ -n "$vault_tool" ]; then
        vault_help="$("$vault_tool" vault --help 2>&1 || true)"
        if echo "$vault_help" | grep -iqE "master-password|setup-password|password"; then
          vault_supports_master_pwd=true
        fi
      fi

      if "$vault_supports_master_pwd"; then
        printf 'Enter master password: '
        IFS= read -s -r master_pwd || master_pwd=""
        echo ""
        printf 'Confirm master password: '
        IFS= read -s -r master_pwd_confirm || master_pwd_confirm=""
        echo ""
        if [ "$master_pwd" != "$master_pwd_confirm" ]; then
          warn "Passwords do not match; skipping vault encryption setup."
        elif [ -z "$master_pwd" ]; then
          warn "Master password cannot be empty; skipping vault encryption setup."
        else
          say "Configuring vault keys..."
          vault_cmd=()
          if echo "$vault_help" | grep -iq "master-password"; then
            vault_cmd=("$vault_tool" vault master-password)
          elif echo "$vault_help" | grep -iq "setup-password"; then
            vault_cmd=("$vault_tool" vault setup-password)
          elif echo "$vault_help" | grep -iq "set-password"; then
            vault_cmd=("$vault_tool" vault set-password)
          else
            vault_cmd=("$vault_tool" vault setup)
          fi
          if [ -n "$service_user" ]; then
            vault_cmd+=(--config "$service_home/.config/heimdall/config.toml")
          fi
          if printf '%s\n' "$master_pwd" | "${vault_cmd[@]}" 2>/dev/null; then
            say "Vault encryption successfully configured."
            if [ -n "$service_user" ]; then
              take_ownership "$service_home/.config/heimdall"
            fi
          else
            warn "Failed to configure vault key via local tooling."
          fi
        fi
      else
        say "Master password setup is not currently supported by local tooling (heimdall vault); client vault encryption was not configured."
      fi
      ;;
    *)
      say "Client vault encryption skipped."
      ;;
  esac

  echo ""
  say "Onboarding complete."
  if "${path_needs_action:-false}"; then
    cat <<EOF

NOTE: the install SUCCEEDED — the binaries and the service file are in place.
Only PATH still needs your action: no shell config file could be written, so
add the line from the snippet above to your own shell configuration.
EOF
  fi
}

# REQ-INST-3: under `curl | sudo bash` the binaries go to /usr/local/bin, but
# the service file and PATH rc lines must land in the invoking user's home (the
# session that will actually run `systemctl --user`), owned by that user.
# Non-fatal by design (aborting mid-install would be worse), but a failed chown
# is always surfaced: root-owned files under the user's config are exactly the
# split-ownership outcome this requirement exists to prevent. No-op for normal
# (non-sudo) runs.
take_ownership() {
  if [ -n "$service_user" ]; then
    for target in "$@"; do
      if ! chown "$service_user:" "$target" 2>/dev/null; then
        warn "could not chown $target to $service_user — run 'chown $service_user: $target' before starting the service"
      fi
    done
  fi
}

# --- PATH wiring (REQ-INST-5, REQ-INST-12) -------------------------------------
# Candidates are keyed to the target user's shell so we never create a config
# for a shell they do not use. Existing files are preferred; when none exists
# the primary rc for their shell is created (the historical ~/.bashrc default
# when the shell is unknown). macOS login shells read ~/.zprofile /
# ~/.bash_profile rather than the interactive rcs, and fish reads
# ~/.config/fish/config.fish.
path_candidates() {
  case "${service_shell:-${SHELL:-}}" in
    *fish*) printf '%s\n' "$service_home/.config/fish/config.fish" ;;
    *zsh*)  printf '%s\n' "$service_home/.zshrc" "$service_home/.zprofile" ;;
    *bash*) printf '%s\n' "$service_home/.bashrc" "$service_home/.bash_profile" ;;
    *)      printf '%s\n' "$service_home/.bashrc" "$service_home/.zshrc" \
                         "$service_home/.bash_profile" "$service_home/.zprofile" \
                         "$service_home/.profile" ;;
  esac
}

# The block printed when an rc file could not be written. Three labelled,
# copy-pasteable forms — plain POSIX shells, home-manager (NixOS rc files are
# read-only store symlinks, the motivating case: edit home.nix, not ~/.bashrc),
# and fish — so the right one is unambiguous.
path_snippet() {
  cat <<EOF

  ------------------------------------------------------------------------
  Could not update your shell configuration automatically. Add ONE of these
  — whichever matches your setup — then open a new shell:

    bash / zsh (~/.bashrc, ~/.bash_profile, ~/.zshrc, ~/.zprofile):
      export PATH="$install_dir:\$PATH"

    NixOS / home-manager (the rc files are read-only store symlinks — put
    this in home.nix instead, then rebuild and re-login):
      home.sessionPath = [ "$install_dir" ];
    (equivalently: home.sessionVariables.PATH = "$install_dir:\$PATH";)

    fish (~/.config/fish/config.fish):
      fish_add_path "$install_dir"
  ------------------------------------------------------------------------
EOF
}

# REQ-INST-5: PATH wiring must NEVER be fatal. On NixOS / home-manager (or any
# immutable-dotfile setup) the rc files are read-only, so a failed append is
# the NORMAL case there — the old bare `printf >> "$rc"` under set -euo
# pipefail aborted mid-install, after the binaries but before the service
# file. Every write is guarded: a writability pre-check catches the common
# case and the tolerated append failure covers TOCTOU and read-only stores
# where access(2) still reports writable (e.g. root). Outcomes are
# distinguished in the output: added / already present / could-not-write (the
# file is named, the snippet is printed, and the install carries on). Sets
# path_needs_action=true when no rc file carries the line so the final
# summary can say the install succeeded and only PATH remains.
wire_path() {
  case "${service_shell:-${SHELL:-}}" in
    *fish*) path_line="fish_add_path \"$install_dir\"" ;;
    *)      path_line="export PATH=\"$install_dir:\$PATH\"" ;;
  esac

  # REQ-INST-3: the process PATH is consulted ONLY for a normal (non-sudo)
  # install; under sudo it is root's PATH and the decision must come from the
  # target user's rc files below.
  if [ -z "$service_user" ]; then
    case ":$PATH:" in
      *":$install_dir:"*)
        say "$install_dir is already on PATH"
        return 0 ;;
    esac
  fi

  handled=false    # at least one rc file carries the PATH line
  write_failed=false
  while IFS= read -r rc; do
    [ -e "$rc" ] || continue
    if grep -Fqx "$path_line" "$rc" 2>/dev/null; then
      say "$rc already adds $install_dir to PATH"
      handled=true
      continue
    fi
    if [ -w "$rc" ] && printf '\n# Added by heimdall install.sh\n%s\n' "$path_line" >> "$rc" 2>/dev/null; then
      say "added $install_dir to PATH in $rc"
      take_ownership "$rc"
      handled=true
    else
      warn "could not write $rc (read-only? managed by Nix/home-manager?)"
      write_failed=true
    fi
  done <<EOF
$(path_candidates)
EOF

  if ! "$handled"; then
    # No existing rc file took the line: create the primary rc for the user's
    # shell. Also non-fatal — a read-only $HOME lands here.
    rc="$(path_candidates | head -n 1)"
    if [ -e "$rc" ]; then
      # The primary rc exists but was unwritable (already warned above).
      :
    elif { [ -d "$(dirname "$rc")" ] || mkdir -p "$(dirname "$rc")" 2>/dev/null; } \
         && printf '\n# Added by heimdall install.sh\n%s\n' "$path_line" >> "$rc" 2>/dev/null; then
      say "created $rc adding $install_dir to PATH"
      take_ownership "$rc"
      handled=true
    else
      warn "could not create $rc (read-only home directory?)"
      write_failed=true
    fi
  fi

  if "$write_failed" || ! "$handled"; then
    path_snippet
  fi
  if "$handled"; then
    if "$write_failed"; then
      say "PATH was partially updated — apply the snippet above to the shell(s) that could not be written"
    else
      say "open a new shell (or 'source' the rc file) so PATH picks up $install_dir"
    fi
  else
    path_needs_action=true
  fi
}

# Removes one file this installer wrote, honouring --dry-run. Reports exactly
# one outcome: a failed rm warns instead of also claiming the removal happened.
remove_installed() {
  if "$dry_run"; then
    say "would remove $1"
  elif rm -f "$1" 2>/dev/null; then
    say "removed $1"
  else
    warn "could not remove $1; delete it by hand"
  fi
}

# --- uninstall (REQ-INST-8) -----------------------------------------------------
# Reverses the install: stops the service (best effort), removes the binaries
# this installer placed, the service file, and the PATH lines added under the
# installer marker — and nothing else. Enrollment state under
# ~/.config/heimdall (bridge token, config.toml) is deliberately kept.
do_uninstall() {
  # 1. Stop the service first, best effort. Under sudo the service belongs to
  # $service_user's session, so the command is PRINTED for them rather than run
  # as root — that advice touches nothing, so it is given in dry runs too.
  # REQ-INST-20: BOTH platforms honour that, and darwin has to be told to. `id
  # -u` is 0 under sudo, so a root-run `launchctl bootout gui/$(id -u)/...`
  # addresses ROOT's GUI domain and stops nothing of $service_user's — while
  # still reporting "stopped ...". The advice therefore carries a literal
  # gui/$(id -u), resolved in their shell to their own uid, which is exactly
  # what the step-3 start instructions hand them. Without sudo `id -u` IS the
  # invoking user, so the real-stop path below is unchanged and correct.
  if [ "$os" = "linux" ]; then
    if [ -n "$service_user" ]; then
      say "service runs as $service_user — stop it as that user: systemctl --user stop heimdall-bridge"
    elif "$dry_run"; then
      say "would stop the heimdall-bridge service (best effort)"
    elif command -v systemctl >/dev/null 2>&1; then
      systemctl --user stop heimdall-bridge >/dev/null 2>&1 || true
      say "stopped heimdall-bridge (best effort)"
    fi
  else
    if [ -n "$service_user" ]; then
      say "service runs as $service_user — stop it as that user: launchctl bootout gui/\$(id -u)/works.earendil.heimdall-bridge"
    elif "$dry_run"; then
      say "would stop the heimdall-bridge service (best effort)"
    elif command -v launchctl >/dev/null 2>&1; then
      launchctl bootout "gui/$(id -u)/works.earendil.heimdall-bridge" >/dev/null 2>&1 || true
      say "stopped works.earendil.heimdall-bridge (best effort)"
    fi
  fi

  # 2. Binaries. These names are ours alone, so their presence at
  # $install_dir is itself proof this installer wrote them — no content check is
  # needed or wanted here.
  for b in heimdall ham-bridge ham-pty-host ham-ctl telegraf; do
    target="$install_dir/$b"
    [ -f "$target" ] || continue
    remove_installed "$target"
  done

  # 3. Service file.
  if [ -e "$service_file" ]; then
    if "$dry_run"; then
      say "would remove service file $service_file"
    elif rm -f "$service_file" 2>/dev/null; then
      say "removed service file $service_file"
    else
      warn "could not remove $service_file; delete it by hand"
    fi
  fi

  # 4. PATH lines: remove ONLY the installer marker line and the heimdall
  # PATH line immediately after it (matched against this install_dir, so a
  # line for a different install dir or an unrelated export is untouched).
  # The rewrite goes through a temp file and back into the same inode so the
  # rc file keeps its owner and mode.
  while IFS= read -r rc; do
    [ -e "$rc" ] || continue
    tmp="$(mktemp)"
    if awk -v export_line="export PATH=\"$install_dir:\$PATH\"" \
           -v fish_line="fish_add_path \"$install_dir\"" '
        $0 == "# Added by heimdall install.sh" { pending = 1; changed = 1; next }
        pending == 1 {
          pending = 0
          if ($0 == export_line || $0 == fish_line) next
          print
          next
        }
        { print }
        END { exit (changed ? 0 : 1) }
      ' "$rc" > "$tmp"; then
      if "$dry_run"; then
        say "would remove the heimdall PATH lines from $rc"
        rm -f "$tmp"
      else
        cat "$tmp" > "$rc" || warn "could not rewrite $rc; remove the heimdall lines by hand"
        rm -f "$tmp"
        say "removed heimdall PATH lines from $rc"
      fi
    else
      rm -f "$tmp"
    fi
  done <<EOF
$(path_candidates)
EOF

  # 5. What is deliberately KEPT. Both of these are the user's own state, not
  # installer debris, and deleting either is irreversible:
  #   - ~/.config/heimdall holds the bridge token and config.toml (enrollment).
  #   - $service_file.bak-* exist only because the user once had a differing,
  #     hand-tuned unit that an install replaced — recovery artifacts. Removing
  #     the evidence of a working configuration during an uninstall is the one
  #     unrecoverable mistake available here, so we name them instead.
  say "kept enrollment state at $service_home/.config/heimdall (bridge token, config.toml) — remove it by hand only if you really want it gone: rm -rf $service_home/.config/heimdall"
  kept_backups=false
  for backup in "$service_file".bak-*; do
    [ -e "$backup" ] || continue
    kept_backups=true
    say "kept service file backup $backup"
  done
  if "$kept_backups"; then
    say "those backups hold service files you had before an install replaced them — remove them by hand if unwanted: rm -f $service_file.bak-*"
  fi
  if "$dry_run"; then
    say "dry run: nothing was removed"
  else
    say "uninstall complete"
  fi
}

extract_json_val() {
  local json_file="$1"
  local key="$2"
  if [ -f "$json_file" ]; then
    sed -n -E "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"([^\"]+)\".*/\1/p" "$json_file" | head -n 1
  fi
}

do_update() {
  local check_only="${1:-false}"
  local bundle_arg="${2:-}"
  local hub_url_arg="${3:-}"
  local force="${4:-false}"

  local data_dir="${HEIMDALL_DATA_DIR:-$HOME/.local/share/heimdall}"
  local bin_dir="$data_dir/bin"
  local lib_dir="$data_dir/lib"
  local share_dir="$data_dir/share"
  local local_bin="$HOME/.local/bin"

  echo "========================================================"
  echo "         Heimdall Cloudtop Update Manager"
  echo "========================================================"

  # 1. Read current installed metadata
  local current_version=""
  local current_commit=""
  local current_built=""

  if [ -f "$data_dir/METADATA.json" ]; then
    current_version="$(extract_json_val "$data_dir/METADATA.json" "version")"
    current_commit="$(extract_json_val "$data_dir/METADATA.json" "commit")"
    if [ -z "$current_commit" ]; then
      current_commit="$(extract_json_val "$data_dir/METADATA.json" "commit_sha")"
    fi
    current_built="$(extract_json_val "$data_dir/METADATA.json" "built_at")"
  fi

  if [ -z "$current_version" ] && [ -x "$bin_dir/ham-bridge" ]; then
    current_version="$("$bin_dir/ham-bridge" --version 2>/dev/null | awk '{print $2}' || true)"
  fi
  if [ -z "$current_version" ]; then
    current_version="unknown"
  fi
  if [ -z "$current_commit" ]; then
    current_commit="unknown"
  fi

  # 2. Determine Hub URL
  local resolved_hub_url="$hub_url_arg"
  if [ -z "$resolved_hub_url" ]; then
    if [ -f "$data_dir/standalone.env" ]; then
      # shellcheck source=/dev/null
      source "$data_dir/standalone.env" 2>/dev/null || true
      resolved_hub_url="${HEIMDALL_HUB_URL:-}"
    fi
    resolved_hub_url="${resolved_hub_url:-http://127.0.0.1:8989}"
  fi
  resolved_hub_url="$(echo "$resolved_hub_url" | sed -e "s/^[[:space:]]*//" -e "s/[[:space:]]*$//" -e "s:/*$::")"

  # 3. Determine latest available version from manifest or bundle
  local latest_version=""
  local latest_commit=""
  local latest_built=""

  if [ -n "$bundle_arg" ]; then
    if [ -f "$bundle_arg" ]; then
      latest_version="$(tar -zxOf "$bundle_arg" METADATA.json 2>/dev/null | sed -n -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' || true)"
      if [ -z "$latest_version" ]; then
        latest_version="$(tar -zxOf "$bundle_arg" heimdall-cloudtop/METADATA.json 2>/dev/null | sed -n -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' || true)"
      fi
      latest_commit="$(tar -zxOf "$bundle_arg" METADATA.json 2>/dev/null | sed -n -E 's/.*"commit"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' || true)"
      if [ -z "$latest_commit" ]; then
        latest_commit="$(tar -zxOf "$bundle_arg" METADATA.json 2>/dev/null | sed -n -E 's/.*"commit_sha"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' || true)"
      fi
      if [ -z "$latest_commit" ]; then
        latest_commit="$(tar -zxOf "$bundle_arg" heimdall-cloudtop/METADATA.json 2>/dev/null | sed -n -E 's/.*"commit"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' || true)"
      fi
      if [ -z "$latest_commit" ]; then
        latest_commit="$(tar -zxOf "$bundle_arg" heimdall-cloudtop/METADATA.json 2>/dev/null | sed -n -E 's/.*"commit_sha"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' || true)"
      fi
    elif [ -d "$bundle_arg" ] && [ -f "$bundle_arg/METADATA.json" ]; then
      latest_version="$(extract_json_val "$bundle_arg/METADATA.json" "version")"
      latest_commit="$(extract_json_val "$bundle_arg/METADATA.json" "commit")"
      if [ -z "$latest_commit" ]; then
        latest_commit="$(extract_json_val "$bundle_arg/METADATA.json" "commit_sha")"
      fi
      latest_built="$(extract_json_val "$bundle_arg/METADATA.json" "built_at")"
    fi
  else
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local root_dir
    root_dir="$(cd "$script_dir/.." && pwd)"
    if [ -f "$root_dir/dist/manifest.json" ]; then
      latest_version="$(extract_json_val "$root_dir/dist/manifest.json" "version")"
      latest_commit="$(extract_json_val "$root_dir/dist/manifest.json" "commit_sha")"
      latest_built="$(extract_json_val "$root_dir/dist/manifest.json" "built_at")"
    elif [ -f "$root_dir/dist/heimdall-cloudtop/METADATA.json" ]; then
      latest_version="$(extract_json_val "$root_dir/dist/heimdall-cloudtop/METADATA.json" "version")"
      latest_commit="$(extract_json_val "$root_dir/dist/heimdall-cloudtop/METADATA.json" "commit")"
      if [ -z "$latest_commit" ]; then
        latest_commit="$(extract_json_val "$root_dir/dist/heimdall-cloudtop/METADATA.json" "commit_sha")"
      fi
      latest_built="$(extract_json_val "$root_dir/dist/heimdall-cloudtop/METADATA.json" "built_at")"
    else
      local manifest_raw
      manifest_raw="$(curl -s --connect-timeout 3 "$resolved_hub_url/api/v1/updates/manifest.json" 2>/dev/null || true)"
      if [ -n "$manifest_raw" ]; then
        latest_version="$(echo "$manifest_raw" | sed -n -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -n 1)"
        latest_commit="$(echo "$manifest_raw" | sed -n -E 's/.*"commit_sha"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -n 1)"
        latest_built="$(echo "$manifest_raw" | sed -n -E 's/.*"built_at"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -n 1)"
      fi
    fi
    if [ -z "$latest_version" ] && [ -f "$root_dir/package.json" ]; then
      latest_version="$(extract_json_val "$root_dir/package.json" "version")"
      if [ -d "$root_dir/.git" ] && command -v git >/dev/null 2>&1; then
        latest_commit="$(git -C "$root_dir" rev-parse --short HEAD 2>/dev/null || true)"
      fi
    fi
  fi

  latest_version="${latest_version:-unknown}"
  latest_commit="${latest_commit:-unknown}"

  # 4. Handle --check mode
  if [ "$check_only" = true ]; then
    echo ""
    echo "  Current Installed Version: $current_version ($current_commit)"
    echo "  Latest Available Version:  $latest_version ($latest_commit)"
    echo ""
    if [ "$latest_version" != "unknown" ] && { [ "$current_version" != "$latest_version" ] || [ "$current_commit" != "$latest_commit" ]; }; then
      echo "  Status: Update available! Run './install.sh --update' to apply."
    else
      echo "  Status: Heimdall is up to date."
    fi
    echo "========================================================"
    return 0
  fi

  # 5. Locate or download bundle for update
  local stage_dir="$data_dir/updates/stage"
  rm -rf "$stage_dir"
  mkdir -p "$stage_dir"

  local target_arch
  target_arch="$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m | tr '[:upper:]' '[:lower:]' | sed 's/x86_64/amd64/' | sed 's/aarch64/arm64/')"

  if [ -n "$bundle_arg" ]; then
    if [[ "$bundle_arg" =~ ^https?:// ]]; then
      echo "[update] Downloading update bundle from $bundle_arg..."
      curl -f -L --progress-bar "$bundle_arg" -o "$stage_dir/bundle.tar.gz" || {
        echo "[-] Error: Failed to download update bundle from $bundle_arg" >&2
        rm -rf "$stage_dir"
        return 1
      }
      tar -xzf "$stage_dir/bundle.tar.gz" -C "$stage_dir"
    elif [ -f "$bundle_arg" ]; then
      echo "[update] Extracting update bundle from $bundle_arg..."
      tar -xzf "$bundle_arg" -C "$stage_dir"
    elif [ -d "$bundle_arg" ]; then
      echo "[update] Using update bundle from directory $bundle_arg..."
      cp -R -p "$bundle_arg/"* "$stage_dir/"
    else
      echo "[-] Error: Specified bundle $bundle_arg not found." >&2
      rm -rf "$stage_dir"
      return 1
    fi
  else
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local root_dir
    root_dir="$(cd "$script_dir/.." && pwd)"
    if [ -d "$root_dir/dist/heimdall-cloudtop/bin" ]; then
      echo "[update] Using local build at $root_dir/dist/heimdall-cloudtop..."
      cp -R -p "$root_dir/dist/heimdall-cloudtop/"* "$stage_dir/"
    elif [ -f "$root_dir/dist/heimdall-cloudtop-bundle.tar.gz" ]; then
      echo "[update] Extracting local archive $root_dir/dist/heimdall-cloudtop-bundle.tar.gz..."
      tar -xzf "$root_dir/dist/heimdall-cloudtop-bundle.tar.gz" -C "$stage_dir"
    elif [ -f "$root_dir/scripts/package-cloudtop-bundle.sh" ]; then
      echo "[update] Packaging fresh standalone bundle..."
      "$root_dir/scripts/package-cloudtop-bundle.sh"
      cp -R -p "$root_dir/dist/heimdall-cloudtop/"* "$stage_dir/"
    else
      local bundle_url="$resolved_hub_url/api/v1/updates/bundle/heimdall-local-${target_arch}.tar.gz"
      echo "[update] Downloading bundle from Central Hub at $bundle_url..."
      if curl -f -s -L "$bundle_url" -o "$stage_dir/bundle.tar.gz" 2>/dev/null; then
        tar -xzf "$stage_dir/bundle.tar.gz" -C "$stage_dir"
      else
        echo "[-] Error: Could not locate local bundle or download bundle from Central Hub ($bundle_url)." >&2
        rm -rf "$stage_dir"
        return 1
      fi
    fi
  fi

  # 6. Locate staged binaries
  local update_bin=""
  local update_root=""
  if [ -d "$stage_dir/bin" ]; then
    update_bin="$stage_dir/bin"
    update_root="$stage_dir"
  elif [ -d "$stage_dir/heimdall-cloudtop/bin" ]; then
    update_bin="$stage_dir/heimdall-cloudtop/bin"
    update_root="$stage_dir/heimdall-cloudtop"
  elif [ -f "$stage_dir/ham-bridge" ]; then
    update_bin="$stage_dir"
    update_root="$stage_dir"
  fi

  if [ -z "$update_bin" ] || [ ! -d "$update_bin" ]; then
    echo "[-] Error: Staged update does not contain valid binaries." >&2
    rm -rf "$stage_dir"
    return 1
  fi

  # In-situ binary preflight check
  if [ -f "$update_bin/ham-bridge" ]; then
    echo "[update] Preflight verifying new bridge binary ($update_bin/ham-bridge --version)..."
    chmod +x "$update_bin/ham-bridge"
    "$update_bin/ham-bridge" --version >/dev/null 2>&1 || {
      echo "[-] Error: New ham-bridge binary failed preflight execution check." >&2
      rm -rf "$stage_dir"
      return 1
    }
  fi

  # 7. Backup current binaries to bin.bak
  echo "[update] Backing up current binaries to $data_dir/bin.bak..."
  rm -rf "$data_dir/bin.bak"
  if [ -d "$bin_dir" ]; then
    cp -R -p "$bin_dir" "$data_dir/bin.bak"
  fi

  # 8. Atomically swap binaries
  echo "[update] Atomically replacing binaries in $bin_dir..."
  rm -rf "$data_dir/bin.new"
  mkdir -p "$data_dir/bin.new"
  cp -R -p "$update_bin/"* "$data_dir/bin.new/"
  chmod u+w "$data_dir/bin.new/"* 2>/dev/null || true
  chmod +x "$data_dir/bin.new/"*

  rm -rf "$data_dir/bin.old"
  if [ -d "$bin_dir" ]; then
    mv "$bin_dir" "$data_dir/bin.old"
  fi
  mv "$data_dir/bin.new" "$bin_dir"
  rm -rf "$data_dir/bin.old"

  # 9. Update supporting runtime components
  if [ -d "$update_root/lib" ]; then
    echo "[update] Updating runtime libraries in $lib_dir..."
    mkdir -p "$lib_dir"
    cp -R -p "$update_root/lib/"* "$lib_dir/" 2>/dev/null || true
    chmod -R u+w "$lib_dir/" 2>/dev/null || true
  fi

  if [ -d "$update_root/share/migrations" ]; then
    echo "[update] Updating database migrations in $share_dir..."
    mkdir -p "$share_dir"
    cp -R -p "$update_root/share/migrations/"* "$share_dir/"
  fi

  if [ -d "$update_root/ui" ] && [ -f "$update_root/ui/index.html" ]; then
    echo "[update] Updating static UI assets..."
    mkdir -p "$data_dir/ui"
    cp -R -p "$update_root/ui/"* "$data_dir/ui/"
  fi

  if [ -f "$update_root/METADATA.json" ]; then
    cp "$update_root/METADATA.json" "$data_dir/METADATA.json"
  fi

  if [ -f "$update_root/start.sh" ]; then
    cp "$update_root/start.sh" "$bin_dir/start.sh"
    cp "$update_root/start.sh" "$data_dir/start.sh"
    chmod +x "$bin_dir/start.sh" "$data_dir/start.sh"
  fi
  if [ -f "$update_root/stop.sh" ]; then
    cp "$update_root/stop.sh" "$bin_dir/stop.sh"
    cp "$update_root/stop.sh" "$data_dir/stop.sh"
    chmod +x "$bin_dir/stop.sh" "$data_dir/stop.sh"
  fi
  if [ -f "$update_root/scripts/apply-bridge-update.sh" ]; then
    mkdir -p "$data_dir/scripts"
    cp "$update_root/scripts/apply-bridge-update.sh" "$data_dir/scripts/apply-bridge-update.sh"
    chmod +x "$data_dir/scripts/apply-bridge-update.sh"
  fi

  # Symlink CLI
  mkdir -p "$local_bin"
  if [ -f "$bin_dir/ham-ctl" ]; then
    ln -sf "$bin_dir/ham-ctl" "$local_bin/ham-ctl"
  fi

  # Clean up staging
  rm -rf "$stage_dir"

  # 10. Restart service
  echo "[update] Restarting Heimdall service..."
  if command -v systemctl >/dev/null 2>&1 && [ -f "$HOME/.config/systemd/user/heimdall.service" ]; then
    echo "[update] Reloading systemd user daemon and restarting heimdall.service..."
    systemctl --user daemon-reload || true
    systemctl --user restart heimdall.service || systemctl --user start heimdall.service || true
  elif [ -f "$data_dir/start.sh" ]; then
    if [ -f "$data_dir/standalone.env" ]; then
      "$data_dir/start.sh" --standalone ${force:+--force} &
    else
      "$data_dir/start.sh" ${force:+--force} &
    fi
  fi

  # 11. Health check verification
  local probe_port="${HEIMDALL_PROBE_PORT:-8989}"
  if [ -f "$data_dir/standalone.env" ]; then
    source "$data_dir/standalone.env" 2>/dev/null || true
    probe_port="${HEIMDALL_PROBE_PORT:-${HEIMDALL_BRIDGE_PORT:-49323}}"
  fi

  local health_ok=false
  if [ "${HEIMDALL_SKIP_HEALTH_CHECK:-false}" = "true" ]; then
    echo "[update] Health check probe skipped (HEIMDALL_SKIP_HEALTH_CHECK=true)."
    health_ok=true
  else
    echo "[update] Verifying service health on port $probe_port..."
    local deadline=$((SECONDS + 15))
    while [ $SECONDS -lt $deadline ]; do
      if curl -s "http://127.0.0.1:$probe_port/api/v1/health" >/dev/null 2>&1 || curl -s -I "http://127.0.0.1:$probe_port/" >/dev/null 2>&1; then
        health_ok=true
        break
      fi
      sleep 0.5
    done
  fi

  if [ "$health_ok" = true ]; then
    echo "[update] Service health check verified on port $probe_port."
    rm -rf "$data_dir/bin.bak"
  else
    echo "[-] Warning: Health check did not respond on port $probe_port within 15s."
    if [ -d "$data_dir/bin.bak" ]; then
      echo "[-] Backup binaries preserved at $data_dir/bin.bak."
    fi
  fi

  local updated_ver
  updated_ver="$(extract_json_val "$data_dir/METADATA.json" "version")"
  local updated_commit
  updated_commit="$(extract_json_val "$data_dir/METADATA.json" "commit")"
  if [ -z "$updated_commit" ]; then
    updated_commit="$(extract_json_val "$data_dir/METADATA.json" "commit_sha")"
  fi

  echo ""
  echo "========================================================"
  echo "    Heimdall Successfully Updated!"
  echo "========================================================"
  echo "  Previous Version: $current_version ($current_commit)"
  echo "  Updated Version:  ${updated_ver:-$current_version} (${updated_commit:-$current_commit})"
  echo "  Binaries:         $bin_dir"
  echo "========================================================"
  return 0
}

main() {
  set -euo pipefail
  version=""
  hub_url=""
  dry_run=false
  force_service=false
  force=false
  update_mode=false
  check_only=false
  bundle_arg=""
  uninstall=false
  # Set by wire_path when no rc file ended up carrying the PATH line, so the
  # final summary can say the install itself succeeded (REQ-INST-5).
  path_needs_action=false
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --version)
        [ "$#" -ge 2 ] || fail "--version requires a value (e.g. v0.1.0)"
        version="$2"; shift 2 ;;
      --hub|--hub-url)
        [ "$#" -ge 2 ] || fail "--hub requires a url"
        hub_url="${2%/}"; shift 2 ;;
      --dry-run) dry_run=true; shift ;;
      --force-service) force_service=true; shift ;;
      --force|-f) force=true; force_service=true; shift ;;
      --update|--apply-update) update_mode=true; shift ;;
      --check) check_only=true; update_mode=true; shift ;;
      --bundle)
        [ "$#" -ge 2 ] || fail "--bundle requires a path or url"
        bundle_arg="$2"; update_mode=true; shift 2 ;;
      --uninstall) uninstall=true; shift ;;
      --help|-h) usage; exit 0 ;;
      *) usage; fail "unknown argument: $1" ;;
    esac
  done

  if [ "$update_mode" = true ]; then
    do_update "$check_only" "$bundle_arg" "$hub_url" "$force"
    exit 0
  fi

  # --- platform detection -----------------------------------------------------
  uname_s="$(uname -s)"
  uname_m="$(uname -m)"
  case "$uname_m" in
    x86_64|amd64) arch="amd64" ;;
    arm64|aarch64) arch="arm64" ;;
    *) fail "unsupported architecture '$uname_m' (need x86_64 or arm64/aarch64)" ;;
  esac
  case "$uname_s" in
    Linux) os="linux" ;;
    Darwin) os="darwin" ;;
    *) fail "unsupported operating system '$uname_s' (need Linux or macOS)" ;;
  esac
  target="$os-$arch"

  # --- install dir + service owner (REQ-INST-3) --------------------------------
  service_user=""
  service_home=""
  service_shell=""
  if [ "$(id -u)" -eq 0 ]; then
    install_dir="/usr/local/bin"
    sudo_target="${SUDO_USER:-}"
    if [ -z "$sudo_target" ] || [ "$sudo_target" = "root" ]; then
      fail "refusing to run as root: SUDO_USER is '${sudo_target:-unset}', so the service file and PATH lines would be written under /root where no user session exists. Re-run without sudo — ~/.local/bin needs no root."
    fi
    service_user="$sudo_target"
    if [ "$os" = "linux" ]; then
      passwd_entry="$(getent passwd "$service_user" 2>/dev/null || true)"
      if [ -n "$passwd_entry" ]; then
        service_home="$(printf '%s' "$passwd_entry" | cut -d: -f6)"
        service_shell="$(printf '%s' "$passwd_entry" | cut -d: -f7)"
      fi
    else
      service_home="$(dscl . -read "/Users/$service_user" NFSHomeDirectory 2>/dev/null | cut -d' ' -f2- || true)"
      service_shell="$(dscl . -read "/Users/$service_user" UserShell 2>/dev/null | cut -d' ' -f2- || true)"
    fi
    if [ -z "$service_home" ] || [ ! -d "$service_home" ]; then
      fail "could not resolve the home directory of SUDO_USER '$service_user' (got '${service_home:-nothing}'). Re-run without sudo — ~/.local/bin needs no root."
    fi
  else
    install_dir="$HOME/.local/bin"
    service_home="$HOME"
  fi

  # --- service file location ----------------------------------------------------
  # Resolved before the release lookup so --uninstall needs no network and no
  # release tag: it only ever touches paths, never a download.
  if [ "$os" = "linux" ]; then
    service_dir="$service_home/.config/systemd/user"
    service_file="$service_dir/heimdall-bridge.service"
  else
    service_dir="$service_home/Library/LaunchAgents"
    service_file="$service_dir/works.earendil.heimdall-bridge.plist"
  fi

  # --- uninstall (REQ-INST-8) ---------------------------------------------------
  if "$uninstall"; then
    do_uninstall
    exit 0
  fi

  # --- REQ-INST-23: never silently shadow a system-managed unit -----------------
  # A unit in ~/.config/systemd/user takes PRECEDENCE over the same name in the
  # system unit directories. Writing ours there on a host that already has a
  # system-managed heimdall-bridge.service does not fail, does not warn, and does
  # not even disturb the running bridge -- a running process keeps the argv it
  # started with. The damage appears only at the NEXT restart, which silently
  # starts our unit instead of the machine's. On 2026-09-27 that left a host
  # unable to restart its own production bridge, undetected, for six hours; it
  # surfaced as a ~20 minute outage when something finally stopped it.
  #
  # Detected by PATH, not by 'systemctl --user cat': a path check needs no session
  # bus (so it works under sudo, in containers, and inside the test sandbox -- see
  # REQ-INST-13), and 'cat' resolves the EFFECTIVE unit, which after our own
  # previous install is OUR user unit -- so it could not tell "the system provides
  # one" from "we installed one" and would fire on an idempotent re-run.
  #
  # Scanned on Linux only. launchd precedence is NOT systemd's: both
  # ~/Library/LaunchAgents and /Library/LaunchAgents load and a duplicate LABEL is
  # a CONFLICT rather than a silent override, so the failure mode differs and
  # nobody has executed it on a Mac. Deliberately not asserted here.
  #
  # This check must stay BELOW the --uninstall exit above: removing our own files
  # is never blocked by the machine having its own unit.
  system_unit=""
  if [ "$os" = "linux" ]; then
    for _unit_dir in $(system_unit_dirs); do
      if [ -e "$_unit_dir/heimdall-bridge.service" ]; then
        system_unit="$_unit_dir/heimdall-bridge.service"
        break
      fi
    done
  fi

  # --- socat preflight (REQ-INST-14) --------------------------------------------
  # Placed here deliberately: AFTER the --uninstall exit above, because removing
  # files needs no transport and refusing to uninstall over a missing dependency
  # would strand users; and BEFORE release resolution, so when this fires
  # nothing has been downloaded, no network has been touched and no file
  # written. Same shape as the sudo/home preflight higher up -- fail before we
  # touch the system, never halfway through it.
  socat_missing=false
  socat_exempt_reason=""
  if ! have_socat; then
    socat_missing=true
    if hub_is_plaintext "$hub_url"; then
      socat_exempt_reason="--hub $hub_url is plain HTTP, so the bridge terminates no TLS and needs no socat"
    fi
  fi
  if "$socat_missing"; then
    if [ -n "$socat_exempt_reason" ]; then
      warn "socat is not installed; continuing because $socat_exempt_reason. Install socat before pointing this bridge at an https:// or wss:// hub."
    elif ! "$dry_run"; then
      # A dry run is exempt: it writes nothing and its job is to PREVIEW, so it
      # reports the missing socat in the plan below and still exits 0.
      fail "$(socat_required_message)"
    fi
  fi

  # --- release URL resolution -------------------------------------------------
  if [ -n "$hub_url" ]; then
    base_url="$hub_url"
    tarball_name="heimdall-local-$target.tar.gz"
    effective_version="${version:-custom-hub-release}"
  elif [ -n "$version" ]; then
    base_url="https://github.com/$GITHUB_REPO/releases/download/$version"
    tarball_name="heimdall-local-$target-$version.tar.gz"
    effective_version="$version"
  else
    # resolve_latest_tag reports through GLOBALS, not stdout. Calling it as
    # `effective_version="$(resolve_latest_tag)"` would run it in a SUBSHELL and
    # throw $resolve_error away -- the diagnosis is the entire point of REQ-INST-6,
    # so it must not be discarded at the call site.
    if resolve_latest_tag; then
      effective_version="$resolved_tag"
      # An if-block, not `[ -n ... ] && warn ...`: a failing test in a bare &&
      # list is itself a `set -e` abort. Same trap that cost T2 a round.
      if [ -n "$resolve_notice" ]; then
        warn "$resolve_notice"
      fi
    elif "$dry_run"; then
      # A dry run must stay usable on an offline machine, so a failed lookup is
      # NOT fatal here. It is still REPORTED, which it previously was not: the
      # old `|| true` swallowed the cause and printed a plan whose download URLs
      # silently contained an empty version, hiding the one fact the user needed.
      warn "$resolve_error"
      warn "continuing the dry run with a placeholder version: the download URLs below are illustrative, not the ones a real run would use"
      effective_version="<latest-release-tag>"
    else
      fail "$resolve_error"
    fi
    base_url="https://github.com/$GITHUB_REPO/releases/download/$effective_version"
    tarball_name="heimdall-local-$target-$effective_version.tar.gz"
  fi
  sums_name="SHA256SUMS"
  tarball_url="$base_url/$tarball_name"
  sums_url="$base_url/$sums_name"
  telegraf_url="https://dl.influxdata.com/telegraf/releases/telegraf-${TELEGRAF_VERSION}_${os}_${arch}.tar.gz"

  # --- dry run ------------------------------------------------------------------
  if "$dry_run"; then
    # REQ-INST-14: a preview must tell the truth about what a real run would do,
    # and what a real run would do here is STOP. The headline goes on stdout,
    # inside the plan the operator is actually reading, ahead of everything
    # else, so it cannot be read as a footnote; the detail follows on stderr.
    if "$socat_missing" && [ -z "$socat_exempt_reason" ]; then
      say "socat is NOT installed: a real (non-dry-run) install would STOP HERE and install nothing"
      socat_required_message >&2
    fi
    say "platform: $os/$arch (release target $target)"
    say "release: $effective_version"
    say "would download: $tarball_url"
    say "would download: $sums_url"
    say "would download telegraf from $telegraf_url"
    say "would verify SHA-256 of $tarball_name against SHA256SUMS before extracting"
    say "would install bin/heimdall bin/ham-bridge bin/ham-pty-host bin/ham-ctl to $install_dir"
    say "would install $install_dir/telegraf"
    if [ -n "$service_user" ]; then
      say "sudo detected: binaries go to $install_dir; the service file and PATH lines will be written for user $service_user (home: $service_home)"
      say "would add $install_dir to PATH in $service_home/.bashrc / .zshrc as needed (idempotent; decided from $service_user's rc files, not the sudo PATH)"
    else
      case ":$PATH:" in
        *":$install_dir:"*) say "$install_dir is already on PATH" ;;
        *) say "would add $install_dir to PATH in ~/.bashrc / ~/.zshrc (idempotent)" ;;
      esac
    fi
    # REQ-INST-5: name the non-fatal fallback in the plan too, so the preview
    # matches what a read-only-rc machine (NixOS, home-manager) actually gets.
    say "a shell config file that cannot be written is NOT an install failure: the PATH snippet is printed for you to add by hand and the install continues"
    # REQ-INST-23: a preview must tell the truth about what a real run would do,
    # and what a real run would do here is REFUSE. Same shape as the socat line
    # at the top of this plan.
    if [ -n "$system_unit" ] && ! "$force_service"; then
      say "would REFUSE to continue: $system_unit already provides heimdall-bridge system-wide, and a user unit of the same name silently takes precedence over it (re-run with --force-service to shadow it deliberately)"
    fi
    if "$force_service"; then
      say "would write service file $service_file unconditionally (--force-service: no backup) with contents:"
    else
      say "would write service file $service_file with contents (a differing existing file is backed up to $service_file.bak-<timestamp>; an identical file is left untouched; pass --force-service to overwrite a differing file without a backup):"
    fi
    if [ "$os" = "linux" ]; then render_systemd_unit; else render_launchd_plist; fi
    print_onboarding
    exit 0
  fi

  # --- download -----------------------------------------------------------------
  # REQ-INST-6: this guard deliberately STAYS BELOW the dry-run exit rather than
  # moving above release resolution.
  #
  # Hoisting it was the original prescription, on the reading that resolution
  # calling curl before the guard ran was an ORDERING bug. It is not the fix, for
  # two reasons found in the source:
  #   1. It does not fix the case it was aimed at. On a wget-only host this guard
  #      PASSES -- wget is present -- so resolution still failed and still blamed
  #      the network. What fixes that host is api_fetch having a wget path at all,
  #      which is where resolve_latest_tag now goes.
  #   2. Hoisting it would REGRESS a property two completed tasks assert: the
  #      guard is fatal, and above the dry-run exit it would make `--dry-run`
  #      fail on a machine with neither downloader, where today it prints a plan
  #      and exits 0.
  # The no-downloader case is instead diagnosed inside resolve_latest_tag, before
  # any network attempt, where it can be fatal on a real run and a warning on a
  # dry run. This guard keeps covering the --hub and --version paths, which skip
  # resolution entirely and so reach a download without ever having checked.
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 \
    || fail "need curl or wget to download the release bundle; install one, or fetch $tarball_name yourself and serve it with --hub <url>"

  # REQ-INST-23: fatal HERE -- below the dry-run exit so --dry-run still previews
  # and still tells the truth, and above the download so a refused run installs
  # NOTHING. That placement is what makes the "Nothing has been installed"
  # sentence below TRUE: if this check is ever moved below the install step, that
  # sentence MUST change with it. Same idiom as the curl/wget guard just above.
  #
  # The "only want fresher binaries" bullet deliberately names the OS and NOT
  # `heimdall update`. On exactly the host this guard is about -- system-managed
  # unit whose ExecStart points outside $install_dir -- `heimdall update` stops the
  # service by NAME (src/manager/service.odin:35), replaces binaries in a directory
  # that unit never execs, and restarts it: a production bounce for zero benefit.
  # T22 (REQ-INST-24) fixes that; until it lands, naming the updater here would
  # send the user into a version of the harm this message warns about.
  if [ -n "$system_unit" ] && ! "$force_service"; then
    fail "this machine already has a system-managed heimdall-bridge service at $system_unit.
Writing $service_file would SILENTLY SHADOW it: a user unit of the same name takes precedence over the system one. Nothing would fail now and the running bridge would carry on, but the next restart would start THIS unit instead of the machine's -- which is how a host loses the ability to restart its own bridge with no error anywhere.
Nothing has been installed; this run stopped before downloading.
  - service managed by your OS (NixOS, a distro package, config management)? Nothing to do -- keep using $system_unit.
  - only want fresher binaries? Whatever put that unit there installed the binaries it runs too, and its ExecStart decides which ones -- so update through your OS (nixos-rebuild, your distro package manager, your config management). Re-running this installer cannot refresh what that unit actually executes.
  - want the user unit to win anyway? Re-run with --force-service.
This installer will never remove or modify $system_unit."
  fi

  say "downloading $tarball_url"
  # An explicit TEMPLATE, not a bare `mktemp -d`. On macOS a bare `mktemp -d`
  # IGNORES $TMPDIR and always uses the per-user darwin temp dir. Measured on
  # both hosted runners (.github/workflows/install-sh.yml prints it every run):
  #   TMPDIR=/Users/runner/work/_temp/tmpdir-probe mktemp -d
  #     -> /var/folders/20/jp1_0n3n7kndh6rnbqb5344m0000gn/T/tmp.G4ukaEijuP
  # That made download_failed's remediation below -- "set TMPDIR to a larger
  # filesystem and re-run" -- FALSE on macOS: the tarball landed in the same
  # place whatever the user set, so the one piece of advice offered for a
  # space-exhausted download could not work. With a template both platforms
  # honour TMPDIR and the advice is true on both. The name is no longer a bare
  # tmp.XXXXXXXX either, which is worth having in a leftover directory.
  tmp_base="${TMPDIR:-/tmp}"
  work_dir="$(mktemp -d "${tmp_base%/}/heimdall-install.XXXXXX")"
  cleanup() { rm -rf "$work_dir"; }
  trap cleanup EXIT

  download "$tarball_url" "$work_dir/$tarball_name"
  say "downloading $sums_url"
  download "$sums_url" "$work_dir/$sums_name"

  # --- verify BEFORE extracting -------------------------------------------------
  expected="$(awk -v f="$tarball_name" '$2 == f {print $1; exit}' "$work_dir/$sums_name")"
  [ -n "$expected" ] || fail "$sums_name has no entry for $tarball_name"
  actual="$(sha256_of "$work_dir/$tarball_name")"
  # Fail-closed: a corrupt or hostile tarball must never reach the filesystem
  # as an installed binary, so nothing is extracted until the checksum matches.
  if [ "$actual" != "$expected" ]; then
    fail "SHA-256 mismatch for $tarball_name (expected $expected, got $actual); aborting before extraction"
  fi
  say "checksum verified ($actual)"

  # --- extract and install ------------------------------------------------------
  tar -xzf "$work_dir/$tarball_name" -C "$work_dir"
  bundle_bin="$work_dir/bin"
  binaries="heimdall ham-bridge ham-pty-host ham-ctl"
  for b in $binaries; do
    [ -f "$bundle_bin/$b" ] || fail "release bundle is missing bin/$b; refusing to install an incomplete bundle"
  done

  say "installing to $install_dir"
  mkdir -p "$install_dir"
  for b in $binaries; do
    install -m 0755 "$bundle_bin/$b" "$install_dir/$b"
    say "installed $install_dir/$b"
  done

  telegraf_url="https://dl.influxdata.com/telegraf/releases/telegraf-${TELEGRAF_VERSION}_${os}_${arch}.tar.gz"
  if "$dry_run"; then
    say "would download telegraf from $telegraf_url"
    say "would install $install_dir/telegraf"
  else
    say "downloading telegraf from $telegraf_url"
    download "$telegraf_url" "$work_dir/telegraf.tar.gz"
    tar -xzf "$work_dir/telegraf.tar.gz" -C "$work_dir"
    telegraf_extracted="$(find "$work_dir" -name telegraf -type f -perm -111 2>/dev/null | head -n 1)"
    [ -n "$telegraf_extracted" ] && [ -f "$telegraf_extracted" ] || fail "failed to find extracted telegraf binary in $work_dir"
    install -m 0755 "$telegraf_extracted" "$install_dir/telegraf"
    say "installed $install_dir/telegraf"
  fi

  # --- PATH (REQ-INST-5: never fatal) -------------------------------------------
  # wire_path handles every outcome itself — added / already present / could
  # not write — and never fails the install, so the service-file step below is
  # always reached. That was the original bug: a read-only rc file aborted the
  # run here, after the binaries and before the unit.
  wire_path

  # --- service file (REQ-INST-2: never silently clobber) -------------------------
  mkdir -p "$service_home/.config/heimdall"
  take_ownership "$service_home/.config/heimdall"
  mkdir -p "$service_dir"
  take_ownership "$service_dir"
  rendered="$(mktemp)"
  if [ "$os" = "linux" ]; then
    render_systemd_unit > "$rendered"
  else
    render_launchd_plist > "$rendered"
  fi
  if [ -e "$service_file" ] && cmp -s "$rendered" "$service_file"; then
    say "service file $service_file is already up to date; leaving it untouched"
  else
    if [ -e "$service_file" ] && ! "$force_service"; then
      backup="$service_file.bak-$(date -u +%Y%m%dT%H%M%SZ)"
      cp -p "$service_file" "$backup"
      say "existing service file differs; saved a copy to $backup"
      take_ownership "$backup"
    fi
    cat "$rendered" > "$service_file"
    chmod 0644 "$service_file"
    say "wrote service file $service_file"
  fi
  rm -f "$rendered"
  take_ownership "$service_file"

  if [ "$os" = "linux" ]; then
    if [ -n "$service_user" ]; then
      say "run 'systemctl --user daemon-reload' as $service_user before starting the service"
    elif command -v systemctl >/dev/null 2>&1; then
      # Best effort: user systemd may not be available in every context (root,
      # containers); the printed instructions cover the manual path.
      systemctl --user daemon-reload 2>/dev/null \
        && say "systemd user unit registered (not started)" \
        || warn "could not run 'systemctl --user daemon-reload'; run it manually before starting the service"
    fi
  fi

  if is_interactive; then
    run_interactive_onboarding
  else
    print_onboarding
  fi
}

main "$@"
