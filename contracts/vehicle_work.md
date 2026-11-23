# Vehicle work (C6)

Working on a vehicle by hand: install, repair, mend, remove, refill. CDDA's own vehicle screen (`veh_interact`)
is a curses loop the client can't answer, so the client shows its own view and asks the sim two things: what can
be done (this read), and to do it (the `vehicle_work` action, not built yet). CDDA decides both: the checks,
texts and times come from `veh_interact`'s own code, run off-screen.

Status: the **read is frozen as written here** (2026-11-22). The action and the install list are planned and not
frozen; see the end.

## The read

`CddaSim.query_vehicle_work(d)` → `int`: a query id (≥ 1), or 0 when refused. The result comes through
`take_query_result(id)` like the other queries (`bridge_api.md`: answered at the main loop's next request, also
while paused; read-only; never a prompt; ≤ 64 KB).

`d` (Dictionary):

| Key | Type | |
|---|---|---|
| `vehicle` | int, required | The snapshot's `vehicles[].uid` (1..2^53−1). |
| `part` | int, optional | A row of that vehicle's `parts` in the snapshot (0..4095): the part the player has selected. Left out or -1: no part, the result has no `selected`. |

Refused (0, nothing queued): a missing `vehicle`, a wrong type, anything out of range, a vehicle-work query still
pending (one at a time), 8 queries pending already, no game running.

When to ask: when the work view opens, when the selection changes, and when the snapshot shows the vehicle or
what the player carries has changed. Not every frame: each one makes CDDA go through every part type for the
selected square, as its own screen does on a cursor move.

### Result

```json
{
  "id": 7, "ok": true, "kind": "vehicle_work",
  "vehicle": 123, "name": "Car", "turn": 5224405,
  "parts": [
    {"row": 0, "mount": [0, 0], "vpart": 412, "name": "frame", "variant": "cross",
     "hp": 100, "damage": 0, "flags": 0},
    {"row": 9, "mount": [1, -1], "vpart": 630, "name": "wheel (faulty)", "variant": "",
     "hp": 31, "damage": 3, "flags": 6, "faults": ["Flat tire"]}
  ],
  "parts_more": 0,
  "selected": {
    "row": 9, "here": [8, 9],
    "commands": [
      {"cmd": "r", "ok": false, "reason": 0, "text": "", "time_s": 1800, "lines": [
        {"text": "Time required:", "met": 0},
        {"text": "> 30 minutes", "met": 0},
        {"text": "Skills required:", "met": 0},
        {"text": "> mechanics 1", "met": 1},
        {"text": "Tools required:", "met": 0},
        {"text": "> 1 tool with wrenching quality of 1 or more", "met": 2}
      ]},
      {"cmd": "o", "ok": true, "reason": 0, "text": "", "time_s": 600, "lines": []},
      {"cmd": "m", "ok": true, "reason": 0, "text": "", "time_s": 0, "lines": []},
      {"cmd": "f", "ok": false, "reason": 1, "text": "", "time_s": 0, "lines": []}
    ]
  },
  "truncated": false
}
```

Top level:

| Field | |
|---|---|
| `id`, `ok`, `kind` | The query id, `true`, `"vehicle_work"`. |
| `vehicle`, `name` | The uid asked for; the vehicle's name as the snapshot gives it (≤ 60 columns). |
| `turn` | The game turn the answer was worked out at. |
| `parts` | The vehicle's own parts, in the order and with the row numbers of the snapshot's `vehicles[].parts` (CDDA's gap fillers, the rows with state bit 3, are not listed: they aren't parts to work on). At most 512; `parts_more` counts the ones left out. |
| `selected` | Only with `part`: see below. |
| `truncated` | `true` when part entries were dropped from the end to keep the result under 64 KB (`parts_more` counts them too). |

A part:

| Field | |
|---|---|
| `row` | Its row in the snapshot's `vehicles[].parts`: the number to send as `part`. |
| `mount` | `[x, y]`, its mount on the vehicle, as in the snapshot row. |
| `vpart` | Its part type, the `vpart` id-table index, as in the snapshot row (name, location and flags such as `NEEDS_JACKING` are in the id table). |
| `name` | CDDA's name for this part without the condition marks, e.g. `"wheel (faulty)"` (≤ 60 columns). |
| `variant` | Its shape, CDDA's variant id (`""` none; ≤ 64 bytes of printable ASCII, else `""`). |
| `hp` | 0..100: its health in percent, cut to a whole number. |
| `damage` | CDDA's damage level of the part's item (0 undamaged; higher is worse). |
| `flags` | Bits: 1 broken, 2 can be repaired (damaged, not broken), 4 has faults, 8 can be refilled (a tank or fuel store with room), 16 carried on a rack. |
| `faults` | Only when it has any: the faults' names (at most 8, each ≤ 60 columns). |

`selected`:

| Field | |
|---|---|
| `row` | The part asked about. |
| `here` | The rows of every part on its square, the selected one included, in CDDA's order for that square (at most 32). |
| `commands` | One entry each for `r` (repair; replaces a broken part), `o` (remove), `m` (mend a fault) and `f` (refill), in that order. Install is not per part and is not listed. |

A command:

| Field | |
|---|---|
| `cmd` | `"r"`, `"o"`, `"m"` or `"f"`: CDDA's own keys. |
| `ok` | The work can start now on this part. |
| `reason` | CDDA's `task_reason` for the command: 0 can be done, 1 no valid target, 2 lacks tools, 3 not free (something is attached to it), 4 lacks skill, 5 the vehicle is moving or being driven, 6 morale too low, 7 too dark. CDDA checks tools and skills in the lines, not here: `ok` false with `reason` 0 means a line is not met. |
| `text` | CDDA's one sentence when it refuses outright, e.g. "It's too dark to see what you are doing…", "This part cannot be uninstalled."; `""` when it has none (≤ 200 columns). For `m` and `f`, `reason` 1 with `""` means this part has nothing to mend or refill. |
| `time_s` | How long the work takes, in seconds of game time (0 for `m` and `f`: mending takes the time of the fix chosen in its menu, refilling is done at once). |
| `lines` | CDDA's requirement text for the command on this part, one entry a line (at most 64, each ≤ 200 columns): time, skills, components, tools, lifting or jacking, what removing yields, then the part type's description. `met`: 0 a heading or a note, 1 a requirement that is met, 2 one that is not (from the colour CDDA gives the line). |

All text is game data: color tags, line breaks and control characters removed.

### Errors

`{"id": 7, "ok": false, "kind": "vehicle_work", "error": "..."}` with `error` one of:

| `error` | |
|---|---|
| `no such vehicle` | No vehicle with that uid in the reality bubble. |
| `too far` | No part of it is on the player's square or one next to it on the player's level (CDDA's rule for examining a vehicle). |
| `no such part` | `part` is not one of its part rows (out of range, or a gap filler). |
| `internal`, `too large` | As for the other queries. |

## Planned, not frozen

- **Install**: the read gets an `install` section for a square of the vehicle: the part types CDDA would list
  there (`can_mount`), which of them the player could install now, and the requirement lines for one of them.
- **The `vehicle_work` action** `{vehicle, part, cmd, ...}`: the sim runs the same check again and, when it
  passes, starts CDDA's own activity. CDDA's questions come as the requests of `ui_requests.md`: a `popup` for
  its yes/no warnings, `item_select` for what to refill from, `menu` for a new part's shape, for which component
  or tool to use and for the mend choice, and `popup` + `target` (look) for the facing of a new light. Several
  of these come when the work finishes, not when the action is sent.
