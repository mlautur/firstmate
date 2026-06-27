#!/usr/bin/env bash
# fm-backend-lib.sh — crew terminal-backend dispatcher for firstmate.
#
# Mirrors the config/crew-harness pattern (see bin/fm-harness.sh): one local,
# gitignored file, config/crew-backend, selects which terminal-multiplexer
# backend firstmate drives crewmate panes through. Resolution order:
#   1. FM_CREW_BACKEND (env override; parity with the harness override, handy
#      for tests),
#   2. config/crew-backend (whitespace-trimmed),
#   3. default.
# Absent / "default" / "tmux" => the tmux backend (bin/fm-tmux-lib.sh);
# "herdr" => the herdr backend (bin/fm-herdr-lib.sh).
#
# Sourcing this file loads exactly ONE backend lib, which defines the stable
# fm_be_* seam. The tmux backend additionally keeps the historical
# fm_tmux_*/fm_pane_* names that current call sites still call directly, so with
# the default (tmux) backend this dispatcher changes no behavior — it is a
# drop-in for a direct `. fm-tmux-lib.sh`.
#
# Safe to source into `set -eu` contexts (fm-send.sh, fm-crew-state.sh, the
# away-mode daemon): every step is guarded. An unknown backend name fails loudly
# (the source returns non-zero); the herdr stub loads cleanly and fails loudly
# only when a primitive is actually called.

# Resolve this lib's own bin/ dir so the backend impls load relative to the
# scripts, never relative to FM_HOME or the caller's cwd.
FM_BACKEND_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# fm_backend_name: echo the selected backend name. FM_CREW_BACKEND wins; else
# config/crew-backend; else empty. "default"/"tmux"/absent normalize to "tmux";
# any other value (including "herdr") is echoed verbatim so the dispatcher can
# either load it or reject it loudly.
fm_backend_name() {
  local name="${FM_CREW_BACKEND:-}" home cfg
  if [ -z "$name" ]; then
    home="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$FM_BACKEND_LIB_DIR/.." && pwd)}}"
    cfg="${FM_CONFIG_OVERRIDE:-$home/config}/crew-backend"
    [ -f "$cfg" ] && name="$(tr -d '[:space:]' < "$cfg" 2>/dev/null || true)"
  fi
  case "$name" in
    ''|default|tmux) printf 'tmux' ;;
    *) printf '%s' "$name" ;;
  esac
}

# Load the selected backend implementation now.
case "$(fm_backend_name)" in
  tmux)
    # shellcheck source=bin/fm-tmux-lib.sh
    . "$FM_BACKEND_LIB_DIR/fm-tmux-lib.sh"
    ;;
  herdr)
    # shellcheck source=bin/fm-herdr-lib.sh
    . "$FM_BACKEND_LIB_DIR/fm-herdr-lib.sh"
    ;;
  *)
    printf 'fm-backend-lib: unknown crew backend %s (expected tmux|herdr)\n' \
      "$(fm_backend_name)" >&2
    # This file is always sourced, so `return` propagates the failure to the
    # caller; `exit` is an unreachable-in-practice fallback for direct execution.
    # shellcheck disable=SC2317
    return 1 2>/dev/null || exit 1
    ;;
esac
