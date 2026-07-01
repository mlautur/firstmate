#!/usr/bin/env bash
# Spawn on the herdr backend (slice 4 of the tmux->herdr migration).
#
# fm-spawn.sh drives crewmate window create + the treehouse-get / brief-launch
# sends through the fm_be_* seam, so selecting config/crew-backend=herdr launches a
# crewmate via herdr instead of tmux. These tests pin the two slice-4 behaviors:
#
#   1. Handle recording: under herdr, state/<id>.meta window= holds the herdr
#      pane_id returned by fm_be_create_window (not a tmux session:window), the
#      worktree= holds the cwd herdr reports, and the spawn flow routes
#      `treehouse get` (pane run) and the brief launch (pane send-text + send-keys
#      Enter) through herdr.
#   2. Turn-end hook skip gate: with the herdr backend AND a CURRENT herdr
#      integration for the harness, the per-harness turn-end hook
#      (.claude/settings.local.json) is NOT installed - herdr reports the turn-end
#      natively. If the integration is absent/not-current, the hook is installed as
#      a defensive fallback and a warning is emitted.
#
# Everything runs against a FAKE `herdr` on PATH (no server) plus a REAL git
# project + worktree so the spawn worktree-isolation guard passes deterministically.
# CI-safe, mirrors tests/fm-herdr-backend.test.sh.
#
# Subshell-local FM_HOME/PATH; silence the dynamic-source/subshell directives.
# shellcheck disable=SC1090,SC2030,SC2031
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-herdr)

# A fake `herdr` covering exactly the verbs fm-spawn drives under the herdr backend.
# It logs every argv to $FM_FAKE_HERDR_LOG. `pane get` returns FM_FAKE_CWD as .cwd
# so the spawn cwd-poll lands the worktree; `integration status` is controlled by
# FM_FAKE_INTEGRATION (current|absent) to exercise the hook-skip gate.
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
    printf '{"result":{"workspaces":[{"workspace_id":"%s","label":"firstmate"}]}}\n' \
      "${FM_FAKE_WS_ID:-w1}" ;;
  "workspace create")
    printf '{"result":{"workspace":{"workspace_id":"%s"}}}\n' "${FM_FAKE_WS_ID:-w1}" ;;
  "tab create")
    printf '{"result":{"root_pane":{"pane_id":"%s"}}}\n' "${FM_FAKE_PANE_ID:-w1:p2}" ;;
  "pane list")
    # No pre-existing pane carries the requested label (no duplicate).
    printf '{"result":{"panes":[]}}\n' ;;
  "pane get")
    [ "${FM_FAKE_DEAD:-0}" = 1 ] && { printf '{"error":{"code":"pane_not_found"}}\n'; exit 1; }
    printf '{"result":{"pane":{"pane_id":"%s","agent_status":"working","cwd":"%s"}}}\n' \
      "${FM_FAKE_PANE_ID:-w1:p2}" "${FM_FAKE_CWD:-/wt}" ;;
  "pane rename") printf '{"result":{"type":"ok"}}\n' ;;
  "pane run") exit 0 ;;
  "pane send-text") exit 0 ;;
  "pane send-keys") exit 0 ;;
  "pane close") printf '{"result":{"type":"ok"}}\n' ;;
  "integration status")
    case "${FM_FAKE_INTEGRATION:-current}" in
      current) printf '%s\n' "claude: current (v6) ($HOME/.claude/hooks/herdr-agent-state.sh)" ;;
      *)       printf '%s\n' "claude: not installed ($HOME/.claude/hooks/herdr-agent-state.sh)" ;;
    esac
    printf '%s\n' "codex: not installed ($HOME/.codex/herdr-agent-state.sh)" ;;
  *) printf 'fake-herdr: unhandled %s %s\n' "$noun" "$verb" >&2; exit 1 ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

# Build one spawn sandbox. Sets up:
#   $CASE/home/           - firstmate home (config/crew-backend=herdr, data/<id>/brief.md)
#   $CASE/fakebin/        - the fake herdr (PATH-prepended)
#   $CASE/project/        - a real git project clone
#   $CASE/wt/             - a real worktree of the project (what herdr "reports" as cwd)
# Echoes "<case_dir> <fakebin> <home> <project> <wt>".
make_case() {  # <name> <task-id>
  local name=$1 id=$2 case_dir fb home proj wt
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir"
  fb=$(make_fake_herdr "$case_dir")
  home="$case_dir/home"
  mkdir -p "$home/config" "$home/data/$id" "$home/state"
  printf 'herdr\n' > "$home/config/crew-backend"
  printf 'do the trivial thing\n' > "$home/data/$id/brief.md"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fm_git_worktree "$proj" "$wt" "fm/seed-$id"
  printf '%s %s %s %s %s\n' "$case_dir" "$fb" "$home" "$proj" "$wt"
}

# Run fm-spawn under the herdr backend with the fake herdr on PATH. The worktree
# cwd herdr "reports" is the real $wt (pwd -P resolved so the isolation guard's
# realpath compare is exact). Echoes spawn's combined stdout+stderr; sets META.
run_spawn_herdr() {  # <id> <fakebin> <home> <project> <wt> <integration> [extra env...]
  local id=$1 fb=$2 home=$3 proj=$4 wt=$5 integ=$6 wt_real
  wt_real=$(cd "$wt" && pwd -P)
  FM_ROOT_OVERRIDE='' \
    FM_HOME="$home" \
    FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_CREW_BACKEND='' \
    FM_SPAWN_NO_GUARD=1 \
    FM_FAKE_HERDR_LOG="$home/herdr.log" \
    FM_FAKE_PANE_ID="${FM_FAKE_PANE_ID:-w7:p3}" \
    FM_FAKE_CWD="$wt_real" \
    FM_FAKE_INTEGRATION="$integ" \
    PATH="$fb:$PATH" \
    "$SPAWN" "$id" "$proj" claude 2>&1
}

# --- 1. handle recording + send routing -------------------------------------

test_spawn_records_pane_id_and_routes_sends() {
  local id=task-herdr-h1 fields case_dir fb home proj wt out meta log proj_abs
  fields=$(make_case handle "$id")
  read -r case_dir fb home proj wt <<<"$fields"
  : "$case_dir"
  # spawn resolves the project arg to an absolute dir with `cd … && pwd`; mirror
  # that exactly so the tab-create --cwd assertion is symlink/realpath robust.
  proj_abs=$(cd "$proj" && pwd)

  out=$(FM_FAKE_PANE_ID=w9:p4 run_spawn_herdr "$id" "$fb" "$home" "$proj" "$wt" current) \
    || fail "herdr spawn should succeed:"$'\n'"$out"

  meta="$home/state/$id.meta"
  assert_present "$meta" "spawn did not write the task meta"
  assert_grep "window=w9:p4" "$meta" "meta window= must record the herdr pane_id handle"
  assert_grep "harness=claude" "$meta" "meta should record harness=claude"
  # worktree= is the cwd herdr reported (the isolation-guard-validated worktree).
  grep -q "^worktree=$(cd "$wt" && pwd -P)$" "$meta" \
    || fail "meta worktree= must record the herdr-reported worktree cwd"
  assert_contains "$out" "window=w9:p4" "spawn summary should echo the pane_id handle"

  # The treehouse-get and brief launch went through herdr, not tmux.
  log="$home/herdr.log"
  assert_grep "tab create --workspace w1 --cwd $proj_abs --label fm-$id --no-focus" "$log" \
    "spawn did not create the task tab in the firstmate workspace"
  assert_grep "pane run w9:p4 treehouse get" "$log" \
    "treehouse get was not run through herdr pane run"
  assert_grep "pane send-text w9:p4" "$log" \
    "the brief launch text was not typed through herdr pane send-text"
  assert_grep "pane send-keys w9:p4 Enter" "$log" \
    "the brief launch was not submitted through herdr pane send-keys Enter"
  pass "herdr spawn records the pane_id handle and routes treehouse-get + brief launch through herdr"
}

# --- 2. turn-end hook skip gate ---------------------------------------------

test_hook_skipped_when_integration_current() {
  local id=task-herdr-h2 fields case_dir fb home proj wt out
  fields=$(make_case hookskip "$id")
  read -r case_dir fb home proj wt <<<"$fields"
  : "$case_dir"

  out=$(run_spawn_herdr "$id" "$fb" "$home" "$proj" "$wt" current) \
    || fail "herdr spawn (integration current) should succeed:"$'\n'"$out"

  assert_absent "$wt/.claude/settings.local.json" \
    "the per-harness turn-end hook must be SKIPPED when herdr reports a current integration"
  assert_not_contains "$out" "installing turn-end hook as a fallback" \
    "no fallback warning should be emitted when the integration is current"
  pass "herdr + current integration: turn-end hook is skipped (herdr reports done natively)"
}

test_hook_installed_when_integration_absent() {
  local id=task-herdr-h3 fields case_dir fb home proj wt out
  fields=$(make_case hookfallback "$id")
  read -r case_dir fb home proj wt <<<"$fields"
  : "$case_dir"

  out=$(run_spawn_herdr "$id" "$fb" "$home" "$proj" "$wt" absent) \
    || fail "herdr spawn (integration absent) should still succeed:"$'\n'"$out"

  assert_present "$wt/.claude/settings.local.json" \
    "the turn-end hook must be installed defensively when no current herdr integration exists"
  # spawn canonicalizes the state dir (STATE_REAL=$(cd "$STATE" && pwd -P)) before
  # composing the turn-ended path, so resolve $home/state the same way to match.
  state_real=$(cd "$home/state" && pwd -P)
  assert_grep "$state_real/$id.turn-ended" "$wt/.claude/settings.local.json" \
    "the fallback hook should touch the task's turn-ended file"
  assert_contains "$out" "installing turn-end hook as a fallback" \
    "spawn should note the defensive hook fallback when the integration is not current"
  pass "herdr + absent integration: turn-end hook is installed defensively with a noted fallback"
}

# --- 3. tmux backend stays unchanged ----------------------------------------
# The slice-4 gate keys the hook-skip on BACKEND=herdr, so the default (tmux)
# backend must behave exactly as before: meta window= records a tmux
# session:window handle and the per-harness turn-end hook is ALWAYS installed.
# Uses a fake tmux (no real server) plus the same real worktree.

make_fake_tmux() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_TMUX_LOG:-/dev/null}"
case "${1:-} ${2:-}" in
  "has-session "*) exit 1 ;;                 # force new-session (no live server)
  "new-session "*) exit 0 ;;
  "list-windows "*) exit 0 ;;                # no existing windows -> empty list
  "new-window "*) exit 0 ;;
  "send-keys "*) exit 0 ;;
  "display-message "*)
    case " $* " in
      *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_CWD:-/wt}" ;;
      *"#S"*) printf 'firstmate\n' ;;
    esac ;;
  *) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

test_tmux_backend_records_window_and_installs_hook() {
  local id=task-tmux-h4 case_dir fb home proj wt out meta wt_real
  case_dir="$TMP_ROOT/tmuxdefault"
  mkdir -p "$case_dir"
  fb=$(make_fake_tmux "$case_dir")
  home="$case_dir/home"
  mkdir -p "$home/config" "$home/data/$id" "$home/state"
  printf 'tmux\n' > "$home/config/crew-backend"   # explicit default backend
  printf 'do the trivial thing\n' > "$home/data/$id/brief.md"
  proj="$case_dir/project"; wt="$case_dir/wt"
  fm_git_worktree "$proj" "$wt" "fm/seed-$id"
  wt_real=$(cd "$wt" && pwd -P)

  out=$( unset TMUX
         FM_ROOT_OVERRIDE='' FM_HOME="$home" \
         FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
         FM_CREW_BACKEND='' FM_SPAWN_NO_GUARD=1 \
         FM_FAKE_TMUX_LOG="$home/tmux.log" FM_FAKE_CWD="$wt_real" \
         PATH="$fb:$PATH" \
         "$SPAWN" "$id" "$proj" claude 2>&1 ) \
    || fail "tmux-backend spawn should succeed:"$'\n'"$out"

  meta="$home/state/$id.meta"
  assert_grep "window=firstmate:fm-$id" "$meta" \
    "tmux backend must record a session:window handle, unchanged from before"
  assert_present "$wt/.claude/settings.local.json" \
    "tmux backend must ALWAYS install the per-harness turn-end hook"
  assert_not_contains "$out" "installing turn-end hook as a fallback" \
    "the herdr fallback warning must never fire on the tmux backend"
  pass "tmux backend unchanged: session:window handle recorded and turn-end hook installed"
}

test_spawn_records_pane_id_and_routes_sends
test_hook_skipped_when_integration_current
test_hook_installed_when_integration_absent
test_tmux_backend_records_window_and_installs_hook
