# herdr-dog-ear

**Ctrl-click a `file://` link — or select any text that names a path — and it opens in `$EDITOR`
in a pane split off the current tab.**

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
command = "open-in-editor.edit-file"
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
command = "open-in-editor.edit-clipboard"
description = "open clipboard path in $EDITOR"
```

It reads the system clipboard (`pbpaste`, `wl-paste`, `xclip`, or `xsel`) and runs the same
extraction as the selection route. If nothing on the clipboard resolves to a file on disk, it
does nothing. `OPEN_IN_EDITOR_CLIP` overrides the clipboard for testing.

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

Every route opens the file in a new pane split to the right of the current tab, with the pane's
cwd set to the file's directory.

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
herdr plugin link ~/.config/herdr/plugins/open-in-editor
herdr plugin list
herdr plugin action list --plugin open-in-editor

# after editing the manifest or config.toml
herdr server reload-config

# what the action actually did
herdr plugin log list --plugin open-in-editor

# dry run without touching panes
OPEN_IN_EDITOR_DRY=1 bash open-in-editor.sh
OPEN_IN_EDITOR_DRY=1 OPEN_IN_EDITOR_CLIP=src/main.rs:42 bash open-in-editor.sh --clipboard
EDITOR=code OPEN_IN_EDITOR_DRY=1 OPEN_IN_EDITOR_CLIP=src/main.rs:42:7 bash open-in-editor.sh --clipboard

# emit a clickable OSC 8 file link to test the handler, in a pane:
printf '\e]8;;file:///tmp/probe.txt\e\\FILE\e]8;;\e\\\n'
# then ctrl-click FILE (not cmd-click)
```

## License

MIT — see [LICENSE](LICENSE).
