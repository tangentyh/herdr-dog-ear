#!/usr/bin/env bash
# open-in-editor — herdr plugin action.
#
# Ctrl-click a file link, select any text, OR pass --clipboard to read the system
# clipboard; opens the file in $EDITOR in a new pane split off the current tab.
# A trailing :line or :line:col on the candidate is passed to the editor too
# (vim +<line>, code -g file:line:col, ...).
#
# Context arrives through herdr plugin env vars:
#   HERDR_PLUGIN_CLICKED_URL   set for link_handlers invocations
#   HERDR_PLUGIN_CONTEXT_JSON  full context; .selected_text for selection invocations
#
# Dry run: OPEN_IN_EDITOR_DRY=1 bash open-in-editor.sh
# Line dry run: OPEN_IN_EDITOR_DRY=1 OPEN_IN_EDITOR_CLIP=src/main.rs:42 bash open-in-editor.sh --clipboard
# Clipboard dry run: OPEN_IN_EDITOR_DRY=1 OPEN_IN_EDITOR_CLIP=src/main.rs bash open-in-editor.sh --clipboard
set -uo pipefail

log() { printf 'open-in-editor: %s\n' "$*"; }

HERDR=${HERDR_BIN_PATH:-herdr}
ctx_json=${HERDR_PLUGIN_CONTEXT_JSON:-}

# jq is a hard runtime dependency: it reads the context JSON and the pane id
# from `herdr pane split`. Detect it once so a missing jq is a loud, actionable
# error instead of a silent "nothing clicked or selected" no-op.
if command -v jq >/dev/null 2>&1; then
  HAVE_JQ=1
else
  HAVE_JQ=0
  log "error: jq not found on PATH; it is required to read plugin context and pane ids"
  log "  install: brew install jq | sudo apt install jq | sudo dnf install jq"
fi

ctx() { [ -n "$ctx_json" ] && [ "$HAVE_JQ" = 1 ] && printf '%s' "$ctx_json" | jq -r "$1" 2>/dev/null; }

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

# Percent-decode a URL path, replacing the old python3/urllib one-liner. A
# literal "%" not followed by two hex digits is left alone, so the tempting
# `printf '%b' "${s//%/\\x}"` shortcut would be wrong here: it emits a literal
# \x and mangles paths like "100% done.txt".
urldecode() {
  local s=$1 out="" n
  while [ -n "$s" ]; do
    case $s in
      %[0-9a-fA-F][0-9a-fA-F]*)
        n=$((16#${s:1:2}))
        printf -v n '\\%03o' "$n"          # raw byte, not a codepoint
        out+=$(printf '%b' "$n")
        s=${s:3} ;;
      *) out+=${s:0:1}; s=${s:1} ;;
    esac
  done
  printf '%s' "$out"
}

# Resolve a candidate into the globals norm_path/norm_line/norm_col. Returns 0
# when it names something that exists on disk. A trailing :line or :line:col is
# peeled off and kept for the editor invocation, not discarded.
normalize() {
  local t=$1 path rest
  norm_path=""; norm_line=""; norm_col=""
  [ -n "$t" ] || return 1
  case "$t" in
    file://*)
      rest=${t#file://}
      case "$rest" in
        /*) path=$rest ;;                 # file:///abs/path (empty host)
        *)  path=/${rest#*/} ;;           # file://host/abs/path (named host)
      esac
      path=$(urldecode "$path")
      ;;
    *://*) return 1 ;;                    # http(s) etc: not ours
    *) path=$t ;;
  esac

  # Peel a trailing :line[:col] before checking the filesystem.
  if [[ $path =~ ^(.*):([0-9]+):([0-9]+)$ ]]; then
    path=${BASH_REMATCH[1]}; norm_line=${BASH_REMATCH[2]}; norm_col=${BASH_REMATCH[3]}
  elif [[ $path =~ ^(.*):([0-9]+)$ ]]; then
    path=${BASH_REMATCH[1]}; norm_line=${BASH_REMATCH[2]}
  fi

  case "$path" in '~/'*) path="$HOME/${path#\~/}" ;; esac
  if [ "${path#/}" = "$path" ]; then
    path="$(pane_cwd)/$path"
  fi

  [ -e "$path" ] || return 1
  norm_path=$path
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
    [ "$HAVE_JQ" = 1 ] || exit 1        # jq error already reported above
    log "skip: nothing clicked or selected"
    log "  ctx: ${ctx_json:-<unset>}"
    exit 0
  fi
  cands=$(candidates_from "$sel")
fi

# --- first candidate that resolves to something on disk ---------------------
path=""; line=""; col=""
while IFS= read -r c; do
  [ -n "$c" ] || continue
  if normalize "$c"; then
    path=$norm_path; line=$norm_line; col=$norm_col
    log "matched: $c"
    break
  fi
done <<EOF
$cands
EOF

if [ -z "$path" ]; then
  log "skip: no existing path in: $(printf '%s' "$cands" | tr '\n' ' ')"
  exit 0
fi

# --- open it ----------------------------------------------------------------
if [ -d "$path" ]; then dir=$path; else dir=$(dirname "$path"); fi
loc=""
[ -n "$line" ] && loc=" line $line" && [ -n "$col" ] && loc="$loc:$col"
log "open: $path$loc"

# Map :line[:col] onto the editor's own flag. Unknown editors get `+<line>`,
# the near-universal convention; vi-family uses +call cursor() when a column is
# known. The path is absolute by now, so `--` is belt-and-braces, not required.
editor=${EDITOR:-vi}
editor_bin=${editor%% *}; editor_bin=${editor_bin##*/}
args=()
if [ -n "$line" ]; then
  case "$editor_bin" in
    code|code-insiders|codium)
      args+=(-g "$path:$line${col:+:$col}") ;;   # location rides in the goto arg
    zed|hx|helix|subl|sublime_text)
      args+=(-- "$path:$line${col:+:$col}") ;;
    nano)
      args+=("+$line${col:+,$col}" -- "$path") ;;
    emacs|emacsclient)
      args+=("+$line${col:+:$col}" "$path") ;;
    *)
      if [ -n "$col" ]; then args+=("+call cursor($line,$col)" -- "$path")
      else args+=("+$line" -- "$path"); fi ;;
  esac
else
  args+=(-- "$path")
fi

cmd="exec $editor"
for a in "${args[@]}"; do cmd="$cmd $(printf '%q' "$a")"; done

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
if [ "$HAVE_JQ" != 1 ]; then
  log "error: jq required to read the pane id; got: $split"
  exit 1
fi
pane=$(printf '%s' "$split" | jq -r '.result.pane.pane_id // empty' 2>/dev/null)
if [ -z "$pane" ]; then log "error: split failed: $split"; exit 1; fi

# Prefix with a space so a zsh pane running `setopt hist_ignore_space`
# (oh-my-zsh default) does not record the injected command in its history.
if "$HERDR" pane run "$pane" " $cmd" >/dev/null 2>&1; then
  log "opened in pane $pane"
else
  log "error: pane run failed in $pane"
fi
