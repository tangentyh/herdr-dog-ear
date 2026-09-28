#!/usr/bin/env bash
# Test suite for open-in-editor.sh.
#
# Dependency-light: bash + POSIX tools only (no bats, no python3). Run with:
#
#   bash tests/run.sh
#
# Every `herdr` call is intercepted by the stub in tests/stub/, so nothing
# touches the live session. The suite is hermetic: all fixtures and logs live
# in a mktemp dir removed on exit.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
PLUGIN="$REPO/open-in-editor.sh"
STUB_DIR="$HERE/stub"
BASH_BIN=$(command -v bash)

# The stub must intercept every herdr call for the whole suite, so even a
# stray/misbehaving probe cannot reach the live session.
export PATH="$STUB_DIR:$PATH"

# Never let the developer's live herdr session (or its editor/clipboard config)
# leak in. The stub must intercept every herdr call.
unset HERDR_BIN_PATH HERDR_PANE_ID HERDR_PLUGIN_CLICKED_URL HERDR_PLUGIN_CONTEXT_JSON \
      HERDR_ACTIVE_PANE_CWD HERDR_PLUGIN_LINK_HANDLER_ID HERDR_ENV HERDR_SOCKET_PATH \
      HERDR_TAB_ID HERDR_WORKSPACE_ID EDITOR OPEN_IN_EDITOR_DRY OPEN_IN_EDITOR_CLIP

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/open-in-editor-tests.XXXXXX") || {
  printf 'could not create a temp dir\n' >&2
  exit 2
}
# Resolve symlinks in the temp root once (macOS: /var -> /private/var) so the
# absolute paths the plugin canonicalizes match the paths asserted below.
TMPROOT=$(cd "$TMPROOT" && pwd -P)
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

# --- fixtures ---------------------------------------------------------------
FIX="$TMPROOT/fixtures"
mkdir -p "$FIX/sub" "$FIX/home"
printf 'plain\n'  > "$FIX/plain.txt"
printf 'spaces\n' > "$FIX/with space.txt"
printf 'nested\n' > "$FIX/sub/nested.txt"
printf 'home\n'   > "$FIX/home/homed.txt"

STUB_LOG="$TMPROOT/stub.log"
export STUB_LOG

# The plugin's function definitions only (everything before its top-level
# route logic). Written to a real file once: sourcing a process substitution
# does not define functions under bash 3.2, which macOS still ships as /bin/bash.
PLUGIN_FUNCS="$TMPROOT/plugin-functions.sh"
sed '/^cands=/,$d' "$PLUGIN" > "$PLUGIN_FUNCS"
export PLUGIN_FUNCS

# A PATH with jq (so the dependency check passes) but no clipboard tool, so
# read_clipboard() reliably returns an empty string without reading the real
# clipboard. NOJQ_DIR is intentionally empty to test the missing-jq guard.
MINJQ_DIR="$TMPROOT/minjq"; mkdir -p "$MINJQ_DIR"
NOJQ_DIR="$TMPROOT/nojq";  mkdir -p "$NOJQ_DIR"
if command -v jq >/dev/null 2>&1; then
  HAVE_JQ=1
  ln -s "$(command -v jq)" "$MINJQ_DIR/jq"
else
  HAVE_JQ=0
fi
# MINJQ_DIR has jq + the stub + bash but no clipboard tool, so the empty
# clipboard case proves read_clipboard() returns nothing AND that no herdr call
# is attempted through the stub.
ln -s "$STUB_DIR/herdr" "$MINJQ_DIR/herdr"
ln -s "$BASH_BIN" "$MINJQ_DIR/bash"

# --- tiny test harness ------------------------------------------------------
PASS=0
FAIL=0
SKIP=0
FAILED_CASES=()

run_case() {
  local name=$1; shift
  local output rc
  output=$("$@" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then
    printf 'PASS  %s\n' "$name"; PASS=$((PASS + 1))
  elif [ "$rc" -eq 77 ]; then
    printf 'SKIP  %s\n' "$name"; SKIP=$((SKIP + 1))
    [ -n "$output" ] && printf '%s\n' "$output" | sed 's/^/      /'
  else
    printf 'FAIL  %s\n' "$name"; FAIL=$((FAIL + 1)); FAILED_CASES+=("$name")
    printf '%s\n' "$output" | sed 's/^/      /'
  fi
}

assert_eq() { # label expected actual
  if [ "$2" != "$3" ]; then
    printf '  assert_eq [%s]\n    expected: [%s]\n    actual:   [%s]\n' "$1" "$2" "$3"
    return 1
  fi
}

assert_contains() { # label haystack needle
  case "$2" in
    *"$3"*) return 0 ;;
  esac
  printf '  assert_contains [%s] needle not found: [%s]\n    haystack:\n%s\n' "$1" "$3" "$2"
  return 1
}

assert_not_contains() { # label haystack needle
  case "$2" in
    *"$3"*)
      printf '  assert_not_contains [%s] unexpected: [%s]\n    haystack:\n%s\n' "$1" "$3" "$2"
      return 1 ;;
  esac
  return 0
}

assert_status() { # label expected actual
  if [ "$2" != "$3" ]; then
    printf '  assert_status [%s]: expected exit %s, got %s\n' "$1" "$2" "$3"
    return 1
  fi
}

skip() { printf '  skip: %s\n' "$*"; return 77; }

# --- plugin drivers ---------------------------------------------------------
# Source only the plugin's function definitions ($PLUGIN_FUNCS). `exit` is
# overridden and `herdr` is a no-op as defence in depth in case the function
# cut marker ever drifts and the main body ends up in the file.
plugin_call() {
  "$BASH_BIN" -c '
    exit() { return 0; }
    herdr() { return 0; }
    __pi_args=("$@")
    set --
    unset HERDR_BIN_PATH
    . "$PLUGIN_FUNCS" >/dev/null 2>&1
    unset -f exit
    "${__pi_args[@]}"
  ' _ "$@"
}

# Prints "status|path|line|col" for normalize() of the candidate in $1.
normalize_probe() {
  "$BASH_BIN" -c '
    exit() { return 0; }
    herdr() { return 0; }
    __pi_cand=$1
    set --
    unset HERDR_BIN_PATH
    . "$PLUGIN_FUNCS" >/dev/null 2>&1
    unset -f exit
    normalize "$__pi_cand" >/dev/null 2>&1
    printf "%s|%s|%s|%s\n" "$?" "$norm_path" "$norm_line" "$norm_col"
  ' _ "$1"
}

# Run the plugin as a subprocess (the stub is already first on PATH).
run_plugin() {
  "$BASH_BIN" "$PLUGIN" "$@"
}

reset_stub() { : > "$STUB_LOG"; }
stub_log() { cat "$STUB_LOG"; }
run_inv() { sed -n '/^INV <pane> <run>/p' "$STUB_LOG" | tail -n 1; }

require_jq() { [ "$HAVE_JQ" = 1 ] || skip "jq not installed on this host"; }

# --- cases ------------------------------------------------------------------

case_candidates_from() {
  local got exp

  # Path with spaces: whole first line survives, tokens split on space.
  got=$(plugin_call candidates_from 'src/my file.rs')
  exp=$'src/my file.rs\nsrc/my\nfile.rs'
  assert_eq "spaces" "$exp" "$got" || return 1

  # Quoted path: wrapping quotes are stripped from the token.
  got=$(plugin_call candidates_from '"src/main.rs"')
  exp=$'"src/main.rs"\nsrc/main.rs'
  assert_eq "quotes" "$exp" "$got" || return 1

  # Trailing punctuation is stripped from the token but kept on the whole line.
  got=$(plugin_call candidates_from 'see src/main.rs:42,')
  exp=$'see src/main.rs:42,\nsee\nsrc/main.rs:42'
  assert_eq "trailing punctuation" "$exp" "$got" || return 1

  # Multiple whitespace-delimited tokens (space and tab).
  got=$(plugin_call candidates_from $'a.txt b.txt\tc.txt')
  exp=$'a.txt b.txt\tc.txt\na.txt\nb.txt\nc.txt'
  assert_eq "multiple whitespace tokens" "$exp" "$got" || return 1
}

case_urldecode() {
  local got hex

  got=$(plugin_call urldecode '%C3%A9')
  hex=$(printf '%s' "$got" | od -An -tx1 | tr -d ' \n')
  assert_eq "percent-encoded UTF-8 yields raw bytes" 'c3a9' "$hex" || return 1

  got=$(plugin_call urldecode '%20')
  assert_eq "%20 is a space" ' ' "$got" || return 1

  got=$(plugin_call urldecode '100% done.txt')
  assert_eq "literal % left alone" '100% done.txt' "$got" || return 1

  got=$(plugin_call urldecode 'a%zz%')
  assert_eq "incomplete escapes left alone" 'a%zz%' "$got" || return 1
}

case_normalize() {
  local r

  export HERDR_ACTIVE_PANE_CWD="$FIX"
  export HOME="$FIX/home"

  r=$(normalize_probe "file://$FIX/with%20space.txt")
  assert_eq "file:///abs + urldecode" "0|$FIX/with space.txt||" "$r" || return 1

  r=$(normalize_probe "file://example.invalid$FIX/plain.txt")
  assert_eq "file://host/abs" "0|$FIX/plain.txt||" "$r" || return 1

  r=$(normalize_probe "$FIX/plain.txt")
  assert_eq "absolute path" "0|$FIX/plain.txt||" "$r" || return 1

  r=$(normalize_probe 'sub/nested.txt')
  assert_eq "relative-to-pane-cwd" "0|$FIX/sub/nested.txt||" "$r" || return 1

  r=$(normalize_probe '~/homed.txt')
  assert_eq "~/ expansion" "0|$FIX/home/homed.txt||" "$r" || return 1

  r=$(normalize_probe "$FIX/plain.txt:42")
  assert_eq ":line suffix" "0|$FIX/plain.txt|42|" "$r" || return 1

  r=$(normalize_probe "$FIX/plain.txt:7:3")
  assert_eq ":line:col suffix" "0|$FIX/plain.txt|7|3" "$r" || return 1

  r=$(normalize_probe "$FIX/missing.txt")
  assert_eq "nonexistent -> no match" '1|||' "$r" || return 1

  r=$(normalize_probe 'https://example.com/a.rs')
  assert_eq "https rejected" '1|||' "$r" || return 1

  r=$(normalize_probe 'http://example.com/a.rs')
  assert_eq "http rejected" '1|||' "$r" || return 1
}

case_editor_vi_col() { # vi-family with a column -> +call cursor(l,c)
  require_jq || return 77
  reset_stub
  export EDITOR=vi OPEN_IN_EDITOR_CLIP="$FIX/plain.txt:7:3"
  local rc; run_plugin --clipboard >/dev/null 2>&1; rc=$?
  assert_status "exit" 0 "$rc" || return 1
  assert_eq "vi +call cursor" \
    'INV <pane> <run> <wK:p999> < exec vi +call\ cursor\(7\,3\) -- '"$FIX/plain.txt>" \
    "$(run_inv)" || return 1
}

case_editor_vim_line() { # vi-family with only a line -> +line
  require_jq || return 77
  reset_stub
  export EDITOR=vim OPEN_IN_EDITOR_CLIP="$FIX/plain.txt:42"
  local rc; run_plugin --clipboard >/dev/null 2>&1; rc=$?
  assert_status "exit" 0 "$rc" || return 1
  assert_eq "vim +line" \
    'INV <pane> <run> <wK:p999> < exec vim +42 -- '"$FIX/plain.txt>" \
    "$(run_inv)" || return 1
}

case_editor_code() { # VS Code -> -g file:line:col
  require_jq || return 77
  reset_stub
  export EDITOR=code OPEN_IN_EDITOR_CLIP="$FIX/plain.txt:7:3"
  local rc; run_plugin --clipboard >/dev/null 2>&1; rc=$?
  assert_status "exit" 0 "$rc" || return 1
  assert_eq "code -g" \
    'INV <pane> <run> <wK:p999> < exec code -g '"$FIX/plain.txt"':7:3>' \
    "$(run_inv)" || return 1
}

case_editor_zed_hx_subl() { # zed/hx/subl -> file:line:col
  require_jq || return 77
  local editor rc
  for editor in zed hx subl; do
    reset_stub
    export EDITOR="$editor" OPEN_IN_EDITOR_CLIP="$FIX/plain.txt:7:3"
    run_plugin --clipboard >/dev/null 2>&1; rc=$?
    assert_status "$editor exit" 0 "$rc" || return 1
    assert_eq "$editor file:line:col" \
      "INV <pane> <run> <wK:p999> < exec $editor -- $FIX/plain.txt:7:3>" \
      "$(run_inv)" || return 1
  done
}

case_editor_nano() { # nano -> +line,col
  require_jq || return 77
  reset_stub
  export EDITOR=nano OPEN_IN_EDITOR_CLIP="$FIX/plain.txt:7:3"
  local rc; run_plugin --clipboard >/dev/null 2>&1; rc=$?
  assert_status "exit" 0 "$rc" || return 1
  assert_eq "nano +line,col" \
    'INV <pane> <run> <wK:p999> < exec nano +7\,3 -- '"$FIX/plain.txt>" \
    "$(run_inv)" || return 1
}

case_editor_emacs() { # emacs -> +line:col
  require_jq || return 77
  reset_stub
  export EDITOR=emacs OPEN_IN_EDITOR_CLIP="$FIX/plain.txt:7:3"
  local rc; run_plugin --clipboard >/dev/null 2>&1; rc=$?
  assert_status "exit" 0 "$rc" || return 1
  assert_eq "emacs +line:col" \
    "INV <pane> <run> <wK:p999> < exec emacs +7:3 $FIX/plain.txt>" \
    "$(run_inv)" || return 1
}

case_route_selection() { # selection via HERDR_PLUGIN_CONTEXT_JSON
  require_jq || return 77
  reset_stub
  export EDITOR=vim
  export HERDR_PLUGIN_CONTEXT_JSON="{\"selected_text\":\"$FIX/plain.txt:42\",\"focused_pane_cwd\":\"$FIX\"}"
  local out rc
  out=$(run_plugin 2>&1); rc=$?
  assert_status "exit" 0 "$rc" || return 1
  assert_contains "open logged" "$out" "open: $FIX/plain.txt line 42" || return 1
  assert_eq "selection argv" \
    'INV <pane> <run> <wK:p999> < exec vim +42 -- '"$FIX/plain.txt>" \
    "$(run_inv)" || return 1
}

case_route_clicked_url() { # clicked OSC-8 URL via HERDR_PLUGIN_CLICKED_URL
  require_jq || return 77
  reset_stub
  export EDITOR=vim
  export HERDR_PLUGIN_CLICKED_URL="file://$FIX/plain.txt:42"
  local out rc
  out=$(run_plugin 2>&1); rc=$?
  assert_status "exit" 0 "$rc" || return 1
  assert_contains "file url matched" "$out" "open: $FIX/plain.txt line 42" || return 1
  assert_eq "clicked argv" \
    'INV <pane> <run> <wK:p999> < exec vim +42 -- '"$FIX/plain.txt>" \
    "$(run_inv)" || return 1
}

case_route_clipboard() { # --clipboard + OPEN_IN_EDITOR_CLIP override
  require_jq || return 77
  reset_stub
  export EDITOR=vim
  export OPEN_IN_EDITOR_CLIP="$FIX/plain.txt:42"
  local out rc
  out=$(run_plugin --clipboard 2>&1); rc=$?
  assert_status "exit" 0 "$rc" || return 1
  assert_contains "clipboard logged" "$out" "clipboard: $FIX/plain.txt:42" || return 1
  assert_eq "clipboard argv" \
    'INV <pane> <run> <wK:p999> < exec vim +42 -- '"$FIX/plain.txt>" \
    "$(run_inv)" || return 1
}

case_route_empty_clipboard() { # no clipboard tool -> skip, exit 0, no herdr call
  reset_stub
  unset OPEN_IN_EDITOR_CLIP HERDR_PLUGIN_CLICKED_URL HERDR_PLUGIN_CONTEXT_JSON
  local out rc
  out=$(PATH="$MINJQ_DIR" "$BASH_BIN" "$PLUGIN" --clipboard 2>&1); rc=$?
  assert_status "empty clipboard exits 0" 0 "$rc" || return 1
  assert_contains "skip message" "$out" 'skip: clipboard empty' || return 1
  assert_eq "no herdr calls" '' "$(stub_log)" || return 1
}

case_guard_missing_jq() { # selection route without jq on PATH
  export HERDR_PLUGIN_CONTEXT_JSON='{"selected_text":"/etc/hosts"}'
  local out rc
  out=$(PATH="$NOJQ_DIR" "$BASH_BIN" "$PLUGIN" 2>&1); rc=$?
  assert_status "nonzero exit" 1 "$rc" || return 1
  assert_contains "jq error" "$out" 'jq not found on PATH' || return 1
  assert_contains "install hint" "$out" 'install: brew install jq' || return 1
}

case_non_dry_split_and_run() {
  require_jq || return 77
  reset_stub
  export EDITOR=vim OPEN_IN_EDITOR_CLIP="$FIX/plain.txt:42"
  local out rc
  out=$(run_plugin --clipboard 2>&1); rc=$?
  assert_status "exit" 0 "$rc" || return 1
  assert_contains "split argv" "$(stub_log)" \
    "<pane> <split> <--current> <--direction> <right> <--cwd> <$FIX>" || return 1
  # The pane run argument must keep its leading space (history suppression).
  assert_contains "run argv + leading space" "$(stub_log)" \
    '<pane> <run> <wK:p999> < exec vim +42 -- '"$FIX/plain.txt>" || return 1
  assert_contains "opened log" "$out" 'opened in pane wK:p999' || return 1
}

case_split_direction() { # #5: OPEN_IN_EDITOR_SPLIT_DIRECTION drives pane split
  require_jq || return 77
  local out rc

  reset_stub
  export EDITOR=vim OPEN_IN_EDITOR_CLIP="$FIX/plain.txt"
  export OPEN_IN_EDITOR_SPLIT_DIRECTION=down
  run_plugin --clipboard >/dev/null 2>&1; rc=$?
  assert_status "down exit" 0 "$rc" || return 1
  assert_contains "down argv" "$(stub_log)" \
    "<pane> <split> <--current> <--direction> <down> <--cwd> <$FIX>" || return 1

  reset_stub
  export OPEN_IN_EDITOR_SPLIT_DIRECTION=sideways
  out=$(run_plugin --clipboard 2>&1); rc=$?
  assert_status "invalid exit" 0 "$rc" || return 1
  assert_contains "invalid warns" "$out" \
    "invalid OPEN_IN_EDITOR_SPLIT_DIRECTION='sideways'" || return 1
  assert_contains "invalid falls back to right" "$(stub_log)" \
    "<pane> <split> <--current> <--direction> <right> <--cwd> <$FIX>" || return 1

  unset OPEN_IN_EDITOR_SPLIT_DIRECTION
}

case_path_outside_cwd() { # #5: ../ candidate outside the pane cwd canonicalizes
  require_jq || return 77
  local sibling="$TMPROOT/sibling" out rc
  mkdir -p "$sibling"
  printf 'outside\n' > "$sibling/outside.txt"
  reset_stub
  export EDITOR=vim HERDR_ACTIVE_PANE_CWD="$FIX" OPEN_IN_EDITOR_CLIP='../sibling/outside.txt'
  out=$(run_plugin --clipboard 2>&1); rc=$?
  assert_status "exit" 0 "$rc" || return 1
  assert_contains "canonical open log" "$out" "open: $sibling/outside.txt" || return 1
  assert_contains "cwd is the sibling dir" "$(stub_log)" "<--cwd> <$sibling>" || return 1
}

case_reuse_vi_pane() { # #4: a vi-family pane in the current tab is reused
  require_jq || return 77
  reset_stub
  export EDITOR=vim OPEN_IN_EDITOR_CLIP="$FIX/plain.txt:42"
  export HERDR_WORKSPACE_ID=wTest HERDR_TAB_ID=wTest:t1
  export STUB_PANE_LIST='{"result":{"panes":[{"pane_id":"wTest:p7","tab_id":"wTest:t1"}]}}'
  export STUB_PROCESS_INFO='{"result":{"process_info":{"foreground_processes":[{"argv0":"vim","name":"vim"}]}}}'
  local out rc
  out=$(run_plugin --clipboard 2>&1); rc=$?
  assert_status "exit" 0 "$rc" || return 1
  assert_contains "reuse logged" "$out" "reused pane wTest:p7" || return 1
  assert_contains "tab drop sent to reused pane" "$(stub_log)" \
    "<pane> <send-text> <wTest:p7> <:tab drop $FIX/plain.txt | call cursor(42)>" || return 1
  assert_not_contains "no split when reused" "$(stub_log)" '<split>' || return 1
  unset HERDR_WORKSPACE_ID HERDR_TAB_ID STUB_PANE_LIST STUB_PROCESS_INFO
}

case_reuse_vi_tabless() { # #4: tabless vi falls back to :edit in the reused pane
  require_jq || return 77
  reset_stub
  export EDITOR=vi OPEN_IN_EDITOR_CLIP="$FIX/plain.txt"
  export HERDR_WORKSPACE_ID=wTest HERDR_TAB_ID=wTest:t1
  export STUB_PANE_LIST='{"result":{"panes":[{"pane_id":"wTest:p7","tab_id":"wTest:t1"}]}}'
  export STUB_PROCESS_INFO='{"result":{"process_info":{"foreground_processes":[{"argv0":"vi","name":"vi"}]}}}'
  local rc
  run_plugin --clipboard >/dev/null 2>&1; rc=$?
  assert_status "exit" 0 "$rc" || return 1
  assert_contains "edit fallback sent" "$(stub_log)" \
    "<pane> <send-text> <wTest:p7> <:edit $FIX/plain.txt>" || return 1
  assert_not_contains "no split when reused" "$(stub_log)" '<split>' || return 1
  unset HERDR_WORKSPACE_ID HERDR_TAB_ID STUB_PANE_LIST STUB_PROCESS_INFO
}

case_reuse_disabled() { # #4: OPEN_IN_EDITOR_REUSE=0 restores split-always
  require_jq || return 77
  reset_stub
  export EDITOR=vim OPEN_IN_EDITOR_CLIP="$FIX/plain.txt"
  export HERDR_WORKSPACE_ID=wTest HERDR_TAB_ID=wTest:t1 OPEN_IN_EDITOR_REUSE=0
  export STUB_PANE_LIST='{"result":{"panes":[{"pane_id":"wTest:p7","tab_id":"wTest:t1"}]}}'
  export STUB_PROCESS_INFO='{"result":{"process_info":{"foreground_processes":[{"argv0":"vim","name":"vim"}]}}}'
  local rc
  run_plugin --clipboard >/dev/null 2>&1; rc=$?
  assert_status "exit" 0 "$rc" || return 1
  assert_contains "split argv" "$(stub_log)" \
    "<pane> <split> <--current> <--direction> <right> <--cwd> <$FIX>" || return 1
  assert_not_contains "no reuse send" "$(stub_log)" '<send-text>' || return 1
  unset HERDR_WORKSPACE_ID HERDR_TAB_ID OPEN_IN_EDITOR_REUSE STUB_PANE_LIST STUB_PROCESS_INFO
}

# --- run --------------------------------------------------------------------
run_case "candidates_from: spaces, quotes, punctuation, whitespace" case_candidates_from
run_case "urldecode: UTF-8 bytes, %20, literal %"                   case_urldecode
run_case "normalize: urls, paths, ~, line:col, rejects"            case_normalize
run_case "editor: vi with column -> +call cursor(l,c)"             case_editor_vi_col
run_case "editor: vim with line -> +line"                          case_editor_vim_line
run_case "editor: code -> -g file:line:col"                        case_editor_code
run_case "editor: zed/hx/subl -> file:line:col"                    case_editor_zed_hx_subl
run_case "editor: nano -> +line,col"                               case_editor_nano
run_case "editor: emacs -> +line:col"                              case_editor_emacs
run_case "route: selection via HERDR_PLUGIN_CONTEXT_JSON"          case_route_selection
run_case "route: clicked URL via HERDR_PLUGIN_CLICKED_URL"         case_route_clicked_url
run_case "route: clipboard via --clipboard + OPEN_IN_EDITOR_CLIP"  case_route_clipboard
run_case "route: empty clipboard skips (exit 0, no herdr)"         case_route_empty_clipboard
run_case "guard: missing jq exits non-zero with install hint"      case_guard_missing_jq
run_case "non-dry: stub pane split + pane run leading space"       case_non_dry_split_and_run
run_case "#5: split direction env + invalid fallback"             case_split_direction
run_case "#5: ../ candidate outside pane cwd canonicalizes"        case_path_outside_cwd
run_case "#4: reuse a vi-family pane in the current tab"         case_reuse_vi_pane
run_case "#4: tabless vi falls back to :edit in reused pane"    case_reuse_vi_tabless
run_case "#4: OPEN_IN_EDITOR_REUSE=0 restores split-always"      case_reuse_disabled

# --- summary ----------------------------------------------------------------
printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" -gt 0 ]; then
  printf 'failed cases:\n'
  for c in "${FAILED_CASES[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
exit 0
