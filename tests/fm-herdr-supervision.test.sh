#!/usr/bin/env bash
# tests/fm-herdr-supervision.test.sh - slice 5 of the tmux->herdr migration: the
# watcher and away-mode daemon derive their wake decisions from the native herdr
# agent_status (read as a LEVEL via fm_be_agent_status, never the edge-triggered
# `herdr wait`; report §2d/§2e). These tests pin the herdr-specific wake mapping:
#   1. window_to_task reverse-looks-up a herdr pane_id handle through meta (the
#      handle does NOT encode the task id), and falls back to the tmux string
#      parse otherwise (so tmux callers stay byte-identical).
#   2. The daemon's window_for_task enumerates meta under herdr instead of
#      scraping tmux window names.
#   3. discover_supervisor_target prefers $HERDR_PANE_ID under the herdr backend.
#   4. The watcher synthesizes a turn-end (touch state/<id>.turn-ended) on the
#      agent_status transition into done / working->idle - the herdr stand-in for
#      the per-task .turn-ended hook fm-spawn skips under herdr - and does so once
#      per transition (no refire while the level is unchanged; the §2e trap).
#   5. A herdr-native "blocked" crew is NOT treated as idle/stale: no false-stale
#      wake, no escalation timer, no synthesized turn-end.
#
# Everything runs against a FAKE `herdr` on PATH (no server needed), CI-safe and
# deterministic, mirroring the slice-3/4 fake-herdr suites.
#
# The watcher is driven as a real subprocess with FM_CREW_BACKEND=herdr so the
# backend dispatcher loads the herdr lib; the pure daemon/classifier functions are
# sourced and exercised with FM_CREW_BACKEND flipped per call (fm_backend_name is a
# dynamic read, so this selects the herdr code path without re-sourcing).
# shellcheck disable=SC1090,SC1091,SC2030,SC2031
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DAEMON="$ROOT/bin/fm-supervise-daemon.sh"
# Source the daemon's pure functions (its main loop is guarded under sourcing).
# It sources fm-backend-lib at the default (tmux) backend, but window_for_task /
# discover_supervisor_target dispatch on fm_backend_name at call time, which we
# flip via FM_CREW_BACKEND per assertion.
if [ -z "${FM_TEST_DAEMON_SOURCED:-}" ]; then
  export FM_TEST_DAEMON_SOURCED=1
  . "$DAEMON"
fi

TMP_ROOT=$(fm_test_tmproot fm-herdr-supervision)

# A fake `herdr` driven by FM_FAKE_STATUS / FM_FAKE_TEXT. Only the verbs the
# watcher's herdr backend issues are implemented: `pane get` (agent_status +
# liveness) and `pane read` (capture). Shape matches herdr 0.7.0 (report App. A).
make_fake_herdr() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "pane get")
    [ "${FM_FAKE_DEAD:-0}" = 1 ] && { printf '{"error":{"code":"pane_not_found"}}\n'; exit 1; }
    printf '{"result":{"pane":{"pane_id":"w1:p2","agent_status":"%s","cwd":"/wt"}}}\n' \
      "${FM_FAKE_STATUS:-idle}" ;;
  "pane read")
    [ "${FM_FAKE_DEAD:-0}" = 1 ] && exit 1
    printf '%s\n' "${FM_FAKE_TEXT:-only-line}" ;;
  *) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

# Portable md5 of a string (matches fm-watch.sh hash_pane over the captured tail).
hash_text() {
  if command -v md5 >/dev/null 2>&1; then printf '%s' "$1" | md5 -q
  else printf '%s' "$1" | md5sum | cut -d' ' -f1; fi
}

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# Wait up to <limit> 0.1s ticks for <path> to exist; 0 if it appeared, 1 if not.
wait_path() {
  local path=$1 limit=${2:-40} i=0
  while [ "$i" -lt "$limit" ]; do
    [ -e "$path" ] && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

# Wait up to <limit> ticks while <pid> stays alive; 0 if still alive, 1 if it died.
wait_live() {
  local pid=$1 limit=${2:-20} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.1; i=$((i + 1))
  done
  return 0
}

# --- 1. window_to_task: herdr pane_id reverse-lookup via meta ----------------

test_window_to_task_herdr_pane_id() {
  local dir state
  dir="$TMP_ROOT/wtt"; state="$dir/state"; mkdir -p "$state"
  printf 'window=w7:p3\nkind=ship\n' > "$state/mytask.meta"
  # A herdr pane_id (no embedded task id) resolves to the meta's task id.
  [ "$(window_to_task w7:p3 "$state")" = mytask ] \
    || fail "window_to_task did not reverse-look-up a herdr pane_id via meta"
  # No state dir -> tmux string parse (byte-identical fallback).
  [ "$(window_to_task sess:fm-other)" = other ] \
    || fail "window_to_task lost the tmux string-parse fallback with no state"
  # State given but no matching meta -> string parse fallback.
  [ "$(window_to_task sess:fm-x "$state")" = x ] \
    || fail "window_to_task did not fall back to the string parse on a meta miss"
  pass "window_to_task maps a herdr pane_id via meta and keeps the tmux fallback"
}

# --- 2. daemon window_for_task: meta enumeration under herdr -----------------

test_window_for_task_herdr_meta() {
  local dir state got
  dir="$TMP_ROOT/wft"; state="$dir/state"; mkdir -p "$state"
  printf 'window=w1:p9\nkind=ship\n' > "$state/foo.meta"
  printf 'window=w1:p4\nkind=ship\n' > "$state/bar.meta"
  got=$(FM_CREW_BACKEND=herdr window_for_task "$(_stale_key foo)" "$state")
  [ "$got" = w1:p9 ] || fail "window_for_task(herdr) did not resolve the task's pane_id from meta, got '$got'"
  # An unknown key fails (no matching meta).
  FM_CREW_BACKEND=herdr window_for_task "$(_stale_key nope)" "$state" \
    && fail "window_for_task(herdr) should fail for an unknown task key"
  pass "daemon window_for_task enumerates meta to resolve a task under herdr"
}

# --- 3. discover_supervisor_target prefers HERDR_PANE_ID under herdr ---------

test_discover_supervisor_target_herdr() {
  local got
  got=$( unset FM_SUPERVISOR_TARGET TMUX_PANE
         FM_CREW_BACKEND=herdr HERDR_PANE_ID=w2:p5 discover_supervisor_target )
  [ "$got" = w2:p5 ] || fail "herdr backend did not discover \$HERDR_PANE_ID, got '$got'"
  # Explicit override still wins over HERDR_PANE_ID.
  got=$( FM_CREW_BACKEND=herdr FM_SUPERVISOR_TARGET=w9:p9 HERDR_PANE_ID=w2:p5 discover_supervisor_target )
  [ "$got" = w9:p9 ] || fail "FM_SUPERVISOR_TARGET override did not win over HERDR_PANE_ID, got '$got'"
  # Under tmux, HERDR_PANE_ID is ignored in favor of TMUX_PANE.
  got=$( unset FM_SUPERVISOR_TARGET
         FM_CREW_BACKEND=tmux TMUX_PANE=%7 HERDR_PANE_ID=w2:p5 discover_supervisor_target )
  [ "$got" = %7 ] || fail "tmux backend should use \$TMUX_PANE, not HERDR_PANE_ID, got '$got'"
  pass "discover_supervisor_target prefers HERDR_PANE_ID under herdr, TMUX_PANE under tmux"
}

# --- 4. watcher synthesizes turn-end on the agent_status transition ----------

test_turnend_synthesized_on_done() {
  local dir state fb out pid key
  dir="$TMP_ROOT/turnend-done"; state="$dir/state"; fb=$(make_fake_herdr "$dir")
  mkdir -p "$state"; out="$dir/watch.out"
  printf 'window=w1:p2\nkind=ship\n' > "$state/fin.meta"
  key=$(printf '%s' "w1:p2" | tr ':/.' '___')
  # Prime the last-seen level as "working" so the poll reads a working->done edge.
  printf 'working' > "$state/.agent-status-$key"

  PATH="$fb:$PATH" FM_CREW_BACKEND=herdr FM_STATE_OVERRIDE="$state" \
    FM_FAKE_STATUS='done' FM_FAKE_TEXT='finished, awaiting review' \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_STALE_ESCALATE_SECS=999 "$WATCH" > "$out" 2>/dev/null &
  pid=$!
  wait_path "$state/fin.turn-ended" 40 || { reap "$pid"; fail "watcher did not synthesize .turn-ended on working->done"; }
  [ "$(cat "$state/.agent-status-$key" 2>/dev/null)" = 'done' ] \
    || { reap "$pid"; fail "watcher did not record the new agent_status level"; }
  # Edge-triggered: clear the marker; while the level stays "done" it must not refire.
  rm -f "$state/fin.turn-ended"
  sleep 1.5
  [ ! -e "$state/fin.turn-ended" ] \
    || { reap "$pid"; fail "watcher refired turn-end while the level was unchanged (edge-trigger trap, §2e)"; }
  reap "$pid"
  pass "watcher synthesizes a turn-end on working->done and does not refire on the steady level"
}

test_turnend_synthesized_on_working_to_idle() {
  local dir state fb out pid key
  dir="$TMP_ROOT/turnend-idle"; state="$dir/state"; fb=$(make_fake_herdr "$dir")
  mkdir -p "$state"; out="$dir/watch.out"
  printf 'window=w1:p2\nkind=ship\n' > "$state/done2.meta"
  key=$(printf '%s' "w1:p2" | tr ':/.' '___')
  printf 'working' > "$state/.agent-status-$key"
  PATH="$fb:$PATH" FM_CREW_BACKEND=herdr FM_STATE_OVERRIDE="$state" \
    FM_FAKE_STATUS=idle FM_FAKE_TEXT='idle' \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_STALE_ESCALATE_SECS=999 "$WATCH" > "$out" 2>/dev/null &
  pid=$!
  wait_path "$state/done2.turn-ended" 40 || { reap "$pid"; fail "watcher did not synthesize .turn-ended on working->idle"; }
  reap "$pid"
  pass "watcher synthesizes a turn-end on the working->idle boundary"
}

# --- 5. a herdr-native "blocked" crew is not idle/stale ----------------------

test_blocked_is_not_stale() {
  local dir state fb out pid key text
  dir="$TMP_ROOT/blocked"; state="$dir/state"; fb=$(make_fake_herdr "$dir")
  mkdir -p "$state"; out="$dir/watch.out"
  text='waiting on a decision'
  printf 'window=w1:p2\nkind=ship\n' > "$state/blk.meta"
  key=$(printf '%s' "w1:p2" | tr ':/.' '___')
  # Prime a stable pane hash + count so the very first poll reaches the stale gate
  # (n>=2). A blocked level must still NOT trip stale.
  printf '%s' "$(hash_text "$text")" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # Prime the agent-status marker so synthesis is a no-op (blocked is never a turn-end).
  printf 'blocked' > "$state/.agent-status-$key"

  PATH="$fb:$PATH" FM_CREW_BACKEND=herdr FM_STATE_OVERRIDE="$state" \
    FM_FAKE_STATUS=blocked FM_FAKE_TEXT="$text" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_STALE_ESCALATE_SECS=1 "$WATCH" > "$out" 2>/dev/null &
  pid=$!
  # Give the watcher a few cycles to (not) misclassify the blocked pane.
  if ! wait_live "$pid" 25; then
    wait "$pid" 2>/dev/null || true
    fail "watcher exited on a blocked pane (should treat it as alive, not stale): $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "blocked pane produced a wake reason: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "blocked pane enqueued a (false-)stale wake"; }
  [ ! -e "$state/.stale-since-$key" ] || { reap "$pid"; fail "blocked pane started a stale escalation timer"; }
  [ ! -e "$state/blk.turn-ended" ] || { reap "$pid"; fail "blocked pane was wrongly synthesized as a turn-end"; }
  reap "$pid"
  pass "a herdr-native blocked crew is not idle/stale: no wake, no timer, no turn-end"
}

test_window_to_task_herdr_pane_id
test_window_for_task_herdr_meta
test_discover_supervisor_target_herdr
test_turnend_synthesized_on_done
test_turnend_synthesized_on_working_to_idle
test_blocked_is_not_stale
