# herdr-dog-ear

**Ctrl-click a `file://` link — or select any text that names a path — and it opens in `$EDITOR`:
a vi-family editor already running in the current tab is reused, otherwise a new pane splits off
the tab.**

Works with whatever `$EDITOR` is set to. No picker, no repo scan, no editor-specific integration.
One action handles both a ctrl-clicked link and a keyboard-invoked selection.

> **Requires herdr ≥ 0.9.0.** `file://` OSC-8 link clicks did not reach plugin `link_handlers`
> before 0.9.0 ([herdr#2941](https://github.com/herdrdev/herdr/issues/2941)). The version floor is
> load-bearing.
>
> **Requires `jq`.** The action reads the plugin context JSON and the `herdr pane split` reply
> through it. Without `jq` it reports the missing dependency with an install hint
> (`brew install jq` · `sudo apt install jq` · `sudo dnf install jq`) and cannot open anything —
> it never fails silently. No Python needed: percent-decoding is done in bash.

## Install

```sh
herdr plugin install tangentyh/herdr-dog-ear
```

For local development, link the checkout instead:

```sh
herdr plugin link ~/path/to/herdr-dog-ear
herdr server reload-config
```

## Usage

**Link click.** Agents and tools that emit OSC-8 `file://` links (e.g. `file:///abs/path`)
become ctrl-clickable. The modifier is **Control on every platform, including macOS** — captured
terminal mouse reports can't tell Cmd from a plain click.

**Selection.** Select text naming a path and invoke the action from a key:

```toml
[[keys.command]]
key = "prefix+e"
type = "plugin_action"
command = "dogear.edit-file"
description = "open selection in $EDITOR"
```

The action tries the whole first selected line first (so paths containing spaces survive), then
every whitespace-delimited token with wrapping punctuation stripped. The first candidate that
exists on disk wins.

**Clipboard.** herdr does not hand selected text to plugins, so if the selection route is
unavailable, copy the path and invoke the clipboard action from a key:

```toml
[[keys.command]]
key = "prefix+shift+o"
type = "plugin_action"
command = "dogear.edit-clipboard"
description = "open clipboard path in $EDITOR"
```

It reads the system clipboard (`pbpaste`, `wl-paste`, `xclip`, or `xsel`) and runs the same
extraction as the selection route. If nothing on the clipboard resolves to a file on disk, it
does nothing. `OPEN_IN_EDITOR_CLIP` overrides the clipboard for testing.

This second action is a workaround, not a preference: herdr does not reliably hand selected text
to plugins, so the selection route cannot always see it. Once a selection invocation reliably
carries `.selected_text`, the clipboard action is redundant and can be dropped.

**Line and column.** A trailing `:line` or `:line:col` on any route is passed through to the
editor rather than dropped, so `src/main.rs:42` opens at line 42. The flag is chosen from
`$EDITOR`:

| Editor | Invocation |
|---|---|
| `code`, `codium` | `code -g file:line:col` |
| `zed`, `hx`, `subl` | `zed file:line:col` |
| `nano` | `nano +line,col` |
| `emacs`, `emacsclient` | `emacs +line:col` |
| anything else (vi, vim, nvim, …) | `vim +line`; `+call cursor(line,col)` when a column is given |

Every route opens the file in a new pane split off the current tab — **right** by default — with
the pane's cwd set to the file's directory. The one exception is a reused editor pane (below).

## Pane reuse

Clicking file after file in one tab used to leave a trail of editor panes. By default the action
now reuses an editor pane **already running in the current tab** instead of splitting another one
(the reused vim gets a tab per file, so you also get a visible hint of what is open):

1. It lists the panes in this tab (`herdr pane list --workspace "$HERDR_WORKSPACE_ID"`, keeping
   `tab_id == "$HERDR_TAB_ID"`) and asks each one for its foreground process
   (`herdr pane process-info`).
2. If **exactly one** pane is running `$EDITOR` (basename of its first word — the same rule used
   for argument mapping), the file opens there. vim and nvim open it in a **tab page** via
   `:tab drop <path>`, so the tabline shows what is already open and a repeated click jumps to
   the existing tab instead of stacking duplicates. Minimal builds and traditional `vi`, which
   have no tabs, fall back to `:edit`. When the candidate carried a line/column the plugin also
   runs `:call cursor(<line>[, <col>])`. Filenames are escaped like vim's `fnameescape()`, so
   spaces and `%`/`#` survive.
3. Otherwise — no editor pane, more than one, or an editor with no generic "open in the running
   instance" protocol — it falls back to the existing split.

Set `OPEN_IN_EDITOR_REUSE=0` to always split, reproducing the previous behavior.

Switch between the opened files with vim's tab commands: `gt`/`gT`, `:tabnext N`, `:tabclose`, or
`:tabs` to list them. (With the `:edit` fallback on tabless vi, they are hidden buffers instead:
`:ls`, `:bnext`, `<C-^>`.)

**Reuse is vi-family only, on purpose.** `$EDITOR` values such as `code`, `zed`, or `emacs` can
open in an existing window, but only by invoking their CLI against that window; there is no
generic "open in the running instance" protocol, and the process table alone does not say
reliably which pane hosts it. Sending guessed keystrokes to a foreign TUI is worse than an extra
pane, so those editors always split. Keys are never sent to a pane that did not match `$EDITOR`
exactly.

**Split direction.** Set `OPEN_IN_EDITOR_SPLIT_DIRECTION` to `right` (default) or `down` to
choose where the new pane appears. Any other value is ignored with a warning and `right` is used,
so a typo never breaks the action. Set it in the environment herdr (and therefore the action) is
launched from, or try it in a dry run:

```sh
OPEN_IN_EDITOR_SPLIT_DIRECTION=down OPEN_IN_EDITOR_DRY=1 bash open-in-editor.sh --clipboard
```

The value flows into both the real `herdr pane split --direction ...` call and the
`OPEN_IN_EDITOR_DRY=1` log line.

**Path resolution.** A relative candidate is joined with the pane's cwd and then canonicalized
(`.`/`..` folded and symlinked directories resolved) before the existence check and before the
file's directory is used as `--cwd`. So a candidate like `../sibling/file.rs` opens even when it
lives outside the pane cwd, and the logged path and pane cwd are clean absolute paths rather than
`<cwd>/../sibling/file.rs`. Canonicalization uses `realpath` only when it is already installed and
otherwise falls back to `cd ... && pwd -P`, so no new dependency is required.

## Caveat: bare paths are not detected as links

`src/main.rs:42` in a terminal is **not** a link span, and no `link_handlers` pattern can make it
one — spans only begin at `http(s)://`
([herdr#1699](https://github.com/herdrdev/herdr/discussions/1699)). Ctrl-clicking a bare path does
nothing. For bare paths, use the **selection** route. The plugin deliberately ships no bare-path
link handler: a `link_handlers` pattern only filters links herdr has already detected, and herdr
never detects a bare path, so such a handler could never fire.

## What arrives in the action

| Variable | Set for |
|---|---|
| `HERDR_PLUGIN_CLICKED_URL` | link_handlers invocations |
| `HERDR_PLUGIN_LINK_HANDLER_ID` | link_handlers invocations |
| `HERDR_PLUGIN_CONTEXT_JSON` | all invocations (`.selected_text`, `.focused_pane_cwd`) |
| `HERDR_ACTIVE_PANE_CWD` | where available |
| `HERDR_PANE_ID` | focused pane |

## Development

```sh
# link / relink (link mode skips [[build]] steps, builds lazily)
herdr plugin link ~/.config/herdr/plugins/dogear
herdr plugin list
herdr plugin action list --plugin dogear

# after editing the manifest or config.toml
herdr server reload-config

# what the action actually did
herdr plugin log list --plugin dogear

# dry run without touching panes
OPEN_IN_EDITOR_DRY=1 bash open-in-editor.sh
OPEN_IN_EDITOR_DRY=1 OPEN_IN_EDITOR_CLIP=src/main.rs:42 bash open-in-editor.sh --clipboard
EDITOR=code OPEN_IN_EDITOR_DRY=1 OPEN_IN_EDITOR_CLIP=src/main.rs:42:7 bash open-in-editor.sh --clipboard
OPEN_IN_EDITOR_SPLIT_DIRECTION=down OPEN_IN_EDITOR_DRY=1 OPEN_IN_EDITOR_CLIP=../sibling/file.rs bash open-in-editor.sh --clipboard
# force the old always-split behavior
OPEN_IN_EDITOR_REUSE=0 OPEN_IN_EDITOR_DRY=1 OPEN_IN_EDITOR_CLIP=src/main.rs bash open-in-editor.sh --clipboard

# emit a clickable OSC 8 file link to test the handler, in a pane:
printf '\e]8;;file:///tmp/probe.txt\e\\FILE\e]8;;\e\\\n'
# then ctrl-click FILE (not cmd-click)
```

## Testing

```sh
bash tests/run.sh
```

A dependency-light smoke/unit suite: pure bash plus POSIX tools, no `bats` or `python3`. It prints
one `PASS`/`FAIL`/`SKIP` line per case and exits non-zero if any case fails.

The suite is hermetic. It creates a `mktemp -d` sandbox (removed on exit) for fixtures and logs,
and every `herdr` call is intercepted by the stub in `tests/stub/herdr` — nothing touches the live
session, and no panes, tabs, or workspaces are created. The stub records each invocation's argv
and returns the JSON `pane split` reply and a successful `pane run`, so the non-dry path is
covered too.

Cases cover: `candidates_from()` (spaces, quotes, trailing punctuation, whitespace tokens),
`urldecode()` (percent-encoded UTF-8 as raw bytes, literal `%`, `%20`), `normalize()`
(`file://` URLs with empty/named host, absolute/relative/`~/` paths, `:line`, `:line:col`,
rejections), the `$EDITOR` line/column flag mapping, the selection/clicked-URL/clipboard routes
plus the empty-clipboard skip, the missing-`jq` guard, and the stub `pane split`/`pane run`
argv. If `jq` is not installed, the cases that need it report `SKIP` instead of failing.

## License

MIT — see [LICENSE](LICENSE).
