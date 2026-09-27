#!/usr/bin/env bash
# open-in-editor — herdr plugin action.
#
# Ctrl-click a file link, select any text, OR pass --clipboard to read the system
# clipboard; opens the file in $EDITOR in a new pane split off the current tab.
#
# Context arrives through herdr plugin env vars:
#   HERDR_PLUGIN_CLICKED_URL   set for link_handlers invocations
#   HERDR_PLUGIN_CONTEXT_JSON  full context; .selected_text for selection invocations
#
# Dry run: OPEN_IN_EDITOR_DRY=1 bash open-in-editor.sh
# Clipboard dry run: OPEN_IN_EDITOR_DRY=1 OPEN_IN_EDITOR_CLIP=src/main.rs bash open-in-editor.sh --clipboard
set -uo pipefail

log() { printf 'open-in-editor: %s\n' "$*"; }

HERDR=${HERDR_BIN_PATH:-herdr}
ctx_json=${HERDR_PLUGIN_CONTEXT_JSON:-}
ctx() { [ -n "$ctx_json" ] && printf '%s' "$ctx_json" | jq -r "$1" 2>/dev/null; }

pane_cwd() {
  local cwd=${HERDR_ACTIVE_PANE_CWD:-}
  [ -n "$cwd" ] || cwd=$(ctx '.focused_pane_cwd // empty')
  [ -n "$cwd" ] || cwd=$PWD
  printf '%s' "$cwd"
}

# Read the system clipboard, cross-platform. OPEN_IN_EDITOR_CLIP overrides it
# (used by the dry-run smoke test).
read_clipboard() {
  if [ -n "${OPEN_IN_EDITOR_CLIP:-}" ]; then printf '%s' "$OPEN_IN_EDITOR_CLIP"; return; fi
  if command -v pbpaste >/dev/null 2>&1; then
    pbpaste
  elif command -v wl-paste >/dev/null 2>&1; then
    wl-paste --no-newline 2>/dev/null || wl-paste
  elif command -v xclip >/dev/null 2>&1; then
    xclip -selection clipboard -o 2>/dev/null
  elif command -v xsel >/dev/null 2>&1; then
    xsel --clipboard --output 2>/dev/null
  fi
}

# Print an absolute, existing path for a candidate, or nothing.
normalize() {
  local t=$1 path rest
  [ -n "$t" ] || return 0
  case "$t" in
    file://*)
      rest=${t#file://}
      case "$rest" in
        /*) path=$rest ;;                 # file:///abs/path (empty host)
        *)  path=/${rest#*/} ;;           # file://host/abs/path (named host)
      esac
      path=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.unquote(sys.argv[1]))' "$path")
      ;;
    *://*) return 0 ;;                    # http(s) etc: not ours
    *) path=$t ;;
  esac

  path=$(printf '%s' "$path" | sed -E 's/:[0-9]+(:[0-9]+)?$//')   # strip :line:col
  case "$path" in '~/'*) path="$HOME/${path#\~/}" ;; esac
  if [ "${path#/}" = "$path" ]; then
    path="$(pane_cwd)/$path"
  fi

  [ -e "$path" ] && printf '%s' "$path"
  return 0
}

# --- gather source text -----------------------------------------------------
mode=link
for arg in "$@"; do
  case "$arg" in --clipboard) mode=clipboard ;; esac
done

# whole first line first (a path containing spaces survives),
# then every whitespace-delimited token with wrapping punctuation stripped
candidates_from() {
  printf '%s\n' "$1" | head -1
  printf '%s' "$1" \
    | tr ' \t' '\n\n' \
    | sed -E "s/^[\`'\"(<[]+//; s/[]\`'\"()>.,;]+$//"
}

cands=""
if [ "$mode" = clipboard ]; then
  clip=$(read_clipboard)
  if [ -z "$clip" ]; then
    log "skip: clipboard empty (or no pbpaste/wl-paste/xclip/xsel available)"
    exit 0
  fi
  log "clipboard: $(printf '%s' "$clip" | head -1)"
  cands=$(candidates_from "$clip")
elif [ -n "${HERDR_PLUGIN_CLICKED_URL:-}" ]; then
  cands=${HERDR_PLUGIN_CLICKED_URL}
else
  sel=$(ctx '.selected_text // empty')
  if [ -z "$sel" ]; then
    log "skip: nothing clicked or selected"
    log "  ctx: ${ctx_json:-<unset>}"
    exit 0
  fi
  cands=$(candidates_from "$sel")
fi

# --- first candidate that resolves to something on disk ---------------------
path=""
while IFS= read -r c; do
  [ -n "$c" ] || continue
  p=$(normalize "$c")
  if [ -n "$p" ]; then path=$p; log "matched: $c"; break; fi
done <<EOF
$cands
EOF

if [ -z "$path" ]; then
  log "skip: no existing path in: $(printf '%s' "$cands" | tr '\n' ' ')"
  exit 0
fi

# --- open it ----------------------------------------------------------------
if [ -d "$path" ]; then dir=$path; else dir=$(dirname "$path"); fi
log "open: $path"

cmd="exec \${EDITOR:-vi} -- $(printf '%q' "$path")"

if [ "${OPEN_IN_EDITOR_DRY:-0}" = "1" ]; then
  log "dry-run: split right cwd=$dir ; run: $cmd"
  exit 0
fi

if [ -n "${HERDR_PANE_ID:-}" ]; then
  target_args=(--pane "$HERDR_PANE_ID")
else
  target_args=(--current)
fi

split=$("$HERDR" pane split "${target_args[@]}" --direction right --cwd "$dir" 2>&1)
pane=$(printf '%s' "$split" | jq -r '.result.pane.pane_id // empty' 2>/dev/null)
if [ -z "$pane" ]; then log "error: split failed: $split"; exit 1; fi

if "$HERDR" pane run "$pane" "$cmd" >/dev/null 2>&1; then
  log "opened in pane $pane"
else
  log "error: pane run failed in $pane"
fi
