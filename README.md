# omajam

An [MPD](https://musicpd.org) client for the [Omarchy](https://omarchy.org)
Quattro bar. What's playing in the bar, and behind it a window with the queue,
your library, your playlists and a search box — laid out like
[rmpc](https://github.com/mierak/rmpc) and driven by the same keys.

> **Written by Claude**, Anthropic's coding agent. Omarchy plugins run
> unsandboxed inside your shell process, with your permissions. Read the source
> first. No promises about your record collection.

## Features

- **A window, not a menu** — queue, directories, artists, album artists,
  albums, genre, playlists and search, each a tab, with the cover and the
  progress bar always on screen.
- **rmpc's keys** — `j`/`k`, `gg`/`G`, `/`, `a`, `d`, `Space`, `Tab`, `p`,
  `z`/`x`/`c`/`v`. `?` lists the lot.
- **A ranger-style browser** — where you came from, where you are, and what is
  behind the cursor, three columns at a time. The third column is fetched
  before you ask for it, so going in is instant.
- **A label you write** — `[%artist% - ]%title%` in mpc's dialect, brackets and
  all, with a live preview in the settings tab.
- **Push, not poll** — MPD's own `idle` drives the widget, so it changes when
  the music does and costs nothing when it doesn't.
- **TCP or unix socket**, with a password, or whatever `$MPD_HOST` already says.
- **Reconnects on its own** when MPD restarts, and says why while it can't.
- **CLI and keybinds** through `omarchy-shell mpd …`.

It follows your Omarchy theme, font and spacing: the colours are the shell's
popup and menu tokens, so a theme change moves the whole window with it.

Only python3 is needed, which Arch already has. There is no `mpc` dependency
and no libmpdclient: the plugin speaks the MPD protocol itself.

## Install

```bash
omarchy plugin add https://github.com/matjam/omajam.git --enable
```

Put the widget wherever you like when prompted — `left`, `center` or `right`.
The window opens centred on the bar whichever you choose. Move it later from
the bar's own settings, or by editing `bar.layout` in
`~/.config/omarchy/shell.json`.

```bash
omarchy plugin update matjam.omajam    # update
omarchy plugin remove matjam.omajam    # remove, leaves nothing behind
```

Omarchy's built-in `omarchy.media` widget is MPRIS-based and knows nothing
about MPD unless something bridges the two. The two can coexist; this one is
about the server.

## The window

Click the label in the bar, or `omarchy-shell matjam.omajam client`.

| Tab | | |
| --- | --- | --- |
| `1` | Queue | What is playing, in order. The cover is beside it. |
| `2` | Directories | Your music tree, as it is on disk. |
| `3` | Artists | Artist → album → track. |
| `4` | Album Artists | The same, by album artist, which is what a compilation wants. |
| `5` | Albums | Every album, then its tracks. |
| `6` | Genre | Genre → album → track. |
| `7` | Playlists | Stored playlists, and what is in them. |
| `8` | Search | Every tag at once, as you type. |
| `9` | Settings | This plugin's, and the server's. |

### Keys

Every one of these is what rmpc binds it to by default.

| | | | |
| --- | --- | --- | --- |
| `j` `k` | move | `p` | play / pause |
| `g g` | top | `s` | stop |
| `G` | bottom | `<` `>` | previous / next |
| `^u` `^d` | half a page | `f` `b` | seek ±5s |
| `^b` `^f` | a page | `.` `,` | volume ±5 |
| `h` `l` | out of / into | `z` | repeat |
| `enter` | play it | `x` | random |
| `a` `A` | add / add all | `c` | consume |
| `d` `D` | delete / clear the queue | `v` | single |
| `space` | mark a row | `u` `U` | update / rescan the database |
| `/` `n` `N` | find, again, back | `tab` `1`–`9` | switch tab |
| `J` `K` | move a song in the queue | `C` | jump to what is playing |
| `X` | shuffle the queue | `i` | the search box |
| `?` | the key list | `q` `esc` | close |

Switching to Search puts the cursor in the box, so keys type rather than
command until `esc` hands the keyboard back to the results. `tab` still walks
the tabs from inside the box, being the one key a single-line field has no use
for.

`a` acts on every marked row, or on the row under the cursor when nothing is
marked. Adding an artist or an album sends the server a filter rather than nine
hundred `add` lines, so a discography lands in one round trip.

The mouse works too: click a row to select it, double-click to play it, click
the progress bar to seek, click the option glyphs in the header to toggle them.
The wheel moves ten rows a notch, the scrollbar can be grabbed and dragged,
and a click on its track jumps there. Dragging the list itself pans it, which
is Quickshell's own behaviour and is left alone.

## In the bar

| | |
| --- | --- |
| Left click the label | Open the window |
| Middle click | Next track |
| Right click | Open the window on its settings tab |
| Scroll | Volume, seek or skip, whichever you chose |
| Hover | Cover art, album, and how far through you are |

The transport buttons beside the label play, pause and skip without opening
anything. The cog opens the settings tab.

## Settings

Tab `9` of the window, or the cog in the bar.

**Server** — host, port, password, and what the connection is doing, including
the server's own error message when it refuses. **Reconnect** restarts the
connection. **Update database** reads the files whose timestamps changed, which
is what you want after adding a record; **Rescan everything** re-reads every
file in the library, which is what you want after editing tags in place, and
takes as long as that sounds. `u` and `U` do the same two things from anywhere
in the window, and MPD reports only that a scan is running, never how far
through it is.

`$MPD_HOST` is read in full, including its `password@host` spelling, but only
while the host field is empty — a host typed into the panel is a decision, and
a shell profile should not quietly override it.

**Label format** — see [Format](#format), with a live preview.

**In the bar** — label width, scroll or elide, which parts of the strip to
show, what to do when nothing is playing, and what the scroll wheel does.

**Playback** — repeat, random, single, consume and volume. These are the
*server's* settings: every MPD client sees them change.

## Format

The label format is mpc's, so one copied out of a status-bar script mostly
works unchanged.

| | |
| --- | --- |
| `%tag%` | Substituted, empty when the tag is missing. |
| `[ … ]` | Dropped entirely unless every `%tag%` inside it resolved. |
| `[ a \| b ]` | Alternatives. The first branch that resolves wins. |
| `%%`, `\x` | A literal percent, a literal `x`. |

The brackets are the point. `[%artist% - ]%title%` loses the dash along with
the artist rather than leaving a title that starts with one, and
`[%title%|%filename%]` falls back to the filename for a track that was never
tagged.

Outside brackets a missing tag just leaves a hole, and `|` is an ordinary
character — `%artist% | %title%` is a separator, not an alternation.

Tags: `artist` `albumartist` `title` `album` `track` `disc` `date` `genre`
`composer` `performer` `comment` `name` `file` `filename` `folder` `state`
`stateicon` `elapsed` `duration` `remaining` `time` `position` `length`
`volume` `bitrate` `audio` `repeat` `random` `single` `consume`

`name` is a radio stream's name, which is the only title many of them carry.
`filename` is the basename without its extension; `folder` is the directory
inside your music library.

Some to steal:

```
%stateicon% [%artist% - ]%title%          ▶ Wire - Another the Letter
[%artist% — ]%title%[ (%date%)]           Wire — Another the Letter (1978)
[%title%|%filename%][  ·  %time%]         Another the Letter  ·  0:41/4:14
[%name%|%artist% - %title%|%filename%]    radio first, then tags, then the file
%title%[  ·  %position%/%length%]         Another the Letter  ·  3/17
```

Anything with `%elapsed%`, `%remaining%` or `%time%` in it moves once a second.
MPD only reports elapsed when something changes, so the clock is carried
forward locally between updates and reset by every one of them.

## From the command line

```bash
omarchy-shell -q mpd toggle          # play/pause
omarchy-shell -q mpd next            # and previous, stop, play, pause
omarchy-shell -q mpd volume +5       # a sign nudges, a bare number sets
omarchy-shell -q mpd seek 90         # absolute, in seconds
omarchy-shell -q mpd option random   # repeat, random, single, consume
omarchy-shell -q mpd clear           # and shuffle, crop
omarchy-shell -q mpd add "Wire/Pink Flag"
omarchy-shell -q mpd load "Friday"   # a stored playlist
omarchy-shell -q mpd update          # read the files that changed
omarchy-shell -q mpd rescan          # re-read every file in the library
omarchy-shell mpd status             # JSON state
omarchy-shell mpd queue              # JSON queue
omarchy-shell matjam.omajam client   # the window
omarchy-shell matjam.omajam settings # the window, on its settings tab
omarchy-shell matjam.omajam search "kate bush"
omarchy-shell matjam.omajam key a    # any key the window takes, from a script
omarchy-shell matjam.omajam key esc  # and the ones with no text: esc enter tab
                                     # up down left right space pgup pgdn home end
omarchy-shell matjam.omajam state    # what the window is showing, as JSON
```

```conf
# hyprland binds
bindl = , XF86AudioPlay, exec, omarchy-shell -q mpd toggle
bindl = , XF86AudioNext, exec, omarchy-shell -q mpd next
bindl = , XF86AudioPrev, exec, omarchy-shell -q mpd previous
bind = SUPER, M, exec, omarchy-shell matjam.omajam client
bind = SUPER SHIFT, M, exec, omarchy-shell matjam.omajam settings
```

## How it works

Quickshell's `Socket` is a `QLocalSocket` — unix sockets only — and MPD is
usually somewhere on TCP, so the connection lives in a small python child
process, [`bin/omajam-mpd`](bin/omajam-mpd). The shell and the bridge speak one
line of JSON at a time: settings, commands and queries go down; state and
answers come back.

The bridge holds three connections, which is what the protocol asks for. One
sits in `idle` waiting for the server to say something changed. One takes
commands and reads status. The third answers the window's browsing queries,
because `search` across ten thousand songs takes long enough to be felt and it
must not be felt on the play button. Album art gets a fourth, short-lived one,
so a 3MB cover cannot delay a play/pause.

Queries carry a channel, and a query superseded by a newer one on the same
channel is dropped rather than run — which is what makes typing into the search
box cost one query rather than one per keystroke.

The connection is held by the plugin's *service*, one per shell rather than one
per monitor: the bar widget is instantiated on every screen, and three of them
would open three connections and race each other. Each widget reads the one
service back through `shell.serviceFor()`.

Covers are cached under `~/.cache/omajam`, keyed by album rather than by track
so a whole record costs one fetch, and pruned to the most recent 96.

<details>
<summary><b>Album art, in detail</b></summary>

MPD has two commands for it. `albumart` returns the cover file sitting beside
the song, `readpicture` whatever is embedded in the tags. This tries the first
and falls back to the second, so a library that keeps `cover.jpg` files and one
that tags its artwork both work, and a track with neither degrades to a
placeholder rather than an error.

Both hand the image back in chunks of `binarylimit` bytes, 8KB by default. The
bridge raises that to 256KB on its art connection, which turns a 3MB cover from
400 round trips into 12. Servers older than 0.22 don't know the command, reject
it, and keep their default.

</details>

<details>
<summary><b>Old servers</b></summary>

MPD 0.21 introduced the filter expression — `find "((artist == 'Wire'))"` — and
has spent every release since deprecating the tag/value spelling that came
before it. The bridge writes whichever the server it is pointed at understands,
because a plugin has no say in which MPD that is and 0.20 is still what a NAS
ships.

</details>

## Requirements

Omarchy Quattro · python3 (already installed on Arch) · an MPD server
somewhere, which can be another machine.

No network access beyond the MPD connection you configure, nothing written
outside `~/.cache/omajam`, and no dependency on `mpc` or libmpdclient.

**Your password is stored as plain text** in `~/.config/omarchy/shell.json`,
the same as every other shell setting, and is sent to MPD the way the protocol
sends it — in the clear, unless you tunnel it. Leave the field empty and use
`$MPD_HOST=password@host` if you would rather it lived in your environment.
The bridge is told its settings over stdin rather than argv, so the password is
at least not visible in `ps`.

MIT — see [LICENSE](LICENSE).
