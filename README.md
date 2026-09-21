# Camelot

*A context bridge between the Linux desktop and an AI.*

Camelot lets an AI see what you are doing on your desktop. It reads the
AT-SPI2 accessibility tree — the same structured view screen readers use —
and reports the active application, the window, the widget that has focus,
the text around your caret, and the whole widget tree when you want it.
Everything comes out as `text` for humans or `json`/`yaml` for machines.

This is the first layer of a larger plan (semantic context now; screen
capture and input later; a daemon and MCP tools on top of the CLI). The CLI
is defined with [Jargon](https://github.com/trans/jargon) JSON Schemas, so
the same command definitions double as tool definitions for an AI.

## Requirements

- Linux with AT-SPI2 running (any GNOME session; other desktops with
  `at-spi2-core` started). Wayland and X11 both work.
- `libatspi` and its GObject-Introspection data (`Atspi-2.0.typelib`,
  `Atspi-2.0.gir`). Arch: `at-spi2-core gobject-introspection`;
  Debian/Ubuntu: `libatspi2.0-dev gir1.2-atspi-2.0 libgirepository1.0-dev`.
- Crystal >= 1.21.

## Building

```sh
shards install    # fetches jargon and gi-crystal
bin/gi-crystal    # generates the Atspi bindings from the system .gir
shards build      # -> bin/camelot
```

or `just bindings build`. The bindings are generated once per machine; the
2-line config lives in `src/bindings/atspi/binding.yml`.

## Usage

```
camelot apps                 # applications on the accessibility bus
camelot windows              # top-level windows, active one first
camelot context              # what the user is doing, packaged for an AI
camelot focus                # the widget with keyboard focus (+ its text)
camelot tree [APP]           # the widget tree of an app (default: active app)
camelot at X Y               # the widget under a window-relative point
camelot watch                # stream events: window switches, focus, typing
camelot mcp                  # serve all of the above as MCP tools (stdio)
```

Every command takes `-f json|yaml|text` (`text` is the default). Snapshot
commands share a few knobs:

| Option | Effect |
|--------|--------|
| `--max-text N` | characters of text content kept per node, around the caret (`0` none, `-1` all) |
| `-a`, `--actions` | list the actions each widget offers |
| `--no-extents` | drop position/size |
| `--all-states` | keep the noisy states (`enabled`, `visible`, `showing`...) |
| `--raw` | keep anonymous layout containers instead of pruning them |
| `--hidden` | include hidden widgets (collapsed menus, closed dialogs, background tabs) |
| `-d`, `--depth N` | levels to descend (`tree`, `focus`) |

### `context`

The one an AI wants. Application, window, breadcrumb of named ancestors, and
the focused widget with up to `--max-text` (default 4000) characters of its
text centred on the caret:

```
$ camelot context
application: gnome-text-editor (pid 126092, GTK)
window: frame "notes.md - Text Editor" [active] (1 children)
path: panel "notes.md"
focus: text [editable, focusable, multi line] @0,86 1060x876 {...}
  text (chars 26592-30592 of 41200), caret at 28592:
  | ...
```

```sh
camelot context -f json | curl -s https://api.example/ai -d @-
```

### `tree`

```
$ camelot tree gnome-text-editor
application "gnome-text-editor"
  frame "notes.md - Text Editor" @0,0 1060x962
    panel "notes.md" @0,86 1060x876
      text [editable, focusable, multi line] @0,86 1060x876
        text (chars 28392-28592 of 28592), caret at 28592:
        | ...
      scroll bar [vertical] =22761.0 @1049,86 11x876
    button "Open" @-1,0 78x34 — Recently Used Documents
    ...
```

Apps are matched by pid, exact name, or case-insensitive substring. Use
`-p 0/2` to start at an index path inside the app. By default the tree is
*pruned*: unnamed `panel`/`grouping`/`filler`… containers with nothing to say
are spliced out so GTK's dozen layers of layout boxes don't bury the content.
`--raw` turns that off. Either way each node's `path` is its real index path
from the application root, so `pid` + `path` addresses the widget again.

### `at`

Coordinates are relative to the active window's top-left (`--app NAME` to
pick another app's window). On Wayland that is the only kind of coordinate a
toolkit can answer; `--screen` uses absolute screen coordinates and searches
every window, which works for X11/XWayland applications.

### Browsers

Firefox and Chromium only build their accessibility tree if accessibility
was enabled when they started. On GNOME that is one persistent setting:

```sh
gsettings set org.gnome.desktop.interface toolkit-accessibility true
```

then restart the browser. (This does *not* start a screen reader — only
`screen-reader-enabled` does that.) Elsewhere, Chromium also honours
`--force-renderer-accessibility`. With it on, `camelot tree firefox`
shows the page itself: headings, paragraphs, links, form fields and their
values, in reading order.

## Output shape

A snapshot node (`json`/`yaml`):

```json
{
  "role": "text",
  "name": null,
  "path": "0/4/2/0",
  "pid": 126092,
  "states": ["editable", "focusable", "focused", "multi line"],
  "extents": {"x": 0, "y": 86, "width": 1060, "height": 876},
  "text": {"length": 28592, "caret": 28592, "offset": 28392, "content": "...", "truncated": true},
  "actions": ["page.copy-all", "..."],
  "child_count": 1,
  "children": [ ... ]
}
```

`value` appears for sliders/scrollbars; `description` when the widget has
one; `children` only when the node was expanded (`child_count` says whether
there is more).

### `watch`

```
$ camelot watch
14:52:41.456  window:activate               pinentry-gtk: frame "pinentry-gtk2"
14:52:41.459  object:state-changed:focused  pinentry-gtk: password text gained
14:52:41.627  object:text-changed:insert    kgx: terminal "Terminal" @3875 (54 chars) "..."
```

Streams AT-SPI events as they happen (`-f json` for one JSON object per
line). `-e type,type` picks the event types; the default set is window
activation, focus changes, text edits, caret moves and document loads.
`-t N` stops after N seconds; `--stats N` prints a count to stderr every N
seconds. Text inserted into password fields is never reported.

This is the seed of the daemon. libatspi delivers events through the GLib
main context; `Events::Pump` runs that context inside Crystal's event
loop the way GLib documents for foreign loops: ask GLib what it would poll
(`g_main_context_prepare`/`query`), wait for exactly that in Crystal (a
fiber parked in `wait_readable` per fd, plus GLib's timeout), then let GLib
run a non-blocking iteration. No polling, no second thread; Crystal's own
fibers, IO and timers run alongside, and an idle pump costs ~0.2% CPU
(libatspi's own periodic timeout, not ours).

## MCP

`camelot mcp` serves the commands above as [Model Context Protocol](https://modelcontextprotocol.io)
tools over stdio. The tool definitions are generated from the same Jargon
schemas that drive the CLI, and each call is parsed by Jargon exactly as a
command line would be, so validation, defaults and output are identical.

Register it with Claude Code once (user scope, since it is about your
desktop rather than any one project):

```sh
claude mcp add --scope user camelot -- /path/to/camelot mcp
```

Then in any session: *"look at what I'm looking at"* → the agent calls
`context`; *"what's in my editor?"* → `tree`; and so on. Tools default to
`text` output, which is the most token-efficient; pass `format: json` when
the caller wants structure.

Any MCP client works the same way; the server speaks newline-delimited
JSON-RPC 2.0, protocol version 2025-06-18, tools only.

## What is never captured

Password fields (AT-SPI role `password text`) are reported with
`"redacted": true` and no `text` or `value`, regardless of `--max-text`.
Everything else the focused application exposes to assistive technology —
terminal scrollback, document bodies, chat drafts — *is* captured, so treat
`context` output as sensitive and point it only at an AI you trust with
your screen.

## Development

```sh
crystal spec        # unit specs; no accessibility bus needed
just run context    # run from source
```

Notes on the bindings — places where the generated gi-crystal code is
bypassed on purpose:

- `GArray` returns are not marshalled: `AtspiStateSet.get_states` is ignored
  in `binding.yml` (states are read with `contains`) and
  `atspi_collection_get_matches` is called by hand (`A11y.collection_matches`).
- `Atspi::EventListener.new` builds each event with transfer FULL and frees
  a struct libatspi still owns — a double free per event. `Events::Listener`
  sets the C callback up itself with transfer NONE.
- `Atspi::Event#any_data` does not compile; the GValue is read in place.

## License

MIT — see LICENSE.
