#!/usr/bin/env bash
# tests/fm-brief.test.sh - fm-brief.sh scaffolding guards.
#
# The headline guard is a `bash -n` parse check: the per-mode Definition-of-done
# bodies are captured with `read -r -d ''` heredocs, and a regression once wrapped
# them in `$(cat <<EOF ...)` command substitution, where bash's parser treats a
# lone apostrophe in the heredoc body (e.g. "no-mistakes' own guidance") as an
# unterminated quote and the whole script fails to parse. shellcheck does NOT
# catch that quirk, so this explicit parse check is the real safety net. The rest
# scaffolds every mode end-to-end and asserts the rendered briefs carry their
# expected, apostrophe-bearing contract text.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-brief)

# A throwaway home with the three delivery modes registered so fm-project-mode.sh
# resolves each project's mode. Echoes the home path.
make_home() {
  local home=$1
  mkdir -p "$home/data" "$home/state" "$home/projects/nm" "$home/projects/dp" "$home/projects/lo"
  cat > "$home/data/projects.md" <<MD
- nm [no-mistakes] - test (added 2026-06-27)
- dp [direct-PR] - test (added 2026-06-27)
- lo [local-only] - test (added 2026-06-27)
MD
}

test_fm_brief_parses() {
  bash -n "$ROOT/bin/fm-brief.sh" || fail "fm-brief.sh failed bash -n (syntax error)"
  pass "fm-brief.sh parses cleanly"
}

test_no_mistakes_brief_renders_slim_contract() {
  local home=$TMP_ROOT/nm-home brief
  make_home "$home"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" nm-task nm >/dev/null || fail "no-mistakes brief scaffold failed"
  brief="$home/data/nm-task/brief.md"
  [ -f "$brief" ] || fail "no-mistakes brief not written"
  # The apostrophe-bearing line is exactly what the command-substitution bug broke.
  grep -qF "no-mistakes' own guidance" "$brief" || fail "no-mistakes brief missing apostrophe contract line"
  grep -qF 'no-mistakes axi run --help' "$brief" || fail "no-mistakes brief missing version-matched guidance pointer"
  grep -qF 'ask-user findings are not yours to answer' "$brief" || fail "no-mistakes brief missing ask-user escalation rule"
  grep -qF 'the captain, not you, owns the ask-user decisions' "$brief" || fail "no-mistakes brief missing --yes avoidance rule"
  grep -qF 'After /no-mistakes reports CI green, append' "$brief" || fail "no-mistakes brief missing CI-green done line"
  pass "no-mistakes brief renders the slimmed contract"
}

test_direct_pr_and_local_only_briefs_render() {
  local home=$TMP_ROOT/ship-home brief
  make_home "$home"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" dp-task dp >/dev/null || fail "direct-PR brief scaffold failed"
  brief="$home/data/dp-task/brief.md"
  grep -qF 'ships **direct-PR**' "$brief" || fail "direct-PR brief missing mode line"
  grep -qF 'push your branch and open a PR' "$brief" || fail "direct-PR brief missing PR instruction"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" lo-task lo >/dev/null || fail "local-only brief scaffold failed"
  brief="$home/data/lo-task/brief.md"
  grep -qF 'ships **local-only**' "$brief" || fail "local-only brief missing mode line"
  # $ID must expand inside the captured heredoc.
  grep -qF 'ready in branch fm/lo-task' "$brief" || fail "local-only brief did not expand \$ID"
  pass "direct-PR and local-only briefs render with expansion"
}

test_scout_and_secondmate_briefs_render() {
  local home=$TMP_ROOT/other-home brief
  make_home "$home"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" sc-task nm --scout >/dev/null || fail "scout brief scaffold failed"
  brief="$home/data/sc-task/brief.md"
  grep -qF 'This is a SCOUT task' "$brief" || fail "scout brief missing scout contract"

  FM_HOME="$home" FM_SECONDMATE_CHARTER='Test charter.' "$ROOT/bin/fm-brief.sh" sm-task --secondmate nm dp >/dev/null \
    || fail "secondmate brief scaffold failed"
  brief="$home/data/sm-task/brief.md"
  grep -qF 'You are a secondmate' "$brief" || fail "secondmate brief missing charter header"
  pass "scout and secondmate briefs render"
}

test_fm_brief_parses
test_no_mistakes_brief_renders_slim_contract
test_direct_pr_and_local_only_briefs_render
test_scout_and_secondmate_briefs_render
