# The daemon

`camelot daemon` is a long-lived process that owns the accessibility bus
connection, records events, and answers commands over a Unix socket. It is
optional: every command in 0.1 still works without it. It exists for the
things a request/response process cannot do.

## Why

- **History.** A snapshot answers "what is on screen now". Only a process
  that was already running can answer "what has the user been doing" — the
  window switches, focus changes and edits of the last minute. That is
  `camelot recent`.
- **Bus presence.** Toolkits (browsers especially) build their accessibility
  tree when an assistive technology is around. A resident client is the
  toolkit-agnostic version of the gsettings switch.
- **Long-lived resources.** The next stages — a screen-capture session
  through the desktop portal, a global hotkey, an overlay — are all things
  you set up once and keep, not per call.

## Shape

```
                    ┌──────────────── camelot daemon ────────────────┐
  AT-SPI bus ──────▶│ Events::Pump ──▶ History (ring buffer, digest) │
                    │ A11y (warm object cache)                       │
  $XDG_RUNTIME_DIR/ │ UNIXServer ──▶ Commands.run(...)               │
   camelot.sock ◀──▶│                                                │
                    └────────────────────────────────────────────────┘
        ▲                       ▲
        │ Client.call           │ Client.call
  camelot <cmd>            camelot mcp  (tools/call)
```

One command runner, `Commands.run`, serves three callers: the CLI, the MCP
server, and the daemon's socket. Arguments arrive as JSON, are parsed by
Jargon exactly as a command line would be (validation and defaults
included), and dispatched to the same `CLI#cmd_*` methods. So there is one
implementation of every command, and the daemon cannot drift from the CLI.

**Forwarding.** When the socket is reachable, `camelot <cmd>` and MCP
`tools/call` send the parsed arguments to the daemon and print its reply.
When it isn't, they run the command in-process, exactly as before. Set
`CAMELOT_LOCAL=1` to bypass a running daemon. `recent` and `status` only
exist in the daemon; without one they say so.

**Protocol.** One JSON line each way:

```
→ {"command": "context", "arguments": {"max-text": 500}}
← {"ok": true, "output": "application: ..."}
← {"ok": false, "error": "no such application: x"}
```

`output` is the command's normal stdout in whatever `format` was asked for.
The socket is mode 0600 in `$XDG_RUNTIME_DIR`, so it is private to the user.

## Push: `subscribe`

A client that sends `{"command": "subscribe"}` keeps the connection and
receives JSON lines: first a backfill of retained events and the current
state, then `{"event": …}` for each recorded event and `{"state": …}` on
pause, resume and reload. Each subscriber has its own writer fiber and a
bounded queue; one that stops reading is dropped rather than allowed to
stall the daemon. The panel is built on this — it mirrors the stream into
its own `History` and never asks for `recent`.

## The pump must always breathe

`Events::Pump` drives GLib's context from a fiber, and every path through
its loop ends in something that lets other fibers run — a wait, or a real
(1 ms) sleep. Never `Fiber.yield`: while the pump stays runnable Crystal
has no reason to run its own event loop, so fibers waiting on timers or
sockets would not wake. Two rules follow from a daemon that spun a core
overnight:

- **Dispatch is bounded** (`MAX_DISPATCH`). "Iterate until nothing is
  ready" can be infinite: libatspi arms an idle source while it drains its
  own queue, so the context is ready again the instant it is dispatched.
- **Watchers are retired** when GLib stops polling an fd. A dead
  application's connection stays readable at EOF forever, and its watcher
  would wake the pump for eternity.

Plus a backoff: if GLib keeps saying a source is ready and dispatching it
produces no work, the loop slows to `IDLE_BACKOFF` instead of spinning.
`spec/events_spec.cr` holds the regression — an always-ready GLib source
must not stop a plain Crystal fiber from ticking.

## Events are resolved off the dispatch path

libatspi delivers events while it is waiting on a synchronous call, so an
event handler that itself makes calls nests D-Bus round trips inside a
dispatch inside a round trip — and an exception escaping the handler
unwinds through libatspi's C frames and wedges it. `Events::Queue`
therefore takes only the free parts of an event in the callback (type,
details, text payload, a ref to the source) and resolves app, role, name
and path from a fiber, with a bounded queue that drops under a flood. The
callback itself is fenced so nothing can escape it.

## History and the digest

The daemon subscribes to window activation, focus changes, text edits,
caret moves and document loads (`Events::DEFAULT_TYPES`) and keeps the last
`history` events (default 2000) for at most `retention` (default 30
minutes) in a ring buffer; whichever bound is hit first wins. With
`text: false`, edit events are recorded without their inserted text.

`recent` does not replay them. It produces a digest: focus-lost and
window-deactivate events are dropped as noise, and consecutive edits to the
same widget fold into one entry carrying a count, a time span and the last
inserted text — a terminal spinner's forty events a second become one line.
`--raw` returns the events as recorded.

Text typed into password fields is never recorded (`Events.capture`
redacts it at the source), and events from ignored applications are dropped
before they reach the buffer.

## Controls: pause, resume, reload

`pause` sets a flag the recorder checks first: nothing reaches the history
or the log until `resume`, while the daemon keeps answering snapshots.
`status` reports the paused-since time and text-mode `recent` leads with
it, so the state is never silent. `reload` re-reads the config file and
re-applies it — history bounds, ignore list, text switch, log sink,
accessibility — without a restart; a bad file is reported and the old
config kept. None of the three is exposed as an MCP tool: they are the
user's controls over being recorded, not an agent's.

## Durable log

Off by default. `log: true` (or a directory) appends every recorded event
as one JSON line to `events-YYYY-MM-DD.jsonl`, directory 0700 and files
0600. It sees exactly what the history sees: after the ignore list, after
the text switch, and nothing while paused. Reading it back into `recent`
is future work; today it is a write-only record the user owns. The
encoding is contained in `Daemon::Sink#write` and may move from JSON
lines to [C0DATA](https://github.com/c0data) (content-addressed,
streamable) once the read side exists.

## Screen capture is not part of the stream

`camelot shot` asks the XDG screenshot portal for one frame, scales and
flattens it (screens have an alpha channel; JPEG does not), hands over
~145 kB of JPEG and deletes the PNG the portal wrote. It is never
recorded: the history holds events, which are small and summarise well,
while frames would fill memory in minutes and summarise not at all. The
daemon is not involved — binary has no place in a line-based JSON
protocol, and the portal answers any process of ours equally well — so
`shot` is one of the commands that never forwards.

## The quiet path, when we need it

GNOME's screenshot portal announces every frame with a flash and a
shutter sound. That is good consent signalling for a one-off, and
obstructive for an agent taking many frames — in a meeting it is worse
than obstructive. There is no setting for it: the flash belongs to the
compositor's screenshot UI, and muting desktop sounds would not remove it.

The answer is the other portal. `org.freedesktop.portal.ScreenCast`
negotiates a session once — the user chooses what is shared — and the
desktop then shows a persistent "screen is being shared" indicator
instead of flashing per frame. Frames are pulled from a PipeWire stream
on demand: no flash, no sound, nothing written to ~/Pictures, and a
continuous signal the user can revoke from. That makes capture a
three-way choice rather than a toggle: **off**, **on demand** (a frame
now, flash and all) and **session** (approved once, quiet thereafter).

## Ignore list

`~/.config/camelot/config.yaml`:

```yaml
ignore:            # application names, case-insensitive globs
  - keepassxc
  - "1Password*"
history: 2000
```

An ignored application is redacted everywhere: snapshots return a shell
(role and name, `"redacted": true`, no text, children or actions), the
breadcrumb in `context` is blanked, and the daemon records nothing from it.
The check is in `A11y.snapshot` and the daemon's recorder, so every
command and every caller honours it. Config is read once per process;
`camelot reload` makes the daemon re-read it.

## Accessibility switch

At startup, unless `accessibility: false`, the daemon runs
`gsettings set org.gnome.desktop.interface toolkit-accessibility true` if
the key is off, and logs that it did. Browsers and some toolkits only build
their accessibility tree when that was on at their startup, so a daemon
started at login (the user unit) makes them all readable. It is a one-way
switch: the daemon never turns it off, because a screen reader may depend
on it. On desktops without that schema, nothing happens.

## Concurrency

The daemon is single-threaded. `Events::Pump` runs GLib's main context from
a fiber (see the README); the socket accept loop and per-client handlers
are fibers too. A handler's AT-SPI calls are synchronous D-Bus round trips,
during which libatspi services its own connection; events that arrive
meanwhile are queued and dispatched on the pump's next turn. Nothing shares
state across threads.

## Running it

```sh
camelot daemon                        # foreground, logs to stderr
systemctl --user enable --now camelot # the packaged user unit
camelot status
camelot recent -s 300 -n 20
```

SIGTERM/SIGINT stop the pump, deregister the listeners and remove the
socket. A stale socket from an unclean exit is replaced on the next start;
a live one is refused.
