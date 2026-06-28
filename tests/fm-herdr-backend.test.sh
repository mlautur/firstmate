#!/usr/bin/env bash
# herdr backend (bin/fm-herdr-lib.sh) — fm_be_* seam implementation.
#
# Slice 3 of the tmux->herdr migration fills the herdr backend so that
# config/crew-backend=herdr actually drives crewmate panes through herdr. These
# tests pin that the herdr backend reproduces the tmux backend's contract:
#   1. fm_be_agent_status maps herdr's native pane agent_status through unchanged
#      (idle/working/blocked/done/unknown), reports "none" for a gone pane, and
#      "unknown" when the field is absent.
#   2. fm_be_pane_cwd extracts .foreground_cwd (the active subshell dir, matching
#      tmux #{pane_current_path}), falling back to .cwd when no foreground subshell.
#   3. fm_be_pane_alive reflects `pane get` exit; fm_pane_is_busy == working.
#   4. fm_be_create_window reuses/creates the shared workspace, creates a tab,
#      renames the pane, echoes the pane_id, and rejects a duplicate label.
#   5. fm_be_resolve / fm_be_window_exists pass a pane_id handle through and
#      resolve a bare label via the pane list (incl. non-numeric workspace ids).
#   6. fm_be_capture selects --format text|ansi, caps to the last N lines, and
#      preserves herdr's non-zero exit on a dead pane.
#   7. fm_be_kill_window closes the pane (herdr auto-removes the empty tab).
#   8. fm_be_submit_verify returns the tmux verdict tokens
#      (empty|pending|unknown|send-failed), driven by native agent_status.
#
# Everything runs against a FAKE `herdr` binary on PATH (no server needed), so the
# suite is deterministic and CI-safe. An optional live round-trip against a real
# herdr server is gated behind FM_HERDR_LIVE=1 and skips cleanly otherwise.
#
# The dispatcher is sourced inside throwaway subshells with a subshell-local
# FM_HOME/PATH; silence the directives that flag that intentional dynamic pattern.
# shellcheck disable=SC1090,SC2030,SC2031
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DISPATCH="$ROOT/bin/fm-backend-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-herdr-backend)

# A fake `herdr` that emits the JSON / raw-text shapes the real CLI does (verified
# against herdr 0.7.0, see data/herdr-migration-scout-h1/report.md Appendix A) and
# is driven by FM_FAKE_* env vars. It appends every argv to $FM_FAKE_HERDR_LOG so
# tests can assert which subcommands a primitive issued.
make_fake_herdr() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_HERDR_LOG:-/dev/null}"
noun=${1:-}; verb=${2:-}
case "$noun $verb" in
  "workspace list")
    if [ "${FM_FAKE_WS_EXISTS:-1}" = 1 ]; then
      printf '{"result":{"workspaces":[{"workspace_id":"%s","label":"%s"}]}}\n' \
        "${FM_FAKE_WS_ID:-w1}" "${FM_FAKE_WS_LABEL:-firstmate}"
    else
      printf '{"result":{"workspaces":[]}}\n'
    fi ;;
  "workspace create")
    printf '{"result":{"workspace":{"workspace_id":"%s"}}}\n' "${FM_FAKE_WS_ID:-w1}" ;;
  "workspace close") printf '{"result":{"type":"ok"}}\n' ;;
  "tab create")
    printf '{"result":{"root_pane":{"pane_id":"%s"}}}\n' "${FM_FAKE_PANE_ID:-w1:p2}" ;;
  "pane list")
    if [ -n "${FM_FAKE_PANE_LABEL:-}" ]; then
      printf '{"result":{"panes":[{"pane_id":"%s","label":"%s"}]}}\n' \
        "${FM_FAKE_PANE_ID:-w1:p2}" "$FM_FAKE_PANE_LABEL"
    else
      printf '{"result":{"panes":[]}}\n'
    fi ;;
  "pane get")
    [ "${FM_FAKE_DEAD:-0}" = 1 ] && { printf '{"error":{"code":"pane_not_found"}}\n'; exit 1; }
    if [ "${FM_FAKE_NO_STATUS:-0}" = 1 ]; then
      printf '{"result":{"pane":{"pane_id":"w1:p2","cwd":"%s"}}}\n' "${FM_FAKE_CWD:-/wt}"
    else
      printf '{"result":{"pane":{"pane_id":"w1:p2","agent_status":"%s","cwd":"%s","foreground_cwd":"%s"}}}\n' \
        "${FM_FAKE_STATUS:-idle}" "${FM_FAKE_CWD:-/wt}" "${FM_FAKE_FGCWD:-/fg}"
    fi ;;
  "pane read")
    [ "${FM_FAKE_DEAD:-0}" = 1 ] && exit 1
    printf '%s\n' "${FM_FAKE_TEXT:-only-line}" ;;
  "pane rename") printf '{"result":{"type":"ok"}}\n' ;;
  "pane run") exit 0 ;;
  "pane send-text") [ "${FM_FAKE_SENDTEXT_FAIL:-0}" = 1 ] && exit 1; exit 0 ;;
  "pane send-keys") exit 0 ;;
  "pane close") printf '{"result":{"type":"ok"}}\n' ;;
  "pane report-agent") exit 0 ;;
  *) printf 'fake-herdr: unhandled %s %s\n' "$noun" "$verb" >&2; exit 1 ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

# Source the herdr backend in a subshell with the fake herdr on PATH. Echoes
# nothing; callers run their assertions inside the same subshell.
herdr_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config"
  printf 'herdr\n' > "$home/config/crew-backend"
  printf '%s\n' "$home"
}

# --- 1. agent_status mapping ------------------------------------------------

test_agent_status_mapping() {
  local home fb got s
  home=$(herdr_home agentstatus); fb=$(make_fake_herdr "$TMP_ROOT/agentstatus")
  for s in idle working blocked 'done' unknown; do
    got=$( unset FM_CREW_BACKEND; export FM_HOME="$home" PATH="$fb:$PATH" FM_FAKE_STATUS="$s"
           . "$DISPATCH" >/dev/null 2>&1; fm_be_agent_status w1:p2 )
    [ "$got" = "$s" ] || fail "agent_status '$s' should pass through, got '$got'"
  done
  # Gone pane -> none.
  got=$( unset FM_CREW_BACKEND; export FM_HOME="$home" PATH="$fb:$PATH" FM_FAKE_DEAD=1
         . "$DISPATCH" >/dev/null 2>&1; fm_be_agent_status w1:p2 )
  [ "$got" = none ] || fail "gone pane should map to none, got '$got'"
  # Pane present but no agent_status field -> unknown.
  got=$( unset FM_CREW_BACKEND; export FM_HOME="$home" PATH="$fb:$PATH" FM_FAKE_NO_STATUS=1
         . "$DISPATCH" >/dev/null 2>&1; fm_be_agent_status w1:p2 )
  [ "$got" = unknown ] || fail "missing agent_status field should map to unknown, got '$got'"
  pass "fm_be_agent_status maps native states, none for gone, unknown for missing"
}

# --- 2. pane_cwd / 3. pane_alive + is_busy ----------------------------------

test_pane_cwd_and_alive() {
  local home fb got
  home=$(herdr_home cwd); fb=$(make_fake_herdr "$TMP_ROOT/cwd")
  # Regression guard for the spawn worktree-detection bug: after `treehouse get`
  # opens a subshell into the worktree, the pane's base .cwd stays the project dir
  # (login shell) while the active subshell's dir is reported in .foreground_cwd.
  # fm_be_pane_cwd must return the foreground (worktree) value to match tmux's
  # #{pane_current_path}, otherwise fm-spawn's wait loop never sees the worktree.
  got=$( unset FM_CREW_BACKEND
         export FM_HOME="$home" PATH="$fb:$PATH" \
                FM_FAKE_CWD=/the/project FM_FAKE_FGCWD=/the/worktree
         . "$DISPATCH" >/dev/null 2>&1; fm_be_pane_cwd w1:p2 )
  [ "$got" = /the/worktree ] \
    || fail "pane_cwd should return .foreground_cwd (worktree), got '$got'"
  # .foreground_cwd absent -> fall back to .cwd (a pane with no foreground subshell).
  got=$( unset FM_CREW_BACKEND; export FM_HOME="$home" PATH="$fb:$PATH" FM_FAKE_NO_STATUS=1 FM_FAKE_CWD=/only/base
         . "$DISPATCH" >/dev/null 2>&1; fm_be_pane_cwd w1:p2 )
  [ "$got" = /only/base ] \
    || fail "pane_cwd should fall back to .cwd when foreground_cwd absent, got '$got'"

  # alive reflects pane get exit.
  ( unset FM_CREW_BACKEND; export FM_HOME="$home" PATH="$fb:$PATH"
    . "$DISPATCH" >/dev/null 2>&1; fm_be_pane_alive w1:p2 ) || fail "live pane should be alive"
  ( unset FM_CREW_BACKEND; export FM_HOME="$home" PATH="$fb:$PATH" FM_FAKE_DEAD=1
    . "$DISPATCH" >/dev/null 2>&1; fm_be_pane_alive w1:p2 ) && fail "dead pane should not be alive"

  # is_busy == working.
  ( unset FM_CREW_BACKEND; export FM_HOME="$home" PATH="$fb:$PATH" FM_FAKE_STATUS=working
    . "$DISPATCH" >/dev/null 2>&1; fm_pane_is_busy w1:p2 ) || fail "working pane should be busy"
  ( unset FM_CREW_BACKEND; export FM_HOME="$home" PATH="$fb:$PATH" FM_FAKE_STATUS=idle
    . "$DISPATCH" >/dev/null 2>&1; fm_pane_is_busy w1:p2 ) && fail "idle pane should not be busy"
  pass "fm_be_pane_cwd/pane_alive/fm_pane_is_busy read herdr pane state correctly"
}

# --- 4. create_window (reuse, create, rename, duplicate) --------------------

test_create_window() {
  local home fb log handle
  home=$(herdr_home create); fb=$(make_fake_herdr "$TMP_ROOT/create")
  log="$TMP_ROOT/create/herdr.log"

  # Reuse an existing "firstmate" workspace; create a tab; echo the pane_id.
  handle=$( unset FM_CREW_BACKEND
            export FM_HOME="$home" PATH="$fb:$PATH" FM_FAKE_HERDR_LOG="$log" \
                   FM_FAKE_WS_EXISTS=1 FM_FAKE_WS_LABEL=firstmate FM_FAKE_PANE_ID=w1:p7
            . "$DISPATCH" >/dev/null 2>&1; fm_be_create_window foo /wt fm-foo )
  [ "$handle" = w1:p7 ] || fail "create_window should echo the pane_id, got '$handle'"
  assert_grep "tab create --workspace w1 --cwd /wt --label fm-foo --no-focus" "$log" \
    "create_window did not create a tab in the reused workspace"
  assert_grep "pane rename w1:p7 fm-foo" "$log" \
    "create_window did not rename the pane to the label"
  assert_no_grep "workspace create" "$log" \
    "create_window created a workspace when one already existed"

  # Lazy-create the workspace when absent.
  : > "$log"
  handle=$( unset FM_CREW_BACKEND
            export FM_HOME="$home" PATH="$fb:$PATH" FM_FAKE_HERDR_LOG="$log" \
                   FM_FAKE_WS_EXISTS=0 FM_FAKE_WS_ID=w3 FM_FAKE_PANE_ID=w3:p2
            . "$DISPATCH" >/dev/null 2>&1; fm_be_create_window bar /wt2 fm-bar )
  [ "$handle" = w3:p2 ] || fail "create_window (lazy) should echo the pane_id, got '$handle'"
  assert_grep "workspace create --cwd /wt2 --label firstmate --no-focus" "$log" \
    "create_window did not lazily create the firstmate workspace"

  # Reject a duplicate label already present in the workspace.
  local out rc
  out=$( unset FM_CREW_BACKEND
         export FM_HOME="$home" PATH="$fb:$PATH" \
                FM_FAKE_WS_EXISTS=1 FM_FAKE_PANE_LABEL=fm-dup
         . "$DISPATCH" >/dev/null 2>&1; fm_be_create_window dup /wt fm-dup 2>&1 ); rc=$?
  [ "$rc" -ne 0 ] || fail "create_window should reject a duplicate label"
  assert_contains "$out" "already exists" "duplicate rejection lacked a diagnostic"
  pass "fm_be_create_window reuses/creates workspace, names the pane, rejects dups"
}

# --- 5. resolve / window_exists ---------------------------------------------

test_resolve_and_exists() {
  local home fb got
  home=$(herdr_home resolve); fb=$(make_fake_herdr "$TMP_ROOT/resolve")

  # A pane_id handle passes through unchanged (incl. non-numeric workspace ids).
  got=$( unset FM_CREW_BACKEND; export FM_HOME="$home" PATH="$fb:$PATH"
         . "$DISPATCH" >/dev/null 2>&1; fm_be_resolve wA:p3 )
  [ "$got" = wA:p3 ] || fail "resolve should pass a pane_id through, got '$got'"

  # A bare label resolves to its pane_id via the pane list.
  got=$( unset FM_CREW_BACKEND
         export FM_HOME="$home" PATH="$fb:$PATH" FM_FAKE_PANE_LABEL=fm-x FM_FAKE_PANE_ID=w2:p5
         . "$DISPATCH" >/dev/null 2>&1; fm_be_resolve fm-x )
  [ "$got" = w2:p5 ] || fail "resolve should map a label to its pane_id, got '$got'"

  # An unknown label fails.
  ( unset FM_CREW_BACKEND; export FM_HOME="$home" PATH="$fb:$PATH"
    . "$DISPATCH" >/dev/null 2>&1; fm_be_resolve fm-missing ) && fail "resolve should fail on an unknown label"

  # window_exists: by handle (pane get) and by label (pane list).
  ( unset FM_CREW_BACKEND; export FM_HOME="$home" PATH="$fb:$PATH"
    . "$DISPATCH" >/dev/null 2>&1; fm_be_window_exists wA:p3 ) || fail "window_exists(handle) should be true for a live pane"
  ( unset FM_CREW_BACKEND; export FM_HOME="$home" PATH="$fb:$PATH" FM_FAKE_DEAD=1
    . "$DISPATCH" >/dev/null 2>&1; fm_be_window_exists wA:p3 ) && fail "window_exists(handle) should be false for a gone pane"
  ( unset FM_CREW_BACKEND; export FM_HOME="$home" PATH="$fb:$PATH" FM_FAKE_PANE_LABEL=fm-x
    . "$DISPATCH" >/dev/null 2>&1; fm_be_window_exists fm-x ) || fail "window_exists(label) should be true when present"
  ( unset FM_CREW_BACKEND; export FM_HOME="$home" PATH="$fb:$PATH"
    . "$DISPATCH" >/dev/null 2>&1; fm_be_window_exists fm-x ) && fail "window_exists(label) should be false when absent"
  pass "fm_be_resolve/window_exists handle pane_id passthrough and label lookup"
}

# --- 6. capture (format + tail + exit) --------------------------------------

test_capture() {
  local home fb log out rc
  home=$(herdr_home capture); fb=$(make_fake_herdr "$TMP_ROOT/capture")
  log="$TMP_ROOT/capture/herdr.log"

  # Plain text by default; caps to the last N lines.
  out=$( unset FM_CREW_BACKEND
         export FM_HOME="$home" PATH="$fb:$PATH" FM_FAKE_HERDR_LOG="$log" \
                FM_FAKE_TEXT=$'l1\nl2\nl3\nl4\nl5'
         . "$DISPATCH" >/dev/null 2>&1; fm_be_capture w1:p2 2 )
  [ "$out" = $'l4\nl5' ] || fail "capture should tail to the last 2 lines, got '$out'"
  assert_grep "pane read w1:p2 --source visible --lines 2 --format text" "$log" \
    "capture did not request a plain visible read"

  # ANSI format on a non-empty third arg.
  : > "$log"
  ( unset FM_CREW_BACKEND
    export FM_HOME="$home" PATH="$fb:$PATH" FM_FAKE_HERDR_LOG="$log"
    . "$DISPATCH" >/dev/null 2>&1; fm_be_capture w1:p2 3 ansi >/dev/null )
  assert_grep "--format ansi" "$log" "capture with a third arg did not request --format ansi"

  # Dead pane -> non-zero exit (fm-watch relies on this to skip gone panes).
  ( unset FM_CREW_BACKEND; export FM_HOME="$home" PATH="$fb:$PATH" FM_FAKE_DEAD=1
    . "$DISPATCH" >/dev/null 2>&1; fm_be_capture w1:p2 40 >/dev/null 2>&1 ) \
    && fail "capture should return non-zero for a dead pane"
  pass "fm_be_capture selects text/ansi, tails to N, and fails on a dead pane"
}

# --- 7. kill_window ---------------------------------------------------------

test_kill_window() {
  local home fb log
  home=$(herdr_home kill); fb=$(make_fake_herdr "$TMP_ROOT/kill")
  log="$TMP_ROOT/kill/herdr.log"
  ( unset FM_CREW_BACKEND; export FM_HOME="$home" PATH="$fb:$PATH" FM_FAKE_HERDR_LOG="$log"
    . "$DISPATCH" >/dev/null 2>&1; fm_be_kill_window w1:p2 ) || fail "kill_window should succeed"
  assert_grep "pane close w1:p2" "$log" "kill_window did not close the pane"
  assert_no_grep "workspace close" "$log" "kill_window must NOT close the shared workspace"
  pass "fm_be_kill_window closes the pane and never the workspace"
}

# --- 8. submit_verify verdicts ----------------------------------------------

test_submit_verify() {
  local home fb got
  home=$(herdr_home submit); fb=$(make_fake_herdr "$TMP_ROOT/submit")

  # send-text failure -> send-failed.
  got=$( unset FM_CREW_BACKEND
         export FM_HOME="$home" PATH="$fb:$PATH" FM_FAKE_SENDTEXT_FAIL=1
         . "$DISPATCH" >/dev/null 2>&1; fm_be_submit_verify w1:p2 hi 2 0.02 0.01 )
  [ "$got" = send-failed ] || fail "send-text failure should yield send-failed, got '$got'"

  # agent_status reaches working -> empty (turn began).
  got=$( unset FM_CREW_BACKEND
         export FM_HOME="$home" PATH="$fb:$PATH" FM_FAKE_STATUS=working
         . "$DISPATCH" >/dev/null 2>&1; fm_be_submit_verify w1:p2 hi 2 0.02 0.01 )
  [ "$got" = empty ] || fail "working agent_status should yield empty, got '$got'"

  # idle agent + empty composer (bare prompt) -> empty via the fallback.
  got=$( unset FM_CREW_BACKEND
         export FM_HOME="$home" PATH="$fb:$PATH" FM_FAKE_STATUS=idle FM_FAKE_TEXT='> '
         . "$DISPATCH" >/dev/null 2>&1; fm_be_submit_verify w1:p2 hi 2 0.02 0.01 )
  [ "$got" = empty ] || fail "idle + empty composer should yield empty, got '$got'"

  # idle agent + leftover text in the composer -> pending after retries.
  got=$( unset FM_CREW_BACKEND
         export FM_HOME="$home" PATH="$fb:$PATH" FM_FAKE_STATUS=idle FM_FAKE_TEXT='still typing here'
         . "$DISPATCH" >/dev/null 2>&1; fm_be_submit_verify w1:p2 hi 2 0.02 0.01 )
  [ "$got" = pending ] || fail "idle + leftover composer should yield pending, got '$got'"

  # A pre-existing done/blocked level is NOT a turn-began signal: a crewmate
  # already parked at done/blocked with leftover composer text must fall through
  # to the composer check and report pending, not falsely confirm a swallowed
  # Enter as empty.
  for s in 'done' blocked; do
    got=$( unset FM_CREW_BACKEND
           export FM_HOME="$home" PATH="$fb:$PATH" FM_FAKE_STATUS="$s" FM_FAKE_TEXT='still typing here'
           . "$DISPATCH" >/dev/null 2>&1; fm_be_submit_verify w1:p2 hi 2 0.02 0.01 )
    [ "$got" = pending ] || fail "$s + leftover composer should yield pending, got '$got'"
  done
  pass "fm_be_submit_verify returns send-failed|empty|pending per agent_status+composer"
}

# --- 9. optional live round-trip (FM_HERDR_LIVE=1) --------------------------

test_live_round_trip() {
  if [ "${FM_HERDR_LIVE:-0}" != 1 ]; then
    pass "live herdr round-trip skipped (set FM_HERDR_LIVE=1 with a running server)"
    return 0
  fi
  if ! command -v herdr >/dev/null 2>&1 || ! herdr status >/dev/null 2>&1; then
    pass "live herdr round-trip skipped (no running herdr server)"
    return 0
  fi
  local home wt label H got
  home=$(herdr_home live); wt=$(pwd -P)
  # An isolated workspace label so the captain's live "firstmate" workspace is
  # never touched (Appendix A cleanup discipline).
  label="fm-s3-live-$$"
  (
    unset FM_CREW_BACKEND
    export FM_HOME="$home" FM_HERDR_WORKSPACE_LABEL="$label"
    . "$DISPATCH" >/dev/null 2>&1
    H=$(fm_be_create_window live "$wt" fm-live) || exit 1
    fm_be_window_exists "$H" || exit 1
    [ "$(fm_be_resolve fm-live)" = "$H" ] || exit 1
    fm_be_run_cmd "$H" 'echo LIVE_S3_MARK'
    sleep 1
    fm_be_capture "$H" 40 | grep -q LIVE_S3_MARK || exit 1
    [ "$(fm_be_pane_cwd "$H")" = "$wt" ] || exit 1
    # Native turn-end: working -> idle synthesizes done.
    herdr pane report-agent "$H" --source fmtest --agent claude --state working >/dev/null 2>&1
    sleep 0.4; [ "$(fm_be_agent_status "$H")" = working ] || exit 1
    herdr pane report-agent "$H" --source fmtest --agent claude --state idle >/dev/null 2>&1
    sleep 0.4; [ "$(fm_be_agent_status "$H")" = 'done' ] || exit 1
    fm_be_kill_window "$H" >/dev/null 2>&1
    sleep 0.4; fm_be_pane_alive "$H" && exit 1
    exit 0
  ) || fail "live herdr round-trip failed"
  # Best-effort cleanup of the isolated workspace.
  got=$(herdr workspace list 2>/dev/null \
        | jq -r --arg l "$label" '.result.workspaces[]?|select(.label==$l)|.workspace_id' 2>/dev/null)
  [ -n "$got" ] && herdr workspace close "$got" >/dev/null 2>&1
  pass "live herdr round-trip: create/run/capture/cwd/agent_status(done)/kill"
}

test_agent_status_mapping
test_pane_cwd_and_alive
test_create_window
test_resolve_and_exists
test_capture
test_kill_window
test_submit_verify
test_live_round_trip
