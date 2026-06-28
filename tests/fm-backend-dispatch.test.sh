#!/usr/bin/env bash
# Backend dispatcher (bin/fm-backend-lib.sh) — selection + seam wiring.
#
# Slice 1 of the tmux->herdr migration adds a reversible backend seam selected by
# config/crew-backend (mirroring config/crew-harness). These tests pin:
#   1. Default / "default" / "tmux" / absent config all select the tmux backend,
#      which exposes BOTH the fm_be_* seam and the historical fm_tmux_*/fm_pane_*
#      names current call sites still call.
#   2. config/crew-backend=herdr selects the herdr backend, which LOADS cleanly
#      and exposes the same fm_be_* seam + historical names as tmux (the backend's
#      own behavior is covered by tests/fm-herdr-backend.test.sh; this file only
#      pins selection + seam wiring).
#   3. FM_CREW_BACKEND overrides the config file.
#   4. An unknown backend name fails the source loudly.
#   5. The NEW tmux fm_be_agent_status maps busy->working, idle->idle, gone->none.
#
# The dispatcher is sourced from $DISPATCH inside throwaway subshells, each with a
# deliberately subshell-local FM_HOME so backend selection is isolated per case;
# silence the directives that flags that intentional, dynamic pattern file-wide.
# shellcheck disable=SC1090,SC2030,SC2031
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DISPATCH="$ROOT/bin/fm-backend-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-backend-dispatch)

mk_home() {  # <name> [backend-value]
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config"
  [ "$#" -ge 2 ] && printf '%s\n' "$2" > "$home/config/crew-backend"
  printf '%s\n' "$home"
}

# --- 1. tmux is the default and exposes both seams --------------------------

test_default_selects_tmux() {
  local home name
  home=$(mk_home default-no-config)
  name=$( unset FM_CREW_BACKEND; export FM_HOME="$home"; . "$DISPATCH" >/dev/null 2>&1; fm_backend_name )
  [ "$name" = tmux ] || fail "absent config did not default to tmux: '$name'"

  # The tmux backend must define the fm_be_* seam AND the historical names.
  (
    unset FM_CREW_BACKEND; export FM_HOME="$home"
    . "$DISPATCH" >/dev/null 2>&1
    for f in fm_be_create_window fm_be_window_exists fm_be_resolve fm_be_run_cmd \
             fm_be_send_text fm_be_send_key fm_be_submit_verify fm_be_capture \
             fm_be_pane_alive fm_be_pane_cwd fm_be_agent_status fm_be_kill_window \
             fm_be_composer_state fm_pane_is_busy fm_tmux_submit_core \
             fm_pane_input_pending fm_tmux_strip_ghost; do
      type "$f" >/dev/null 2>&1 || { echo "missing: $f" >&2; exit 1; }
    done
  ) || fail "tmux backend did not expose the full seam + historical names"
  pass "absent config selects the tmux backend with fm_be_* and fm_tmux_* present"
}

test_explicit_tmux_and_default_values() {
  local home name v
  for v in tmux default __empty__; do
    if [ "$v" = __empty__ ]; then
      home=$(mk_home "val-empty"); : > "$home/config/crew-backend"
    else
      home=$(mk_home "val-$v" "$v")
    fi
    name=$( unset FM_CREW_BACKEND; export FM_HOME="$home"; . "$DISPATCH" >/dev/null 2>&1; fm_backend_name )
    [ "$name" = tmux ] || fail "config value '$v' did not resolve to tmux: '$name'"
  done
  pass "config 'tmux', 'default', and empty all resolve to the tmux backend"
}

# --- 2. herdr loads cleanly and exposes the full seam -----------------------
# Slice 3 replaced the herdr stub with a real backend; this test now pins that
# config=herdr selects it, sources cleanly, and exposes the same fm_be_* seam +
# historical names as tmux. The backend's behavior lives in fm-herdr-backend.test.sh.

test_herdr_selected_and_exposes_seam() {
  local home name
  home=$(mk_home herdr-home herdr)
  name=$( unset FM_CREW_BACKEND; export FM_HOME="$home"; . "$DISPATCH" >/dev/null 2>&1; fm_backend_name )
  [ "$name" = herdr ] || fail "config=herdr did not select herdr: '$name'"

  # Sourcing must SUCCEED (the lib only defines functions; no herdr call at load).
  ( unset FM_CREW_BACKEND; export FM_HOME="$home"; . "$DISPATCH" ) >/dev/null 2>&1 \
    || fail "sourcing the herdr backend failed at load time"

  # The herdr backend must define the fm_be_* seam AND the historical names that
  # current call sites still call directly, exactly like the tmux backend.
  (
    unset FM_CREW_BACKEND; export FM_HOME="$home"
    . "$DISPATCH" >/dev/null 2>&1
    for f in fm_be_create_window fm_be_window_exists fm_be_resolve fm_be_run_cmd \
             fm_be_send_text fm_be_send_key fm_be_submit_verify fm_be_capture \
             fm_be_pane_alive fm_be_pane_cwd fm_be_agent_status fm_be_kill_window \
             fm_be_composer_state fm_pane_is_busy fm_tmux_submit_core \
             fm_pane_input_pending fm_tmux_strip_ghost; do
      type "$f" >/dev/null 2>&1 || { echo "missing: $f" >&2; exit 1; }
    done
  ) || fail "herdr backend did not expose the full seam + historical names"
  pass "config=herdr selects the herdr backend with fm_be_* and fm_tmux_* present"
}

# --- 3. env override beats the file -----------------------------------------

test_env_override_beats_config() {
  local home name
  home=$(mk_home env-override tmux)
  name=$( export FM_HOME="$home" FM_CREW_BACKEND=herdr; . "$DISPATCH" >/dev/null 2>&1; fm_backend_name )
  [ "$name" = herdr ] || fail "FM_CREW_BACKEND=herdr did not override config=tmux: '$name'"
  pass "FM_CREW_BACKEND overrides config/crew-backend"
}

# --- 4. unknown backend fails the source loudly -----------------------------

test_unknown_backend_rejected() {
  local home out rc
  home=$(mk_home bogus-home wat)
  out=$( unset FM_CREW_BACKEND; export FM_HOME="$home"; . "$DISPATCH" 2>&1 ); rc=$?
  [ "$rc" -ne 0 ] || fail "unknown backend 'wat' sourced successfully (should fail)"
  assert_contains "$out" "unknown crew backend" \
    "unknown backend did not print the rejection diagnostic"
  pass "an unknown crew backend fails the source loudly"
}

# --- 5. tmux fm_be_agent_status mapping (busy->working, idle->idle, gone->none)

# A fake tmux: display-message exit reflects FM_FAKE_ALIVE (pane liveness);
# capture-pane emits a busy footer when FM_FAKE_BUSY=1, else an idle line.
make_fake_tmux() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message) [ "${FM_FAKE_ALIVE:-1}" = 1 ] && { printf '%%1\n'; exit 0; }; exit 1 ;;
  capture-pane)
    if [ "${FM_FAKE_BUSY:-0}" = 1 ]; then printf 'doing things\nesc to interrupt\n'
    else printf 'all done here\n'; fi
    exit 0 ;;
esac
exit 1
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

test_agent_status_mapping() {
  local home fb got
  home=$(mk_home agentstatus); fb=$(make_fake_tmux "$TMP_ROOT/agentstatus")

  got=$( unset FM_CREW_BACKEND; export FM_HOME="$home" PATH="$fb:$PATH" FM_FAKE_ALIVE=1 FM_FAKE_BUSY=1
         . "$DISPATCH" >/dev/null 2>&1; fm_be_agent_status w:1 )
  [ "$got" = working ] || fail "busy pane should map to working, got '$got'"

  got=$( unset FM_CREW_BACKEND; export FM_HOME="$home" PATH="$fb:$PATH" FM_FAKE_ALIVE=1 FM_FAKE_BUSY=0
         . "$DISPATCH" >/dev/null 2>&1; fm_be_agent_status w:1 )
  [ "$got" = idle ] || fail "idle pane should map to idle, got '$got'"

  got=$( unset FM_CREW_BACKEND; export FM_HOME="$home" PATH="$fb:$PATH" FM_FAKE_ALIVE=0
         . "$DISPATCH" >/dev/null 2>&1; fm_be_agent_status w:1 )
  [ "$got" = none ] || fail "gone pane should map to none, got '$got'"
  pass "tmux fm_be_agent_status maps busy->working, idle->idle, gone->none"
}

test_default_selects_tmux
test_explicit_tmux_and_default_values
test_herdr_selected_and_exposes_seam
test_env_override_beats_config
test_unknown_backend_rejected
test_agent_status_mapping
