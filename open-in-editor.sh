#!/usr/bin/env bash
# open-in-editor — herdr plugin action.
#
# Ctrl-click a file link, OR select any text and invoke the action from a key:
# opens the file in $EDITOR in a new pane split off the current tab.
#
# Context arrives through herdr plugin env vars:
#   HERDR_PLUGIN_CLICKED_URL   set for link_handlers invocations
#   HERDR_PLUGIN_CONTEXT_JSON  full context; .selected_text for selection invocations
#
# Dry run: OPEN_IN_EDITOR_DRY=1 bash open-in-editor.sh
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

# --- build candidate list ---------------------------------------------------
cands=""
if [ -n "${HERDR_PLUGIN_CLICKED_URL:-}" ]; then
  cands=${HERDR_PLUGIN_CLICKED_URL}
else
  sel=$(ctx '.selected_text // empty')
  if [ -z "$sel" ]; then
    log "skip: nothing clicked or selected"
    log "  ctx: ${ctx_json:-<unset>}"
    exit 0
  fi
  # whole first line first (a path containing spaces survives),
  # then every whitespace-delimited token with wrapping punctuation stripped
  cands=$(printf '%s' "$sel" | head -1)
  cands="$cands
$(printf '%s' "$sel" \
    | tr ' \t' '\n\n' \
    | sed -E "s/^[\`'\"(<[]+//; s/[\`'\"()>\].,;]+$//")"
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
