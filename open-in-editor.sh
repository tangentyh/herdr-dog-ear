#!/usr/bin/env bash
# open-in-editor — herdr plugin action.
#
# Ctrl-click a file link, select any text, OR pass --clipboard to read the system
# clipboard; opens the file in $EDITOR. A vi-family editor already running in
# the current tab is reused: vim/nvim open the file in a tab page (`:tab drop`),
# minimal/traditional vi falls back to `:edit`; every other case splits a new
# pane off the current tab. A trailing :line or :line:col on the candidate is
# passed to the editor too (vim +<line>, code -g file:line:col, ...).
#
# Context arrives through herdr plugin env vars:
#   HERDR_PLUGIN_CLICKED_URL   set for link_handlers invocations
#   HERDR_PLUGIN_CONTEXT_JSON  full context; .selected_text for selection invocations
#
# Split direction: OPEN_IN_EDITOR_SPLIT_DIRECTION=right (default) or down.
#
# Dry run: OPEN_IN_EDITOR_DRY=1 bash open-in-editor.sh
# Line dry run: OPEN_IN_EDITOR_DRY=1 OPEN_IN_EDITOR_CLIP=src/main.rs:42 bash open-in-editor.sh --clipboard
# Clipboard dry run: OPEN_IN_EDITOR_DRY=1 OPEN_IN_EDITOR_CLIP=src/main.rs bash open-in-editor.sh --clipboard
# Always split: OPEN_IN_EDITOR_REUSE=0 bash open-in-editor.sh
set -uo pipefail

log() { printf 'open-in-editor: %s\n' "$*"; }

HERDR=${HERDR_BIN_PATH:-herdr}
ctx_json=${HERDR_PLUGIN_CONTEXT_JSON:-}

# Where the new pane goes. Only the values herdr's pane split accepts are
# allowed; anything else is a typo, so warn loudly and keep the old default
# rather than handing herdr a bad --direction.
split_direction=${OPEN_IN_EDITOR_SPLIT_DIRECTION:-right}
case "$split_direction" in
  right|down) ;;
  *)
    log "warn: invalid OPEN_IN_EDITOR_SPLIT_DIRECTION='$split_direction' (expected right or down); using right"
    split_direction=right ;;
esac

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

# Canonicalize an absolute path without requiring realpath(1) (often missing
# on macOS). Resolve the parent directory physically with `cd ... && pwd -P`
# and reattach the basename, so `.`/`..` and symlinked cwds come out clean and
# the derived --cwd points at the real directory. realpath(1) is used only when
# it happens to be present, since it also resolves a symlinked final component.
# Falls back to the input unchanged if nothing can be resolved.
canonicalize() {
  local p=$1 dir base rp
  [ -n "$p" ] || { printf '%s' "$p"; return 0; }
  case "$p" in /*) ;; *) printf '%s' "$p"; return 0 ;; esac
  if command -v realpath >/dev/null 2>&1 && rp=$(realpath "$p" 2>/dev/null) && [ -n "$rp" ]; then
    printf '%s' "$rp"; return 0
  fi
  if [ -d "$p" ]; then
    (cd "$p" 2>/dev/null && pwd -P) && return 0
  fi
  dir=$(dirname "$p"); base=$(basename "$p")
  if rp=$(cd "$dir" 2>/dev/null && pwd -P); then
    printf '%s/%s' "$rp" "$base"; return 0
  fi
  printf '%s' "$p"
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

  path=$(canonicalize "$path")

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

# --- pane reuse -------------------------------------------------------------
# vi-family editors accept an ex command that opens a file inside the running
# instance, so a click can retarget the editor pane already in this tab instead
# of splitting a new one. vim/nvim open it in a tab page (`:tab drop` reuses the
# existing tab when the file is already open, so repeated clicks do not stack
# duplicates); minimal builds and traditional vi, which lack tabs, fall back to
# `:edit`. Other editors get the split: there is no generic "open in the running
# instance" protocol, and sending guessed keystrokes to a foreign TUI is worse
# than an extra pane. Keys are never sent to an arbitrary pane: the send path is
# reachable only after find_reusable_pane matched $editor_bin exactly once.
vi_family() {
  case "$1" in
    vi|vim|nvim|vim.basic|vim.tiny|vim.gtk|vimx|gvim|gview|nvim-qt|vi.basic|vi.tiny)
      return 0 ;;
    *) return 1 ;;
  esac
}

# vi-family editors with tab pages. vim.tiny/vi.tiny and traditional vi are
# built without +windows, so they keep the `:edit` fallback.
vi_tabs() {
  case "$1" in
    vim|nvim|vim.basic|vi.basic|vim.gtk|vimx|gvim|gview|nvim-qt) return 0 ;;
    *) return 1 ;;
  esac
}

# Escape a filename for a vim ex command (:edit). Mirrors fnameescape(): the
# characters vim treats specially on the command line get a backslash, as do a
# leading `+`/`>`. Paths are absolute here, so `#`/`%` would otherwise expand to
# the alternate/current file name.
vim_escape() {
  local s=$1 out="" c i
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case "$c" in
      $'\n') out+='\n' ;;
      ' ' | $'\t' | '*' | '?' | '[' | '{' | '`' | '$' | '\' | '%' | '#' | "'" | '"' | '|' | '!' | '<')
        out+="\\$c" ;;
      *) out+=$c ;;
    esac
  done
  case "$out" in '+'* | '>'*) out="\\$out" ;; esac
  printf '%s' "$out"
}

# Print the id of the single pane in the current tab whose foreground-process
# basename is $1, or nothing when there is not exactly one. Read-only.
find_reusable_pane() {
  local want=$1 panes pids pid info names n found="" count=0
  [ -n "${HERDR_WORKSPACE_ID:-}" ] && [ -n "${HERDR_TAB_ID:-}" ] || return 1
  panes=$("$HERDR" pane list --workspace "$HERDR_WORKSPACE_ID" 2>/dev/null) || return 1
  pids=$(printf '%s' "$panes" \
    | jq -r --arg tab "$HERDR_TAB_ID" \
        '.result.panes[]? | select(.tab_id == $tab) | .pane_id' 2>/dev/null)
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    info=$("$HERDR" pane process-info --pane "$pid" 2>/dev/null) || continue
    names=$(printf '%s' "$info" | jq -r \
      '.result.process_info.foreground_processes[]? | [.argv0, .name, (.argv[0]?)] | .[] | select(. != null)' 2>/dev/null)
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      if [ "${n##*/}" = "$want" ]; then
        found=$pid; count=$((count + 1)); break
      fi
    done <<EOF
$names
EOF
  done <<EOF
$pids
EOF
  [ "$count" -eq 1 ] && printf '%s' "$found"
}

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

# Reuse an existing editor pane in this tab when it is safe: exactly one pane in
# the tab is running the same vi-family editor. OPEN_IN_EDITOR_REUSE=0 restores
# the always-split behavior.
reuse_pane=""
reuse_cmd=""
if [ "${OPEN_IN_EDITOR_REUSE:-1}" != "0" ] && vi_family "$editor_bin" && [ "$HAVE_JQ" = 1 ]; then
  reuse_pane=$(find_reusable_pane "$editor_bin")
  if [ -n "$reuse_pane" ]; then
    if vi_tabs "$editor_bin"; then open_ex=":tab drop"; else open_ex=":edit"; fi
    reuse_cmd="$open_ex $(vim_escape "$path")"
    if [ -n "$line" ]; then
      if [ -n "$col" ]; then reuse_cmd="$reuse_cmd | call cursor($line,$col)"
      else reuse_cmd="$reuse_cmd | call cursor($line)"; fi
    fi
  fi
fi

if [ "${OPEN_IN_EDITOR_DRY:-0}" = "1" ]; then
  if [ -n "$reuse_pane" ]; then
    log "dry-run: reuse pane $reuse_pane: $reuse_cmd"
  else
    log "dry-run: split $split_direction cwd=$dir ; run: $cmd"
  fi
  exit 0
fi

# Guarded send: only reached when find_reusable_pane matched $editor_bin in
# this tab. Esc first normalizes insert/command-line mode.
if [ -n "$reuse_pane" ]; then
  if "$HERDR" pane send-keys "$reuse_pane" esc >/dev/null 2>&1 \
     && "$HERDR" pane send-text "$reuse_pane" "$reuse_cmd" >/dev/null 2>&1 \
     && "$HERDR" pane send-keys "$reuse_pane" enter >/dev/null 2>&1; then
    log "reused pane $reuse_pane: $reuse_cmd"
    exit 0
  fi
  log "error: reuse in pane $reuse_pane failed; opening in a split"
fi

if [ -n "${HERDR_PANE_ID:-}" ]; then
  target_args=(--pane "$HERDR_PANE_ID")
else
  target_args=(--current)
fi

split=$("$HERDR" pane split "${target_args[@]}" --direction "$split_direction" --cwd "$dir" 2>&1)
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
