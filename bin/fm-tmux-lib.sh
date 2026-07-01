#!/usr/bin/env bash
# fm-tmux-lib.sh — the tmux backend behind firstmate's crew-pane seam.
#
# This is the tmux implementation of the backend interface dispatched by
# bin/fm-backend-lib.sh (config/crew-backend = absent/default/tmux). It defines
# the stable fm_be_* seam at the bottom of this file, plus the historical
# fm_tmux_*/fm_pane_* primitives current call sites still call directly. The
# herdr backend (bin/fm-herdr-lib.sh, filled in migration slice 3) implements the
# same fm_be_* interface; see data/herdr-migration-scout-h1/report.md §4.
#
# ONE source of truth for: busy detection, composer-empty (pending-input)
# detection, and a verify-and-retry-Enter submit. Sourced by both the away-mode
# daemon (bin/fm-supervise-daemon.sh) and bin/fm-send.sh (through the dispatcher)
# so the composer/submit logic cannot drift between the two.
#
# Why this exists (incident afk-invx-i5): the daemon's old composer check only
# recognized a BARE prompt glyph ("> ") as an empty composer. claude draws its
# input box with box-drawing borders ("│ > … │"), so every idle claude pane read
# as "pending input" and the away-mode daemon deferred 100% of escalations for
# 9.5 hours with no escape. The detector below strips the box borders before
# deciding, so a bordered-but-empty composer is correctly seen as empty. The same
# corrected detector backs the submit acknowledgement (a submit "landed" iff the
# composer is empty afterward), fixing the parallel false "Enter swallowed".
#
# Ghost text (incident composer-robust): claude renders a predicted-next-prompt
# "suggestion" as dim/faint text inside an otherwise-empty composer. A plain
# capture cannot tell it apart from text a human typed, so the old reader saw an
# idle pane as holding pending input and the daemon deferred injection / firstmate
# misjudged the pane. The composer reader now captures just the cursor line WITH
# ANSI styling (tmux capture-pane -e), drops dim/faint (SGR 2) runs, and decides on
# what is left, so ghost/placeholder text never counts as real input. The styled
# capture is consumed internally and parsed into a boolean here; it is NEVER
# surfaced (fm-peek and every human/LLM-facing path stay plain), and only the
# single composer row is captured, so no escape-laden pane bulk is produced. This
# is harness-generic: any harness that dims placeholder/ghost text benefits.
#
# Per-harness override: FM_COMPOSER_IDLE_RE matches an empty composer after
# dim-ghost and structural border stripping. FM_BUSY_REGEX overrides the busy
# footer set (mirrors fm-watch.sh / the daemon).
#
# All functions are `set -u` and `set -e` safe (guarded tmux calls, explicit
# returns) so they can be sourced into either context.

# Busy footers per harness (mirror fm-watch.sh). claude/codex: "esc to
# interrupt"; opencode: "esc interrupt"; pi: "Working..."; grok: "Ctrl+c:cancel"
# (grok's mid-turn cancel hint, shown iff a turn is running - verified grok 0.2.73).
FM_TMUX_BUSY_REGEX_DEFAULT='esc (to )?interrupt|Working\.\.\.|Ctrl\+c:cancel'

# fm_tmux_strip_ghost: remove dim/faint (ANSI SGR 2) styled runs from one captured
# composer line, then drop any remaining escape sequences, leaving only the plain,
# normal-intensity text, the text a human actually typed. Dim/faint runs are
# ghost/placeholder text (e.g. claude's predicted-next-prompt suggestion) that
# fills an otherwise-empty composer and must never read as pending input. Reads the
# styled line on stdin (from `tmux capture-pane -e`) and prints plain text on
# stdout. LC_ALL=C makes awk walk bytes, so multibyte glyphs (e.g. ❯) and dim runs
# alike pass through or drop intact without locale-dependent character classes.
# A reset (SGR 0) or normal-intensity (SGR 22) ends a dim run; codes are processed
# left to right within a sequence so "ESC[0;2m" (reset then dim) reads as dim.
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

# fm_tmux_composer_state: classify the cursor/composer line of <target> as
#   empty   - no pending input (blank, a bare prompt, a busy footer, or only dim
#             ghost/placeholder text). Safe to inject; also the positive
#             acknowledgement that a submit landed.
#   pending - real, unsubmitted text on the cursor line (a human mid-typing, or a
#             previous injection whose Enter was swallowed). Defer / retry.
#   unknown - the pane could not be read (tmux error). The caller decides.
#
# The cursor line is captured WITH ANSI styling (capture-pane -e) and bounded to
# the single composer row (-S/-E), then run through fm_tmux_strip_ghost so dim/faint
# ghost text drops out before classification. The styled capture is internal only,
# never surfaced. The detector then strips the harness's box-drawing composer
# borders ("│ … │", heavy "┃", or a plain ASCII "|") using literal-string
# substitution (bash 3.2 safe, locale-independent — no \u escapes, no multibyte
# character classes), and asks whether anything real is left.
fm_tmux_composer_state() {  # <target> -> empty|pending|unknown
  local target=$1 cy raw line stripped
  cy=$(tmux display-message -p -t "$target" '#{cursor_y}' 2>/dev/null) || { printf 'unknown'; return 0; }
  case "$cy" in ''|*[!0-9]*) printf 'unknown'; return 0 ;; esac
  raw=$(tmux capture-pane -e -p -t "$target" -S "$cy" -E "$cy" 2>/dev/null) || { printf 'unknown'; return 0; }
  line=$(printf '%s\n' "$raw" | fm_tmux_strip_ghost)
  # Strip the composer box borders (literal glyphs — no character classes).
  stripped=${line//│/}      # U+2502 light vertical (claude)
  stripped=${stripped//┃/}  # U+2503 heavy vertical
  stripped=${stripped//|/}  # ASCII pipe
  # Trim surrounding whitespace.
  stripped="${stripped#"${stripped%%[![:space:]]*}"}"
  stripped="${stripped%"${stripped##*[![:space:]]}"}"
  # Nothing left inside the box = empty composer.
  [ -n "$stripped" ] || { printf 'empty'; return 0; }
  if [ -n "${FM_COMPOSER_IDLE_RE:-}" ] \
     && printf '%s' "$stripped" | grep -qiE "$FM_COMPOSER_IDLE_RE"; then
    printf 'empty'; return 0
  fi
  # Just a bare prompt glyph = empty composer (idle).
  case "$stripped" in
    '>'|'❯'|'$'|'%'|'#') printf 'empty'; return 0 ;;
  esac
  # A busy footer landing on the cursor line is not pending input.
  if printf '%s' "$stripped" | grep -qiE "${FM_BUSY_REGEX:-$FM_TMUX_BUSY_REGEX_DEFAULT}"; then
    printf 'empty'; return 0
  fi
  printf 'pending'; return 0
}

# fm_pane_input_pending: 0 (pending) if the cursor line holds real unsubmitted
# text, 1 otherwise. An unreadable pane is treated as NOT pending (fail-safe:
# the same bias the old daemon used — an unknown pane defers nothing here).
fm_pane_input_pending() {  # <target>
  [ "$(fm_tmux_composer_state "$1")" = pending ]
}

# fm_pane_is_busy: 0 if the pane's last few non-blank lines show a busy footer
# (an agent mid-turn). Scans a 40-line tail like fm-watch.sh.
fm_pane_is_busy() {  # <target>
  local win=$1 tail40
  tail40=$(tmux capture-pane -p -t "$win" -S -40 2>/dev/null) || return 1
  printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -6 \
    | grep -qiE "${FM_BUSY_REGEX:-$FM_TMUX_BUSY_REGEX_DEFAULT}"
}

# fm_tmux_submit_core: type <text> into <target> ONCE, then submit with Enter,
# verifying the composer cleared. Retries Enter ONLY — never retypes, because a
# swallowed Enter leaves our text in the composer and retyping would duplicate
# it. Echoes the final verdict on stdout (empty|pending|unknown|send-failed) so callers can
# pick their own success policy:
#   - the daemon clears its buffer only on "empty" (strict: an unknown pane must
#     not be mistaken for a delivered escalation).
#   - fm-send fails only on "pending" (lenient: a positively-confirmed swallow),
#     so an unreadable pane never turns a normal steer into a false error.
fm_tmux_submit_enter_core() {  # <target> <retries> <enter-sleep>
  local target=$1 retries=$2 sleep_s=$3 i=0 state
  while :; do
    tmux send-keys -t "$target" Enter 2>/dev/null || true
    sleep "$sleep_s"
    state=$(fm_tmux_composer_state "$target")
    [ "$state" = pending ] || { printf '%s' "$state"; return 0; }
    i=$((i + 1))
    [ "$i" -lt "$retries" ] || { printf 'pending'; return 0; }
  done
}

fm_tmux_submit_core() {  # <target> <text> <retries> <enter-sleep> <settle>
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5
  tmux send-keys -t "$target" -l "$text" 2>/dev/null || { printf 'send-failed'; return 0; }
  sleep "$settle"
  fm_tmux_submit_enter_core "$target" "$retries" "$sleep_s"
}

# ============================================================================
# Backend seam (fm_be_*) — tmux implementation.
#
# The stable interface every backend provides (dispatched by bin/fm-backend-lib.sh;
# the herdr stub mirrors these signatures in bin/fm-herdr-lib.sh). The tmux
# backend implements it by reusing the primitives above plus the inline tmux calls
# that today live in fm-spawn.sh, fm-peek.sh, fm-send.sh and fm-teardown.sh. Slice
# 1 only DEFINES this seam (and keeps every historical name above working); moving
# those call sites onto fm_be_* is later slices, so each function below is a
# behavior-preserving equivalent of today's inline tmux usage.
#
# Handle model (tmux): a window is addressed as "session:window" (e.g.
# "firstmate:fm-foo"); that string is the opaque handle stored in
# state/<id>.meta window= and is what every fm_be_* below accepts.
# ============================================================================

# fm_be_create_window <id> <cwd> <label> -> echoes handle (session:window).
# Mirror fm-spawn.sh's session/window creation: reuse firstmate's current tmux
# session when inside tmux, else a dedicated detached "firstmate" session; create
# a detached window named <label> at <cwd>; refuse a duplicate window name. <id>
# is accepted for interface parity (the herdr backend names by agent id); the
# tmux backend addresses by <label>.
fm_be_create_window() {  # <id> <cwd> <label>
  local cwd=$2 label=$3 ses
  if [ -n "${TMUX:-}" ]; then
    ses=$(tmux display-message -p '#S') || return 1
  else
    tmux has-session -t firstmate 2>/dev/null || tmux new-session -d -s firstmate || return 1
    ses=firstmate
  fi
  if tmux list-windows -t "$ses" -F '#{window_name}' 2>/dev/null | grep -qx "$label"; then
    printf 'fm_be_create_window: window %s:%s already exists\n' "$ses" "$label" >&2
    return 1
  fi
  tmux new-window -d -t "$ses" -n "$label" -c "$cwd" || return 1
  printf '%s:%s' "$ses" "$label"
}

# fm_be_window_exists <handle|label> -> 0 if a matching window exists, else 1.
fm_be_window_exists() {  # <handle|label>
  case "$1" in
    *:*) tmux list-windows -a -F '#{session_name}:#{window_name}' 2>/dev/null \
           | grep -qx "$1" ;;
    *)   tmux list-windows -a -F '#{window_name}' 2>/dev/null | grep -qx "$1" ;;
  esac
}

# fm_be_resolve <name|handle> -> echoes a session:window handle, or fails.
# A bare window name resolves via `tmux list-windows -a` (matches fm-peek/fm-send);
# an already-qualified session:window passes through unchanged.
fm_be_resolve() {  # <name|handle>
  case "$1" in
    *:*) printf '%s' "$1" ;;
    *)   tmux list-windows -a -F '#{session_name}:#{window_name}' 2>/dev/null \
           | grep -m1 ":$1\$" || return 1 ;;
  esac
}

# fm_be_run_cmd <handle> <cmd>: type a shell command and submit it (command + Enter).
fm_be_run_cmd() {  # <handle> <cmd>
  tmux send-keys -t "$1" "$2" Enter
}

# fm_be_send_text <handle> <text>: type literal text, no Enter.
fm_be_send_text() {  # <handle> <text>
  tmux send-keys -t "$1" -l "$2"
}

# fm_be_send_key <handle> <key...>: send one or more named keys (Enter/Escape/C-c).
fm_be_send_key() {  # <handle> <key...>
  local handle=$1
  shift
  tmux send-keys -t "$handle" "$@"
}

# fm_be_submit_verify <handle> <text> <retries> <enter-sleep> <settle>
#   -> empty|pending|unknown|send-failed   (the verify-and-retry submit contract).
fm_be_submit_verify() {  # <handle> <text> <retries> <enter-sleep> <settle>
  fm_tmux_submit_core "$@"
}

# fm_be_capture <handle> <lines> [ansi]: echo the last <lines> rows of the pane.
# With a non-empty third arg, preserve ANSI styling (tmux -e, for the ghost-text
# path); otherwise a plain capture (the peek/busy analog).
fm_be_capture() {  # <handle> <lines> [ansi]
  if [ -n "${3:-}" ]; then
    tmux capture-pane -e -p -t "$1" -S -"$2"
  else
    tmux capture-pane -p -t "$1" -S -"$2"
  fi
}

# fm_be_pane_alive <handle> -> 0 if the handle resolves to a live pane, else 1.
fm_be_pane_alive() {  # <handle>
  tmux display-message -p -t "$1" '#{pane_id}' >/dev/null 2>&1
}

# fm_be_pane_cwd <handle> -> echo the pane's current working directory.
fm_be_pane_cwd() {  # <handle>
  tmux display-message -p -t "$1" '#{pane_current_path}' 2>/dev/null
}

# fm_be_agent_status <handle> -> idle|working|none   (tmux best-effort).
# Derive a unified agent state from the tmux-native signals firstmate already
# uses, so later slices can read ONE function regardless of backend:
#   working - the busy signature is present in the pane footer (agent mid-turn).
#   idle    - the pane is readable and NOT busy.
#   none    - the handle does not resolve to a live pane.
# tmux has NO native source for "done" or "blocked" — those come from the
# crewmate status file and per-harness turn-end hooks, not the pane — so the tmux
# backend never returns them. The herdr backend, reading herdr's native per-pane
# agent_status, supplies done/blocked/unknown directly. This is the unifying read
# that replaces inline busy-regex + pane-hash checks in later slices.
fm_be_agent_status() {  # <handle>
  fm_be_pane_alive "$1" || { printf 'none'; return 0; }
  if fm_pane_is_busy "$1"; then
    printf 'working'; return 0
  fi
  printf 'idle'; return 0
}

# fm_be_kill_window <handle>: tear down the window/pane (teardown path).
fm_be_kill_window() {  # <handle>
  tmux kill-window -t "$1"
}

# fm_be_composer_state <handle> -> empty|pending|unknown   (ghost-text aware).
fm_be_composer_state() {  # <handle>
  fm_tmux_composer_state "$1"
}
