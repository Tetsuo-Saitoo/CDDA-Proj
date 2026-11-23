# Vehicle work (C6)

Working on a vehicle by hand: install, repair, mend, remove, refill. CDDA's own vehicle screen (`veh_interact`)
is a curses loop the client can't answer, so the client shows its own view and asks the sim two things: what can
be done (the read), and to do it (the action). CDDA decides both: the checks, texts and times come from
`veh_interact`'s own code, run off-screen.

Status (2026-11-22): the **read** is built and frozen as written here. The **action** is built for repair and
remove. Install, mend and refill are planned and not frozen; see the end.

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
selected square, as its own screen does on a cursor move (measured for a car with a part selected: about 20 ms
on the game thread in the Windows build, 4 ms on Linux).

### Result

```json
{
  "id": 7, "ok": true, "kind": "vehicle_work",
  "vehicle": 123, "name": "Car", "turn": 5224405, "owned": true,
  "parts": [
    {"row": 0, "mount": [0, 0], "vpart": 412, "name": "frame", "variant": "cross",
     "hp": 100, "damage": 0, "flags": 0},
    {"row": 41, "mount": [-2, 1], "vpart": 630, "name": "wheel (faulty)", "variant": "",
     "hp": 100, "damage": 0, "flags": 4, "faults": ["Flat tire"]},
    {"row": 79, "mount": [1, 1], "vpart": 977, "name": "glovebox", "variant": "",
     "hp": 50, "damage": 3, "flags": 2}
  ],
  "parts_more": 0,
  "selected": {
    "row": 79, "here": [12, 13, 79],
    "commands": [
      {"cmd": "r", "ok": false, "reason": 0, "text": "", "time_s": 600, "lines": [
        {"text": "Time required:", "met": 0},
        {"text": "> about 10 minutes", "met": 0},
        {"text": "Skills required:", "met": 0},
        {"text": "> mechanics 1", "met": 1},
        {"text": "Components required:", "met": 0},
        {"text": "> 2 bone glues OR 20 superglue OR 50 duct tape", "met": 2},
        {"text": "Tools required:", "met": 0},
        {"text": "> NONE", "met": 1},
        {"text": "Description", "met": 0},
        {"text": "> A small lidded compartment in the dashboard.  Holds a few litres.", "met": 0}
      ]},
      {"cmd": "o", "ok": true, "reason": 0, "text": "", "time_s": 210, "lines": [
        {"text": "Removing the |. glovebox will yield:", "met": 0},
        {"text": "> |. glovebox", "met": 0},
        {"text": "Time required:", "met": 0},
        {"text": "> about 3 minutes", "met": 0},
        {"text": "Skills required:", "met": 0},
        {"text": "> mechanics 1", "met": 1},
        {"text": "Tools required:", "met": 0},
        {"text": "> 1 tool with screw driving of 1 or more.", "met": 1},
        {"text": "Additional requirements:", "met": 0},
        {"text": "> 1 tool with lifting 1 OR strength 1", "met": 1},
        {"text": "Description", "met": 0},
        {"text": "> A small lidded compartment in the dashboard.  Holds a few litres.", "met": 0}
      ]},
      {"cmd": "m", "ok": false, "reason": 1, "text": "", "time_s": 0, "lines": []},
      {"cmd": "f", "ok": false, "reason": 1, "text": "No parts can currently be refilled.", "time_s": 0, "lines": []}
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
| `owned` | `true` when the vehicle is the player's or nobody's. `false`: it belongs to someone else, and CDDA asks before any work on it (see the action); owners who see the work take it as theft. |
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
| `fill` | Only for a tank, a battery or another fuel store (a reactor, a coal bunker; not a turret's ammunition): `{"what", "now", "max", "unit"}`, as CDDA's vehicle overview shows them. `what`: the name of what is in it, `""` when empty (≤ 60 columns). `unit` `"ml"` for a tank (`now` the volume in it, `max` what it holds), `"charges"` for the others (CDDA's charge counts). `max` is 0 when CDDA can't tell (an empty fuel store that takes several kinds). Added 2026-11-22; older results lack it. |

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
| `text` | CDDA's one sentence when it refuses outright, e.g. "It's too dark to see what you are doing…", "This part cannot be uninstalled."; `""` when it has none (≤ 200 columns). `reason` 1 with `""` means this part itself has nothing to repair, mend or refill, whatever other parts of the vehicle have. |
| `time_s` | How long the work takes, in seconds of game time (0 for `m` and `f`: mending takes the time of the fix chosen in its menu, refilling is done at once). |
| `lines` | CDDA's requirement text for the command on this part, one entry a line (at most 64, each ≤ 200 columns): time, skills, components, tools, lifting or jacking, what removing yields, then the part type's description. `met`: 0 a heading or a note, 1 a requirement that is met, 2 one that is not (from the colour CDDA gives the line under its requirement headings; also 2 for a red sentence of CDDA's that rules the work out, such as "This part cannot be repaired."). A part's or item's name in a line may start with CDDA's condition marks, e.g. `|.`. |

All text is game data: color tags, line breaks and control characters removed.

### Errors

`{"id": 7, "ok": false, "kind": "vehicle_work", "vehicle": 123, "error": "..."}`: `vehicle` is the uid the
query named (added 2026-11-22; left out for `internal` and `too large` answers of older bridges). `error` is one
of:

| `error` | |
|---|---|
| `no such vehicle` | No vehicle with that uid in the reality bubble. |
| `an appliance` | It is an appliance (a fridge, a lamp, a wall wire): CDDA has another screen for those, and this read and the action don't cover them. |
| `too far` | No part of it is on the player's square or one next to it on the player's level (CDDA's rule for examining a vehicle). |
| `no such part` | `part` is not one of its part rows (out of range, or a gap filler). |
| `internal`, `too large` | As for the other queries. |

## The action: repair and remove

`CddaSim.queue_vehicle_work(d)` → `bool`: queued, or `false` when refused before queueing. It shares the action
queue with the other queued actions (`ui_requests.md`) and runs at the main loop like them.

| Key | Type | |
|---|---|---|
| `vehicle` | int, required | The snapshot's `vehicles[].uid`. |
| `part` | int, required | A row of that vehicle's `parts` (0..4095), as the read's `row`. |
| `vpart` | int, required | That part's type as the read (or the snapshot row) gave it: the `vpart` id-table index (1..2^20). |
| `mount` | Array, required | That part's mount as the read gave it: `[x, y]`, two ints (each −1023..1023). |
| `cmd` | String, required | `"r"` repair (replaces a broken part) or `"o"` remove. |
| `tag` | int, optional | 1..2^31−1: the client's number for this action, answered by one `work_result` event (`events.md`) when the action has run. |

`vpart` and `mount` name the part a second time. Rows move up when a part comes off, so a `part` taken from a
list read before that can be another part's row by now; the sim then refuses instead of working on the wrong
part. Send them as ints: a result parsed from JSON has floats. (Added 2026-11-23, before this shape was frozen.)

`false`, nothing queued: a missing key, a wrong type (a `mount` that isn't two ints), anything out of range,
another `cmd`, a full queue, no game running.

When it runs, the sim checks everything again; nothing the client sent is taken on trust. Refused, nothing
done, with the sentence as a `message` and as the event's text:

| Text | |
|---|---|
| "There is no such vehicle here." | No vehicle with that uid in the reality bubble. |
| "That can't be worked on like a vehicle." | An appliance, or a summoned vehicle. |
| "That vehicle is too far away." | No part of it within a square of the player. |
| "That vehicle has no such part." | Not one of its part rows now. |
| "That part isn't there any more." | The row now holds a part of another type or at another mount than `vpart` and `mount` say: the client's list is older than the vehicle. Read again. Checked before any of CDDA's questions. |
| CDDA's sentence | Its own check says no: the read's `text` for that command ("It's too dark to see what you are doing…", "This part cannot be uninstalled.", ...). |
| "You don't meet the requirements to repair the X." / "... to remove the X." | A requirement line is not met (the read's `ok` false with `reason` 0). |
| "The X needs no repair." | The part isn't damaged. |

Otherwise the work starts as CDDA's vehicle screen starts it: the player gets CDDA's vehicle activity
(`ACT_VEHICLE` in `get_held().activity`), which takes the read's `time_s`. As for any activity, turns pass and
no snapshot comes until it ends, is interrupted (`interrupt()`) or asks something. CDDA's questions are real
requests the client answers (a yes / no `popup` has no cancel: answer `YES` or `NO`, CDDA asks again otherwise):

- Before anything else, a `popup` (yes / no) when the vehicle belongs to someone else ("This vehicle belongs
  to: ..., there may be consequences if you are observed interacting with it, continue?"). CDDA asks this before
  it checks the requirements, as its own screen does. No: nothing starts, and the event's text is "". A vehicle
  with no owner becomes the player's when work on it is started, as in CDDA.
- Before the start, a `popup` (yes / no) when the work would make an aircraft unfit to fly. No: nothing starts,
  and the event's text is "".
- When the work finishes, a `menu` when more than one component or tool could be used up for it.

The `work_result` event says the work was **started** (`amount` 1), not that it is finished. What it did shows
in the next snapshot and read: a repaired part's `hp` and `flags` (CDDA repairs down to the wear it can't take
back, so `hp` can stay below 100 with the repair bit gone); a removed part's row gone, with the rows after it
moving up by one. What a removal yields goes where CDDA puts it: into a cargo space on the player's
square, else at their feet. CDDA uses up the components and tools when the work finishes, and checks them again
then: if they are gone by then it says so and nothing is repaired or removed.

## Planned, not frozen

- **Install**: the read gets an `install` section for a square of the vehicle: the part types CDDA would list
  there (`can_mount`), which of them the player could install now, and the requirement lines for one of them.
  The action gets `cmd` `"i"` with the part type. Its questions: a `menu` for a new part's shape, and `popup` +
  `target` (look) for the facing of a new light, both when the work finishes.
- **Mend and refill**: `cmd` `"m"` (CDDA's mend `menu`, then its own activity) and `"f"` (`item_select` for what
  to refill from).
