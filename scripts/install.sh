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

usage() {
  cat >&2 <<'USAGE'
usage: install.sh [--version <tag>] [--hub <url>] [--dry-run] [--force-service]
                  [--uninstall]

Installs prebuilt heimdall binaries (heimdall, ham-bridge, ham-pty-host,
ham-ctl), wires PATH, and registers a user-level heimdall-bridge service.

  --version <tag>      install release <tag> instead of the latest GitHub release
  --hub <url>          download <url>/heimdall-local-<target>.tar.gz and
                       <url>/SHA256SUMS (self-hosted hub mirror) and start the
                       service with --hub <url> as an explicit override.
                       Without --hub the service reads the hub URL from
                       config.toml ([wrapper] daemon_url, written by
                       'heimdall enroll'); nothing is baked into the unit.
  --dry-run            print every planned action without writing anything
  --force-service      overwrite an existing, differing service file WITHOUT
                       keeping a .bak-<timestamp> backup (default: back up the
                       old file first; skip the write when identical)
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

# Where the provenance record for the bundled openssl lives, beside the binary
# it describes. 'openssl' is the one generic name this installer writes, so
# --uninstall cannot tell ours from the system's by CONTENT -- that test is
# wrong in both directions: stock OpenSSL carries no 'heimdall' bytes (so our
# own file would survive, misreported as a stranger's), while a stranger's
# wrapper script that merely mentions heimdall would be deleted. The sidecar
# records the sha256 of the file we installed, so removal needs proof of
# authorship rather than a guess: a stranger's file cannot match it, and ours
# does until something else overwrites it.
openssl_marker() { printf '%s\n' "$install_dir/.heimdall-openssl.sha256"; }

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
  if [ -n "$hub_url" ]; then printf ' \\\n    --hub %s' "$hub_url"; fi
}

service_hub_flags_plist() {
  if [ -n "$hub_url" ]; then
    printf '    <string>--hub</string>\n    <string>%s</string>\n' "$hub_url"
  fi
}

render_systemd_unit() {
  cat <<UNIT
[Unit]
Description=Heimdall Bridge
After=network-online.target

[Service]
Type=simple
ExecStart=$install_dir/ham-bridge \\
    --bridge-token-file %h/.config/heimdall/bridge-token \\
    --port 49323 \\
    --local-endpoint-port 49324 \\
    --local-run-dir /tmp/heimdall-bridge-local$(service_hub_flags_systemd)
Environment=HEIMDALL_HAM_PTY_HOST_BIN=$install_dir/ham-pty-host
Environment=HEIMDALL_BRIDGE_PTY_HOST=true
Environment=HEIMDALL_HAM_CTL_BIN=$install_dir/ham-ctl
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
      fish_add_path $install_dir
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
    *fish*) path_line="fish_add_path $install_dir" ;;
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
  if [ "$os" = "linux" ]; then
    if [ -n "$service_user" ]; then
      say "service runs as $service_user — stop it as that user: systemctl --user stop heimdall-bridge"
    elif "$dry_run"; then
      say "would stop the heimdall-bridge service (best effort)"
    elif command -v systemctl >/dev/null 2>&1; then
      systemctl --user stop heimdall-bridge >/dev/null 2>&1 || true
      say "stopped heimdall-bridge (best effort)"
    fi
  elif "$dry_run"; then
    say "would stop the heimdall-bridge service (best effort)"
  elif command -v launchctl >/dev/null 2>&1; then
    launchctl bootout "gui/$(id -u)/works.earendil.heimdall-bridge" >/dev/null 2>&1 || true
    say "stopped works.earendil.heimdall-bridge (best effort)"
  fi

  # 2. Binaries. These four names are ours alone, so their presence at
  # $install_dir is itself proof this installer wrote them — no content check is
  # needed or wanted here. Do not "fix" this asymmetry with the openssl rule
  # below: openssl is the only generic name we write, and it is the only one
  # that needs proof of authorship.
  for b in heimdall ham-bridge ham-pty-host ham-ctl; do
    target="$install_dir/$b"
    [ -f "$target" ] || continue
    remove_installed "$target"
  done

  # 2b. The bundled openssl, removed only against the provenance recorded at
  # install time (see openssl_marker). Every other outcome KEEPS the file and
  # says which of them it was, so the output never claims authorship it cannot
  # prove — nor denies authorship of a file we did write.
  openssl_file="$install_dir/openssl"
  marker_file="$(openssl_marker)"
  if [ -f "$openssl_file" ]; then
    recorded=""
    marker_present=false
    if [ -f "$marker_file" ]; then
      marker_present=true
      recorded="$(awk 'NR == 1 {print $1; exit}' "$marker_file" 2>/dev/null || true)"
    fi
    current="$(sha256_or_empty "$openssl_file")"
    if [ -z "$recorded" ] && "$marker_present"; then
      # A record EXISTS and we could not read it. Saying "no record" here would
      # deny authorship of a file we may well have written — the same false
      # claim the content-marker design used to make. Keep the file either way,
      # but report which of the two states we are actually in.
      say "left $openssl_file in place (a provenance record exists at $marker_file but could not be read, so this installer cannot prove the file is its own; remove it by hand if unwanted)"
    elif [ -z "$recorded" ]; then
      say "left $openssl_file in place (this installer has no record of writing it; remove it by hand if unwanted)"
    elif [ -z "$current" ]; then
      say "left $openssl_file in place (could not hash it to check against $marker_file — unreadable, or no sha256sum/shasum on PATH; remove it by hand if unwanted)"
    elif [ "$current" = "$recorded" ]; then
      remove_installed "$openssl_file"
      remove_installed "$marker_file"
    else
      say "left $openssl_file in place (it no longer matches the checksum recorded at $marker_file, so something replaced it after install — a self-update, or your package manager; remove it by hand if unwanted)"
    fi
  elif [ -f "$marker_file" ]; then
    # The openssl is already gone; its record is our own debris.
    remove_installed "$marker_file"
  fi

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
           -v fish_line="fish_add_path $install_dir" '
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

main() {
  set -euo pipefail
  version=""
  hub_url=""
  dry_run=false
  force_service=false
  uninstall=false
  # Set by wire_path when no rc file ended up carrying the PATH line, so the
  # final summary can say the install itself succeeded (REQ-INST-5).
  path_needs_action=false
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --version)
        [ "$#" -ge 2 ] || fail "--version requires a value (e.g. v0.1.0)"
        version="$2"; shift 2 ;;
      --hub)
        [ "$#" -ge 2 ] || fail "--hub requires a url"
        hub_url="${2%/}"; shift 2 ;;
      --dry-run) dry_run=true; shift ;;
      --force-service) force_service=true; shift ;;
      --uninstall) uninstall=true; shift ;;
      --help|-h) usage; exit 0 ;;
      *) usage; fail "unknown argument: $1" ;;
    esac
  done

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
    say "would verify SHA-256 of $tarball_name against SHA256SUMS before extracting"
    say "would install bin/heimdall bin/ham-bridge bin/ham-pty-host bin/ham-ctl (and bin/openssl if bundled) to $install_dir"
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
  if [ -f "$bundle_bin/openssl" ]; then
    install -m 0755 "$bundle_bin/openssl" "$install_dir/openssl"
    say "installed bundled $install_dir/openssl"
    # Record what we just wrote so --uninstall can PROVE this openssl is ours
    # before deleting it (see openssl_marker). A sidecar we fail to write means
    # --uninstall will keep the file: the fallback leans toward leaving a
    # leftover, never toward removing a file we cannot account for.
    openssl_sha="$(sha256_or_empty "$install_dir/openssl")"
    if [ -n "$openssl_sha" ] && printf '%s\n' "$openssl_sha" > "$(openssl_marker)" 2>/dev/null; then
      say "recorded its checksum at $(openssl_marker) so --uninstall can tell it from a system openssl"
    else
      rm -f "$(openssl_marker)" 2>/dev/null || true
      warn "could not record openssl provenance at $(openssl_marker); --uninstall will leave $install_dir/openssl in place for you to remove by hand"
    fi
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

  print_onboarding
}

main "$@"
