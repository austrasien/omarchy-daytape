# Day tape

A HUD-style tape along the left edge of the Omarchy shell: today's hours to
scale, with the coming events as blocks from their start to their end.

- **At rest** only a thin rail shows, as wide as the gap beside your windows.
- **Hover** the rail and the hours deploy in a wave from the pointer.
- **Hover a block** and a target-lock card opens with its details. It stays
  while the pointer is on the rail, the strip or the card.
- **Click a block** to open its call (Teams, Meet or any web link).
- **Click a line of the card** to copy it; it blinks to confirm. Meeting
  secrets are masked on the card; the `LINK` line copies the real link.
- A block **blinks** from five minutes before its start.

Colours follow the theme's accent. Animations stop with
`omarchy toggle animations`, but keep running during a call: the optional
call-mode plugin (`austraz.callmode`) holds animations off too, and the tape
only animates during a hover.

## Requirements

- [omarchy-next-event](https://github.com/austrasien/omarchy-next-event) 1.8 or
  later: the bar widget that fetches the calendars. The tape reads the `today` list it
  publishes in `$XDG_RUNTIME_DIR/next-event-upcoming.json`.
- `wl-copy` (wl-clipboard), for copying.

## Install

Clone this repository to `~/.config/omarchy/plugins/austraz.daytape`, then add
it to the `plugins` list of `~/.config/omarchy/shell.json`:

```json
{ "id": "austraz.daytape" }
```

## Settings

`~/.config/omarchy/daytape.json`, all optional:

```json
{
  "dayStart": 6,
  "dayEnd": 24,
  "calendars": ["Work"],
  "monitor": "eDP-1",
  "railWidth": 12,
  "visible": true
}
```

| Key | Meaning |
| --- | --- |
| `dayStart`, `dayEnd` | Hours at the top and bottom of the tape; widened for events outside them. |
| `calendars` | NextEvent feed labels to show. Empty or absent: all of them. |
| `monitor` | Screen to stay on. Absent: the focused one. |
| `railWidth` | Width at rest, in pixels. Absent: the gap beside windows. |
| `visible` | Show the tape. |

## Commands

```sh
omarchy-shell austraz.daytape toggle    # show or hide
omarchy-shell austraz.daytape peek 0    # open the card of block 0; -1 closes
omarchy-shell austraz.daytape state     # what the tape holds, as JSON
```

## Tests

```sh
node --test test/*.test.js
```

## License

MIT
