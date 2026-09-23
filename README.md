# Camelot

[![CI](https://github.com/tabcomputing/camelot/actions/workflows/ci.yml/badge.svg)](https://github.com/tabcomputing/camelot/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/tabcomputing/camelot)](https://github.com/tabcomputing/camelot/releases/latest)

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

## Installing

Arch, Debian/Ubuntu and Fedora packages are attached to each
[release](https://github.com/tabcomputing/camelot/releases/latest).
To build them yourself from `pkg/`:

```sh
just pkg-arch && sudo pacman -U pkg/camelot-*.pkg.tar.zst
just pkg-deb  && sudo apt install ./pkg/camelot_*.deb ./pkg/camelot-gtk_*.deb
just pkg-rpm  && sudo dnf install pkg/camelot-*.x86_64.rpm
```

(`pkg-deb` and `pkg-rpm` build inside podman containers, so they work from
any distro.) `camelot` installs the CLI, daemon, systemd user unit and
bash/zsh/fish completions; `camelot-gtk` adds the control panel.
`just test-install` installs the deb and rpm into fresh containers to
check their runtime dependencies.

## Building from source

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
camelot daemon               # background service: warm bus, activity history
camelot recent               # what the user has been doing (needs the daemon)
camelot status               # is the daemon up, what does it hold
camelot mcp                  # serve all of the above as MCP tools (stdio)
camelot-gtk                  # the control panel (separate package)
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
was enabled when they started. On GNOME that is one persistent setting,
which **the daemon turns on for you** at startup (and says so in its log;
`accessibility: false` in config leaves it alone). Without the daemon:

```sh
gsettings set org.gnome.desktop.interface toolkit-accessibility true
```

Either way, restart the browser afterwards. This does *not* start a screen
reader — only `screen-reader-enabled` does that — and camelot never turns
it back off, since a screen reader may depend on it. Elsewhere, Chromium
also honours `--force-renderer-accessibility`. With it on,
`camelot tree firefox` shows the page itself: headings, paragraphs, links,
form fields and their values, in reading order.

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

### `shot`

```sh
camelot shot -o screen.jpg     # the whole screen
camelot shot --pick -o win.jpg # the desktop's picker: a window or a region
camelot shot | your-tool       # JPEG on stdout
```

Capture goes through the XDG desktop portal, so the desktop grants it and
announces each frame its own way (on GNOME, the shutter flash and sound).
A 2560x1440 screen arrives as a ~145 kB JPEG scaled to fit `--max-edge`
(1568 by default, which is as much as a vision model uses).

**Capture is always a pull.** A frame is taken when something asks for
one, handed over, and dropped: no frame enters the event stream or the
daemon's history, which would cost more memory in a minute than the whole
event log does in a day. `screenshots: false` in the config switches
capture off entirely.

### `daemon`, `recent`, `status`

The daemon keeps the bus connection warm and records window switches,
focus changes and edits; `recent` digests them into what the user has been
doing, with bursts of edits on one widget folded into a single line:

```
$ systemctl --user enable --now camelot     # or: camelot daemon
$ camelot recent -s 120
12:40:03  window  firefox: frame "Pull request #12 — Mozilla Firefox"
12:40:03  focus   firefox: entry "Leave a comment"
12:40:05  edit    firefox: entry "Leave a comment" ×41 over 12.3s last "looks right to me"
12:40:21  window  gnome-text-editor: frame "notes.md - Text Editor"
```

While the daemon runs, every other command (and every MCP tool call) is
answered by it, so caches stay warm; without it they run in-process as
before. `CAMELOT_LOCAL=1` bypasses it. Details in [docs/daemon.md](docs/daemon.md).

### Ignoring applications

`~/.config/camelot/config.yaml`:

```yaml
ignore:              # case-insensitive globs on the application name
  - keepassxc
  - "1Password*"
history: 2000        # most events the daemon keeps...
retention: 30m       # ...and for how long (s/m/h/d suffix, or seconds)
text: true           # record what was typed, not just that typing happened
accessibility: true  # daemon turns on toolkit accessibility at start (see Browsers)
log: false           # durable log: true ($XDG_STATE_HOME/camelot), or a directory
```

`camelot reload` makes a running daemon re-read the file. `camelot pause`
stops it recording anything (it keeps running and answering; `status` and
`recent` say so) until `camelot resume`. With `log:` on, every recorded
event is also appended to `events-YYYY-MM-DD.jsonl` in that directory
(mode 0600) — off by default, and `status` shows where it is logging.
These three are user controls: they are deliberately not MCP tools.

Ignored applications are reported as a redacted shell (role and name only)
by every command, and the daemon records nothing from them. `text: false`
keeps `recent` working (which widget, how many edits, over how long) but
drops the "last …" snippet of what was typed.

## The panel: `camelot-gtk`

A small GTK4/libadwaita window over the daemon. The front page is a
**switchboard** — what is being recorded, one switch per capability:

- **Background service** — start/stop the daemon (systemd user unit when
  installed, otherwise a child process).
- **Recording**: activity on/off (pause/resume), typed text, how long to
  keep history, the durable log.
- **Access**: browser accessibility; ignored applications (a page with a
  "choose a running application" picker).
- **Activity log** — a page with the `recent` digest as a live list,
  pushed by the daemon and updated row by row, never polled. It is there
  when you want it, not in your face.

Every change is written to the config file and the daemon reloads it in
place. It is a separate package (`camelot-gtk`) so a machine running only
the daemon needs no GTK, and it is single-instance: launching it again
raises the open window.

## MCP

`camelot mcp` serves the commands above as [Model Context Protocol](https://modelcontextprotocol.io)
tools over stdio. The tool definitions are generated from the same Jargon
schemas that drive the CLI, and each call is parsed by Jargon exactly as a
command line would be, so validation, defaults and output are identical.

Register it with Claude Code once (user scope, since it is about your
desktop rather than any one project):

```sh
claude mcp add --scope user camelot -- camelot mcp     # or: just mcp-add
```

Then in any session: *"look at what I'm looking at"* → the agent calls
`context`; *"what's in my editor?"* → `tree`; *"what was I just doing?"*
→ `recent` (with the daemon running); and so on. Tools default to
`text` output, which is the most token-efficient; pass `format: json` when
the caller wants structure.

The tools are the read-only commands plus `shot`, which answers with the
image itself (an MCP image block, not a file). What an agent is *not*
given: the daemon, the raw event stream, and your controls over being
recorded — `pause`, `resume` and `reload` are yours, not an agent's.

Any MCP client works the same way; the server speaks newline-delimited
JSON-RPC 2.0, protocol version 2025-06-18, tools only.

## What is never captured

Password fields (AT-SPI role `password text`) are reported with
`"redacted": true` and no `text` or `value`, regardless of `--max-text`,
and keystrokes into them never enter the event stream or the daemon's
history. Applications on the ignore list are redacted the same way.

**The daemon cannot reach the network.** Its systemd unit sets
`RestrictAddressFamilies=AF_UNIX`, so the kernel refuses to create an
internet socket for it at all: it talks to AT-SPI, D-Bus and its own socket,
nothing else. What it sees leaves your machine only through the MCP tools,
to an agent you chose, under the switchboard's settings.

**What the daemon holds.** Its history is in memory only: at most
`history` events, none older than `retention` (30 minutes by default),
readable only through a socket private to your user, gone when it stops.
It does include the text typed into ordinary fields — that is what makes
`recent` useful — unless `text: false`. Note that AT-SPI already
broadcasts these events to every process in your session; the daemon adds
short retention, not access.
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
