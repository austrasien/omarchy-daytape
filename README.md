# Day tape

A HUD-style tape along the left edge of the Omarchy shell: today's hours to
scale, with the events as blocks from their start to their end, and finished
ones as empty outlines.

- **At rest** only a thin rail shows, as wide as the gap beside your windows.
- **Hover** the rail and the hours deploy in a wave from the pointer.
- **Hover a block** and a target-lock card opens with its details. It stays
  while the pointer is on the rail, the strip or the card.
- **Click a block** to open its call (Teams, Meet or any web link).
- **Click a line of the card** to copy it; it blinks to confirm. Meeting
  secrets are masked on the card; the `LINK` line copies the real link.
- From five minutes before its start, a block **grows and blinks** in a target
  frame, with a tag sweeping up and down its height (`T-05`, then seconds in
  the last minute). Simultaneous events get a column and a tag each.
- If you have not joined, the warning goes on for ten minutes after the start
  (`T+03`). It ends when a call starts (an app captures the microphone or the
  screen) or when you click the block or its tag. Clicking joins the call.
- During a warning the tape shows above fullscreen windows, and on the other
  screens too.
- **After a sleep**, an event that started meanwhile and is still running warns
  for ten minutes from the wake; those already over are listed in a
  notification.
- **`NO DATA`** shows at the top when the calendars have not been fetched for
  a while.

Colours follow the theme's accent. Animations stop with
`omarchy toggle animations`, but keep running during a call: the optional
call-mode plugin (`austraz.callmode`) holds animations off too, and the tape
only animates during a hover or a warning.

## Requirements

- [omarchy-next-event](https://github.com/austrasien/omarchy-next-event) 1.10 or
  later: the bar widget that fetches the calendars. The tape reads the `today` list it
  publishes in `$XDG_RUNTIME_DIR/next-event-upcoming.json`.
- `wl-copy` (wl-clipboard), for copying, and `notify-send`, for missed events.

## Install

```sh
omarchy plugin add https://github.com/austrasien/omarchy-daytape.git --enable
```

## Settings

`~/.config/omarchy/daytape.json`, all optional:

```json
{
  "dayStart": 6,
  "dayEnd": 24,
  "calendars": ["Work"],
  "hatched": ["Perso"],
  "monitor": "eDP-1",
  "railWidth": 12,
  "visible": true
}
```

| Key | Meaning |
| --- | --- |
| `dayStart`, `dayEnd` | Hours at the top and bottom of the tape; widened for events outside them. |
| `calendars` | NextEvent feed labels to show. Empty or absent: all of them. |
| `hatched` | Feed labels drawn hatched instead of solid. |
| `monitor` | Screen to stay on. Absent: the focused one. |
| `railWidth` | Width at rest, in pixels. Absent: the gap beside windows. |
| `visible` | Show the tape. |

## Commands

```sh
omarchy-shell austraz.daytape toggle    # show or hide
omarchy-shell austraz.daytape peek 0    # open the card of block 0; -1 closes
omarchy-shell austraz.daytape slept 20  # act as if back from a 20-minute sleep
omarchy-shell austraz.daytape state     # what the tape holds, as JSON
```

## Tests

```sh
node --test test/*.test.js
```

## License

MIT
