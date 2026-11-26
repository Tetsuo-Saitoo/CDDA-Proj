# The map (G5)

CDDA's map screen is a curses loop the client can't answer, so the client draws its own map and asks the sim what
the player knows of the overmap. Slice 1 is the read on this page. Notes, routes and travel (`queue_overmap`,
the `map_result` event) are planned in `docs/MAP.md` and not built.

Status (2026-11-26): the read is built and frozen as written here.

## The read

`CddaSim.query_overmap(d)` → `int`: a query id (≥ 1), or 0 when refused. The answer comes through
`take_query_result(id)` like the other queries (`bridge_api.md`: answered at the main loop's next request, also
while paused; read-only; never a prompt; ≤ 64 KB).

`d` (Dictionary):

| Key | Type | |
|---|---|---|
| `origin` | Array, required | `[x, y, z]`, three ints: the page's north-west cell in absolute overmap terrains (OMT). `x` and `y` are multiples of 32, each within ±16777216; `z` is the level, −10..10. |
| `path` | bool, optional | `true`: the answer also carries the player's travel path. |

Refused (0, nothing queued): a missing or malformed `origin`, an origin off the 32-cell grid or out of range, a
`path` that isn't a bool, an overmap query still pending (one at a time), 8 queries pending already, no game
running.

A page is 32 × 32 cells on one level. Ask for the pages on screen one at a time and take each answer before
posting the next: the sim keeps at most 4 untaken overmap answers. The player's cell comes from the snapshot.

**The read never creates ground.** It looks only at overmaps that exist already. Ground nobody has been near has
no overmap yet: a page over it answers `ok` with every cell unseen, and no overmap is made for it.

### Answer

```json
{
  "id": 9, "ok": true, "kind": "overmap",
  "origin": [96, -64, 0], "turn": 5400,
  "looks": [{"name": "", "sym": "", "color": ""}, {"name": "forest", "sym": "F", "color": "c_green"}],
  "look": [1, 1, 0], "vision": [4, 1, 0], "flags": [0, 1, 0],
  "notes": [{"at": [100, -60], "sym": "!", "color": "c_red", "text": "bandits", "danger": true, "radius": 3}],
  "notes_more": 0,
  "path": {"to": [100, -70, 0], "cells": [97, -64, 0, 98, -65, 0], "more": 0},
  "truncated": false
}
```

(`look`, `vision` and `flags` have 1024 entries each; the example is cut short.)

| Field | |
|---|---|
| `origin` | The page asked for. |
| `turn` | The game turn the page was read at. |
| `looks` | What is drawn on this page, at most 256 entries. A look is what CDDA's own map screen draws for a cell at the vision level the player has of it: `name` (plain text, ≤ 60 columns), `sym` (CDDA's map symbol, a short UTF-8 string; roads and the like are box-drawing characters) and `color` (a CDDA colour name, `c_green`). Look 0 is always the unseen cell, three empty strings. Two cells share a look when CDDA draws them the same, so cells of different real kinds that look alike from afar can't be told apart; the terrain's id is not sent at any vision level. |
| `look` | 1024 ints, a cell's index into `looks`. Cell index = `(y − origin.y) * 32 + (x − origin.x)`: row by row from the north-west. |
| `vision` | 1024 ints, CDDA's `om_vision_level` for the cell: 0 unseen, 1 vague, 2 outlines, 3 details, 4 full. |
| `flags` | 1024 ints, bits: 1 the player's explored mark, 2 a vehicle the player tracks, 4 a camp, 8 the active mission's target. More bits may be added: ignore unknown ones. |
| `notes` | The notes on cells of this page, at most 256, in cell order: `at` `[x, y]`; `sym` (one character) and `color` as CDDA parses them from the note's own prefix (CDDA's `get_note_display_info`); `text`, the note without that prefix (plain text, ≤ 450 columns); `danger` and `radius`, CDDA's danger mark and its radius in cells (0 when not dangerous). Notes CDDA writes itself for map extras are notes like any other. |
| `notes_more` | Notes left out: beyond 256, or to stay within the byte limit. |
| `path` | Only with `path: true` and only while the player has a destination: `to` `[x, y, z]`, the destination; `cells`, a flat list of three ints a cell from the player's end toward the destination, at most 2048 cells; `more`, cells left out at the far end. |
| `truncated` | Something was left out: looks beyond 256 (those cells have look 0 with their real `vision`), notes, or path cells. |

All text is game data, and a note's text is written by players (saves can come from other people): colour tags,
line breaks and control characters are removed and lengths capped by columns and bytes. Show it as plain text.

Over the 64 KB limit the path's far cells go first, then notes from the end.

Not sent: anything CDDA's map screen hides. Cells not seen have no look; hordes and other characters are not
part of this read.

### Errors

`{"id": 9, "ok": false, "kind": "overmap", "error": "..."}` with `error` `internal` or `too large`, as for the
other queries.
