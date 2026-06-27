#!/usr/bin/env bash
# fm-herdr-lib.sh — herdr backend STUB for firstmate's pane primitives.
#
# Slice 1 of the tmux->herdr migration introduces the backend seam but does NOT
# implement herdr; that is slice 3 (see data/herdr-migration-scout-h1/report.md
# §4). This stub defines the full fm_be_* interface (and the historical
# fm_tmux_*/fm_pane_* names current call sites still call directly) so that
# selecting config/crew-backend=herdr LOADS cleanly through the dispatcher and
# then FAILS LOUDLY the moment any backend primitive is used, rather than
# silently misbehaving or dying on a bare "command not found".
#
# Every function prints a clear "not yet implemented" diagnostic to stderr and
# returns non-zero. Safe to source into `set -eu` contexts: sourcing only defines
# functions, so the deferred failure surfaces at call time, not load time.

FM_HERDR_NOT_IMPL_MSG='herdr backend not yet implemented (tmux->herdr migration slice 3); set config/crew-backend=tmux to use the tmux backend'

# fm_herdr_not_implemented <fn-name>: emit the standard diagnostic and fail.
fm_herdr_not_implemented() {
  printf 'fm-herdr-lib: %s: %s\n' "${1:-fm_be_*}" "$FM_HERDR_NOT_IMPL_MSG" >&2
  return 1
}

# --- stable fm_be_* seam (filled in slice 3) --------------------------------
fm_be_create_window()  { fm_herdr_not_implemented fm_be_create_window; }
fm_be_window_exists()  { fm_herdr_not_implemented fm_be_window_exists; }
fm_be_resolve()        { fm_herdr_not_implemented fm_be_resolve; }
fm_be_run_cmd()        { fm_herdr_not_implemented fm_be_run_cmd; }
fm_be_send_text()      { fm_herdr_not_implemented fm_be_send_text; }
fm_be_send_key()       { fm_herdr_not_implemented fm_be_send_key; }
fm_be_submit_verify()  { fm_herdr_not_implemented fm_be_submit_verify; }
fm_be_capture()        { fm_herdr_not_implemented fm_be_capture; }
fm_be_pane_alive()     { fm_herdr_not_implemented fm_be_pane_alive; }
fm_be_pane_cwd()       { fm_herdr_not_implemented fm_be_pane_cwd; }
fm_be_agent_status()   { fm_herdr_not_implemented fm_be_agent_status; }
fm_be_kill_window()    { fm_herdr_not_implemented fm_be_kill_window; }
fm_be_composer_state() { fm_herdr_not_implemented fm_be_composer_state; }

# --- historical names current call sites still use directly -----------------
# fm-send.sh, fm-crew-state.sh and bin/fm-supervise-daemon.sh call these by name.
# Kept here as erroring shims so a herdr-backed run of those scripts fails loudly
# with the same diagnostic instead of "command not found".
fm_tmux_strip_ghost()       { fm_herdr_not_implemented fm_tmux_strip_ghost; }
fm_tmux_composer_state()    { fm_herdr_not_implemented fm_tmux_composer_state; }
fm_pane_input_pending()     { fm_herdr_not_implemented fm_pane_input_pending; }
fm_pane_is_busy()           { fm_herdr_not_implemented fm_pane_is_busy; }
fm_tmux_submit_enter_core() { fm_herdr_not_implemented fm_tmux_submit_enter_core; }
fm_tmux_submit_core()       { fm_herdr_not_implemented fm_tmux_submit_core; }
