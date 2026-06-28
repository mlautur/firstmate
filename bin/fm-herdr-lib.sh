#!/usr/bin/env bash
# fm-herdr-lib.sh — the herdr backend behind firstmate's crew-pane seam.
#
# This is the herdr implementation of the backend interface dispatched by
# bin/fm-backend-lib.sh (config/crew-backend = herdr). It mirrors, function for
# function, the contract of the tmux backend (bin/fm-tmux-lib.sh): the stable
# fm_be_* seam plus the historical fm_tmux_*/fm_pane_* names that current call
# sites (fm-send.sh, fm-supervise-daemon.sh, fm-crew-state.sh) still call
# directly, so every consumer is backend-agnostic. See
# data/herdr-migration-scout-h1/report.md §2 for the verified tmux->herdr command
# mapping and Appendix A for the empirical evidence this implementation is built on.
#
# Scope (migration slice 3): this fills the observation/IO primitives so that
# selecting config/crew-backend=herdr actually drives crewmate panes through
# herdr. It does NOT switch fm-spawn/fm-teardown/fm-watch to USE the seam on herdr
# (slices 4/5); the default backend stays tmux and this code is dormant until the
# backend is selected. Harness scope is claude only (its herdr integration reports
# native agent_status).
#
# herdr model (v0.7.0, socket API): session -> workspace -> tab -> pane -> agent.
# firstmate maps one shared "firstmate" workspace, one tab (and its single pane)
# per task. The canonical handle stored in state/<id>.meta window= and accepted by
# every fm_be_* below is the herdr **pane_id** (e.g. "w7:p1") — stable and
# unambiguous (report §2a).
#
# JSON vs text (verified, Appendix A): `herdr <noun> list|get|create` emit JSON on
# stdout (parsed with jq); `herdr pane read --format text|ansi` emits RAW terminal
# text (NOT JSON); `herdr pane run|send-text|send-keys|rename|close` emit a small
# JSON ack or nothing and signal success via exit status. A missing pane fails the
# call with a non-zero exit, which every primitive below relies on.
#
# The big win (report §2d): herdr exposes a native per-pane agent_status
# (idle|working|blocked|done|unknown) and synthesizes "done" on a working->idle
# transition (the turn-end signal). fm_be_agent_status reads it directly — no
# busy-regex, no pane-hash. The composer/ghost-text machinery below is kept as a
# best-effort fallback only; under a working claude integration it is mooted.
#
# All functions are `set -u`/`set -e` safe (guarded calls, explicit returns) so
# they can be sourced into either the daemon or fm-send.

# The herdr binary and the shared workspace label are overridable for tests and
# for multi-home isolation. Default label "firstmate" reuses the captain's live
# workspace exactly as the tmux backend reuses the "firstmate" session.
FM_HERDR_BIN="${FM_HERDR_BIN:-herdr}"
FM_HERDR_WORKSPACE_LABEL="${FM_HERDR_WORKSPACE_LABEL:-firstmate}"

# Busy footers per harness — used ONLY by the best-effort composer fallback below
# (fm_pane_is_busy reads native agent_status, not this regex). Mirrors fm-tmux-lib.
FM_HERDR_BUSY_REGEX_DEFAULT='esc (to )?interrupt|Working\.\.\.'

# fm_herdr_is_pane_id <s>: 0 if <s> looks like a herdr pane handle, 1 otherwise
# (i.e. it is a label/agent name to resolve). herdr pane ids are "w<ws>:p<n>",
# where the workspace suffix is NOT always numeric (verified: w5, w8, wA, ...), so
# match "w*:p*" rather than requiring digits; a tab id "w<ws>:t<n>" or a firstmate
# label "fm-<id>" (no ":p") correctly falls through to the label path. Lets the
# resolve/exists primitives accept either an opaque handle or a human name, like
# the tmux backend.
fm_herdr_is_pane_id() {
  case "$1" in
    w*:p*) return 0 ;;
    *) return 1 ;;
  esac
}

# fm_herdr_pane_by_label <label> [workspace_id]: echo the pane_id of the pane
# carrying <label>, searching one workspace when given, else the whole fleet.
# Empty output (and success) when nothing matches; callers test for non-empty.
fm_herdr_pane_by_label() {  # <label> [workspace_id]
  local label=$1
  if [ -n "${2:-}" ]; then
    "$FM_HERDR_BIN" pane list --workspace "$2" 2>/dev/null
  else
    "$FM_HERDR_BIN" pane list 2>/dev/null
  fi | jq -r --arg l "$label" \
        '.result.panes[]? | select(.label==$l) | .pane_id' 2>/dev/null \
     | head -n1
}

# fm_herdr_workspace_id <cwd>: echo the workspace_id of the shared firstmate
# workspace, creating it lazily at <cwd> if absent (report §6 recommendation: one
# "firstmate" workspace, tab-per-task). Fails (non-zero, empty) only if creation
# itself fails.
fm_herdr_workspace_id() {  # <cwd>
  local cwd=$1 wsid
  wsid=$("$FM_HERDR_BIN" workspace list 2>/dev/null \
    | jq -r --arg l "$FM_HERDR_WORKSPACE_LABEL" \
        '.result.workspaces[]? | select(.label==$l) | .workspace_id' 2>/dev/null \
    | head -n1)
  if [ -n "$wsid" ]; then
    printf '%s' "$wsid"
    return 0
  fi
  wsid=$("$FM_HERDR_BIN" workspace create --cwd "$cwd" \
           --label "$FM_HERDR_WORKSPACE_LABEL" --no-focus 2>/dev/null \
         | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)
  [ -n "$wsid" ] || return 1
  printf '%s' "$wsid"
}

# fm_tmux_strip_ghost: identical to the tmux backend's strip — remove dim/faint
# (ANSI SGR 2) runs from one captured composer line, then drop remaining escapes,
# leaving the plain text a human actually typed. Ghost/placeholder text (claude's
# predicted-next-prompt suggestion) is dim and must never read as pending input.
# Reads a styled line on stdin (from `herdr pane read --format ansi`), prints plain
# text. Kept self-contained here because the dispatcher loads exactly ONE backend
# lib, so the herdr backend cannot rely on fm-tmux-lib being sourced; the logic is
# harness-generic and deliberately mirrors fm-tmux-lib.sh's copy byte for byte.
fm_tmux_strip_ghost() {
  LC_ALL=C awk '
    function sgr_code(v, b) {
      b = v
      sub(/:.*/, "", b)
      if (b == "") b = "0"
      return b
    }
    function skip_color_payload(a, p, k, mode, code) {
      if (index(a[p], ":") > 0) return p
      if (p >= k) return p
      mode = a[p + 1]
      code = sgr_code(mode)
      if (index(mode, ":") > 0) return p + 1
      if (code == "5") return p + 2
      if (code == "2") return p + 4
      return p + 1
    }
    {
      line = $0; out = ""; dim = 0; n = length(line); i = 1
      while (i <= n) {
        c = substr(line, i, 1)
        if (c == "\033") {            # ESC: consume a CSI ... final-byte sequence
          j = i + 1
          if (substr(line, j, 1) == "[") {
            j++; params = ""
            while (j <= n) {
              cc = substr(line, j, 1)
              if (cc ~ /[@-~]/) break
              params = params cc; j++
            }
            if (j <= n && substr(line, j, 1) == "m") {   # SGR: update dim/faint state
              if (params == "") params = "0"
              k = split(params, a, ";")
              for (p = 1; p <= k; p++) {
                v = a[p]; code = sgr_code(v)
                if (code == "38" || code == "48" || code == "58") {
                  p = skip_color_payload(a, p, k)
                } else if (code == "2") dim = 1
                else if (code == "0" || code == "22") dim = 0
              }
            }
            if (j <= n) { i = j + 1; continue }
          }
          i = i + 1; continue          # lone/other ESC: drop the ESC byte only
        }
        if (dim == 0) out = out c        # keep only normal-intensity bytes
        i++
      }
      print out
    }
  '
}

# fm_tmux_composer_state: best-effort classify of <target>'s composer row as
# empty|pending|unknown. herdr has no cursor_y, so this reads the last non-blank
# line of the visible ANSI capture (the input box usually sits at the bottom),
# strips dim ghost text and box borders, and asks whether anything real is left.
# This is a SAFETY NET only: under herdr the authoritative "did the turn start /
# is the agent mid-turn" signal is the native agent_status (see fm_pane_is_busy and
# fm_tmux_submit_enter_core), which moots the ghost-text path for an integrated
# harness (report §2d/§3). Named with the historical fm_tmux_ prefix because
# fm-supervise-daemon.sh's pane_input_pending shim calls it by that name.
fm_tmux_composer_state() {  # <target> -> empty|pending|unknown
  local target=$1 raw line stripped
  raw=$(fm_be_capture "$target" 2 ansi 2>/dev/null) || { printf 'unknown'; return 0; }
  line=$(printf '%s\n' "$raw" | fm_tmux_strip_ghost \
         | grep -v '^[[:space:]]*$' | tail -1)
  # Strip the composer box borders (literal glyphs — no character classes).
  stripped=${line//│/}      # U+2502 light vertical (claude)
  stripped=${stripped//┃/}  # U+2503 heavy vertical
  stripped=${stripped//|/}  # ASCII pipe
  # Trim surrounding whitespace.
  stripped="${stripped#"${stripped%%[![:space:]]*}"}"
  stripped="${stripped%"${stripped##*[![:space:]]}"}"
  [ -n "$stripped" ] || { printf 'empty'; return 0; }
  if [ -n "${FM_COMPOSER_IDLE_RE:-}" ] \
     && printf '%s' "$stripped" | grep -qiE "$FM_COMPOSER_IDLE_RE"; then
    printf 'empty'; return 0
  fi
  # Just a bare prompt glyph = empty composer (idle).
  case "$stripped" in
    '>'|'❯'|'$'|'%'|'#') printf 'empty'; return 0 ;;
  esac
  # A busy footer landing on the read line is not pending input.
  if printf '%s' "$stripped" | grep -qiE "${FM_BUSY_REGEX:-$FM_HERDR_BUSY_REGEX_DEFAULT}"; then
    printf 'empty'; return 0
  fi
  printf 'pending'; return 0
}

# fm_pane_input_pending <target>: 0 (pending) if the composer holds real
# unsubmitted text, 1 otherwise. An unreadable pane is treated as NOT pending
# (fail-safe, same bias as the tmux backend).
fm_pane_input_pending() {  # <target>
  [ "$(fm_tmux_composer_state "$1")" = pending ]
}

# fm_pane_is_busy <target>: 0 if the agent is mid-turn. Under herdr this is the
# native agent_status == "working" (report §2d) — no 40-line tail, no busy-regex.
fm_pane_is_busy() {  # <target>
  [ "$(fm_be_agent_status "$1")" = working ]
}

# fm_tmux_submit_enter_core: submit with Enter and verify the turn began, retrying
# Enter ONLY (never retyping). Primary signal is the native agent_status reaching
# working/done/blocked (the turn started — report §2b); the composer read is a
# fallback for panes without a reporting integration. Echoes the tmux contract
# verdict (empty|pending|unknown|send-failed): "empty" == landed.
fm_tmux_submit_enter_core() {  # <target> <retries> <enter-sleep>
  local target=$1 retries=$2 sleep_s=$3 i=0 st cs
  while :; do
    fm_be_send_key "$target" Enter 2>/dev/null || true
    sleep "$sleep_s"
    # Primary (semantic): did the agent's turn begin? Edge-tolerant LEVEL read —
    # never `herdr wait agent-status`, which is edge-triggered (report §2e).
    st=$(fm_be_agent_status "$target")
    case "$st" in
      working|done|blocked) printf 'empty'; return 0 ;;
    esac
    # Fallback: inspect the composer (best-effort, ghost-aware).
    cs=$(fm_tmux_composer_state "$target")
    [ "$cs" = pending ] || { printf '%s' "$cs"; return 0; }
    i=$((i + 1))
    [ "$i" -lt "$retries" ] || { printf 'pending'; return 0; }
  done
}

# fm_tmux_submit_core: type <text> ONCE (send-text), settle, then submit-and-verify
# with fm_tmux_submit_enter_core. Mirrors the tmux backend's signature and verdicts
# exactly so fm-send.sh and the daemon read one contract regardless of backend.
fm_tmux_submit_core() {  # <target> <text> <retries> <enter-sleep> <settle>
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5
  fm_be_send_text "$target" "$text" 2>/dev/null || { printf 'send-failed'; return 0; }
  sleep "$settle"
  fm_tmux_submit_enter_core "$target" "$retries" "$sleep_s"
}

# ============================================================================
# Backend seam (fm_be_*) — herdr implementation.
#
# Same stable interface the tmux backend provides (dispatched by
# bin/fm-backend-lib.sh). Handle model: every fm_be_* accepts the herdr pane_id
# ("wN:pM"); fm_be_resolve/window_exists additionally accept a label/agent name.
# ============================================================================

# fm_be_create_window <id> <cwd> <label> -> echoes handle (pane_id).
# Reuse the shared "firstmate" workspace (create lazily if absent), create a tab
# per task at <cwd> labeled <label> (= fm-<id>), rename its pane to the same label
# so it is resolvable by name, and echo the pane_id. Refuses a duplicate label in
# the workspace (parity with the tmux backend's duplicate-window rejection).
fm_be_create_window() {  # <id> <cwd> <label>
  local cwd=$2 label=$3 wsid pid
  wsid=$(fm_herdr_workspace_id "$cwd") || return 1
  [ -n "$wsid" ] || return 1
  if [ -n "$(fm_herdr_pane_by_label "$label" "$wsid")" ]; then
    printf 'fm_be_create_window: pane labeled %s already exists in workspace %s\n' \
      "$label" "$wsid" >&2
    return 1
  fi
  pid=$("$FM_HERDR_BIN" tab create --workspace "$wsid" --cwd "$cwd" \
          --label "$label" --no-focus 2>/dev/null \
        | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
  [ -n "$pid" ] || return 1
  "$FM_HERDR_BIN" pane rename "$pid" "$label" >/dev/null 2>&1 || true
  printf '%s' "$pid"
}

# fm_be_window_exists <handle|label> -> 0 if a matching pane exists, else 1.
fm_be_window_exists() {  # <handle|label>
  if fm_herdr_is_pane_id "$1"; then
    "$FM_HERDR_BIN" pane get "$1" >/dev/null 2>&1
  else
    [ -n "$(fm_herdr_pane_by_label "$1")" ]
  fi
}

# fm_be_resolve <name|handle> -> echoes a pane_id handle, or fails.
# A pane_id passes through unchanged (parity with the tmux backend, which passes a
# qualified session:window through without verifying); a bare label/agent name is
# resolved to its pane_id via the fleet pane list.
fm_be_resolve() {  # <name|handle>
  local pid
  if fm_herdr_is_pane_id "$1"; then
    printf '%s' "$1"
    return 0
  fi
  pid=$(fm_herdr_pane_by_label "$1")
  [ -n "$pid" ] || return 1
  printf '%s' "$pid"
}

# The action primitives below mirror tmux's silent send-keys: their value is the
# side effect plus the exit status, never stdout. herdr's `pane run/send-text/
# send-keys` are silent today, but `pane close` (and other verbs) print a JSON ack,
# so every action primitive discards stdout (keeping stderr + exit status). This
# guarantees a herdr ack can never corrupt a captured verdict — fm_tmux_submit_core
# runs fm_be_send_text/fm_be_send_key on the same stdout it echoes its verdict on.

# fm_be_run_cmd <handle> <cmd>: type a shell command and submit it (text + Enter).
fm_be_run_cmd() {  # <handle> <cmd>
  "$FM_HERDR_BIN" pane run "$1" "$2" >/dev/null
}

# fm_be_send_text <handle> <text>: type literal text, no Enter.
fm_be_send_text() {  # <handle> <text>
  "$FM_HERDR_BIN" pane send-text "$1" "$2" >/dev/null
}

# fm_be_send_key <handle> <key...>: send one or more named keys (Enter/Escape/C-c).
fm_be_send_key() {  # <handle> <key...>
  local handle=$1
  shift
  "$FM_HERDR_BIN" pane send-keys "$handle" "$@" >/dev/null
}

# fm_be_submit_verify <handle> <text> <retries> <enter-sleep> <settle>
#   -> empty|pending|unknown|send-failed   (the verify-and-retry submit contract).
fm_be_submit_verify() {  # <handle> <text> <retries> <enter-sleep> <settle>
  fm_tmux_submit_core "$@"
}

# fm_be_capture <handle> <lines> [ansi]: echo the last <lines> rows of the pane.
# herdr `pane read --source visible` returns the on-screen viewport; `--lines` does
# not tail it (verified Appendix A), so cap to the last <lines> with tail to honor
# the "last N lines" contract while preserving herdr's non-zero exit on a dead pane
# (fm-watch's staleness loop relies on that exit to skip gone panes). NOTE vs tmux:
# `visible` exposes the on-screen rows, not deep scrollback like tmux `-S -N`, so a
# peek shows the current screen rather than N lines of history (report §3 risk 2).
# With a non-empty third arg, preserve ANSI styling (--format ansi) for the
# ghost-text path; otherwise plain text (the peek/busy analog).
fm_be_capture() {  # <handle> <lines> [ansi]
  local fmt=text out rc
  [ -n "${3:-}" ] && fmt=ansi
  out=$("$FM_HERDR_BIN" pane read "$1" --source visible --lines "$2" \
          --format "$fmt" 2>/dev/null)
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s\n' "$out" | tail -n "$2"
}

# fm_be_pane_alive <handle> -> 0 if the handle resolves to a live pane, else 1.
fm_be_pane_alive() {  # <handle>
  "$FM_HERDR_BIN" pane get "$1" >/dev/null 2>&1
}

# fm_be_pane_cwd <handle> -> echo the pane's current working directory.
# Prefer .cwd, fall back to .foreground_cwd (both verified to report a worktree
# path — report §2d), so the spawn worktree-isolation guard reads the same value
# it reads from tmux's #{pane_current_path}.
fm_be_pane_cwd() {  # <handle>
  "$FM_HERDR_BIN" pane get "$1" 2>/dev/null \
    | jq -r '.result.pane | (.cwd // .foreground_cwd // empty)' 2>/dev/null
}

# fm_be_agent_status <handle> -> idle|working|blocked|done|unknown|none.
# The big win: herdr reports a native per-pane agent_status, and synthesizes
# "done" on a working->idle transition (the turn-end signal) — report §2d. This is
# the unifying read the watcher/crew-state consume regardless of backend; the tmux
# backend derives only working/idle/none from busy-regex+hash, while herdr supplies
# done/blocked/unknown directly. "none" means the pane does not exist (parity with
# the tmux backend); "unknown" means the pane exists but its agent state is unknown.
fm_be_agent_status() {  # <handle>
  local out st
  out=$("$FM_HERDR_BIN" pane get "$1" 2>/dev/null) || { printf 'none'; return 0; }
  st=$(printf '%s' "$out" | jq -r '.result.pane.agent_status // empty' 2>/dev/null)
  case "$st" in
    idle|working|blocked|done) printf '%s' "$st" ;;
    *) printf 'unknown' ;;
  esac
}

# fm_be_kill_window <handle>: close the task's pane (teardown path). herdr
# auto-removes the now-empty tab (verified Appendix A: closing a tab's last pane
# closes the tab), so one call covers "pane close (and close the tab if empty)".
# The shared "firstmate" workspace is intentionally NEVER closed here.
fm_be_kill_window() {  # <handle>
  "$FM_HERDR_BIN" pane close "$1" >/dev/null
}

# fm_be_composer_state <handle> -> empty|pending|unknown   (best-effort).
# Optional for herdr and largely mooted by agent_status (report §3 risk 4); kept as
# a working ghost-text-aware fallback so callers (the away-mode daemon's injection
# gate) keep functioning under the herdr backend.
fm_be_composer_state() {  # <handle>
  fm_tmux_composer_state "$1"
}
