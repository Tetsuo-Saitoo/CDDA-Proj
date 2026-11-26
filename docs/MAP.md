# Map (PLAN.md G5): plan

Status: plan only (lead-ui, 2026-11-26); the user answered its two questions. No code until the user approves
slice 1.

The goal is CDDA's overmap as a map the player looks at: 2D first, 3D later, with notes, routes and auto-travel.
CDDA decides everything: what the player has seen, what a note says, whether a route exists and how travel runs.
The client only shows that and sends the player's choices. The HUD-in-view rule applies (TASKS "HUD in the view"):

- **MapData** (`client/scripts/map/map_data.gd`, lead-ui) is the one shared data layer. It holds the pages it has
  read, the notes, the destination and the selection, and emits `changed`.
- **The canvas** is `ui/map_canvas.gd` (lead-ui), the one painter for both views. It is a Control that reads only
  MapData, and its `cell_at(local_px) -> Vector2i` gives the cell under a point.
- **The screen view** is `ui/map_view.gd` (lead-ui): a full-screen panel holding the canvas, on CDDA's map key.
- **The VR view** is `vr/vr_map.gd` (lead-vr; agreed 2026-11-26): the canvas in a SubViewport on a sheet held in
  the off hand, as VrPanel shows flat UI, like a paper map.
  - The off hand is the left one, or the right one if the rig is left-handed.
  - The map opens from a controller binding or from CDDA's map key. It is put away when that hand grips something
    or the map is closed.
  - That hand's stick pans and zooms, and a stick click changes the level. A two-hand pull to zoom can come later.
  - vr_map.gd owns the hold, the pointing (where the hand's ray meets the sheet gives the cell, through
    `cell_at`), the name label and the wheel.
  - Pointing at a cell shows its name. Only the trigger opens the wheel, and nothing acts on gaze.
- Both views exist from slice 1.

## Slices (smallest useful first)

1. **Read-only 2D map.**
   - It shows the player's level around the player. Each cell uses CDDA's symbol and colour for what the player
     has seen.
   - Pan, zoom, and PgUp/PgDn for the level. Hovering or pointing at a cell shows CDDA's name for it.
   - It also shows the player's arrow, the notes (symbol, and the text on hover) and the current destination's
     path.
   - Tests:
     - MapData tests with a stand-in bridge: paging, caps, bad data dropped.
     - A fork sim test: unseen cells read as unseen, a vaguely seen cell reads as its vague look only, notes
       read back, and a page over ground with no overmap yet reads as unseen and creates none.
     - A live test on the game's own read, like range_ui_live_test: the player's cell matches CDDA's `ter` there,
       and a far cell the player hasn't seen reads as unseen.
2. **Notes.**
   - Add, edit and delete a note on a cell: text, CDDA's symbol and colour, and the danger mark with its radius.
     Refused notes come back with CDDA's sentence.
   - VR has no text entry yet:
     - The symbol, the colour and the danger mark with its radius come from the wheel.
     - The text is picked from a short word list; a few words can be joined.
     - Editing a note keeps its text unless new words are picked.
     - A desk keyboard, when there is one, opens the flat note dialog.
     - A VR keyboard is a later piece of lead-vr's and does not block this slice.
   - Live test: add a note, read it back, edit it, delete it. Overlong text is capped, and control characters
     are stripped.
3. **Routes with several stops, and auto-travel** (user, 2026-11-26: several stops, each leg CDDA's own route and
   travel).
   - **The stop list lives in the client** (MapData). It holds at most 16 stops, all on the level the route starts
     on, because CDDA's travel never changes level.
     - The player adds, moves and removes stops on the map. In VR, "Add stop" and "Clear stops" are on the wheel.
     - The list is kept until the game ends and is not saved. Saving it can come later; if it does, it is read back
       as untrusted data, bounded to 16 stops.
   - **Drawing:**
     - The current leg is CDDA's own path, the read's `path`, drawn with its length.
     - Later legs are dashed straight lines between numbered stops, marked "not checked yet". CDDA checks each leg
       when it becomes the current one.
   - **Going:** "Go" sends `travel` for the first stop.
     - CDDA asks its question as a `popup` request ("Travel to this point?", overburdened, walking while in a
       vehicle). It does this for every leg, because the client never answers CDDA's questions for the player.
     - Then CDDA runs ACT_TRAVELLING, or autodrive when driving.
   - **Next leg:** a leg has ended when the snapshot shows the travel activity has stopped. If the player's cell
     is that leg's stop, the stop is dropped and `travel` goes out for the next one, with CDDA's question again.
   - **Refused, answered no, or interrupted partway** (CDDA's own interruption, such as a monster seen, or the
     player's):
     - The route stops there, and CDDA's sentence is shown.
     - The rest of the list is kept but never run on its own. "Go" carries on from the next stop that hasn't been
       reached.
     - The player stops travel with a key on the flat screen, or a grip or stick push in VR. Both send the bridge's
       existing `interrupt()`, which CDDA confirms first ("Cancel auto move?").
   - **VR:** "Go" is its own wheel item, and CDDA's questions come on the VR panel. VR comfort (vignette, blink)
     has to hold while the player moves on their own; lead-vr checks that in this slice.
   - **Fork:** nothing new. Each leg is the same `travel` command (and `route` for the current leg's path).
     Checking legs ahead would need `route` from a given cell; that can be added later with lead-bridge if
     unchecked legs prove a nuisance.
   - **Tests:**
     - MapData tests: the cap, a reached stop dropped, and the rest kept after a refusal, a no and an
       interruption.
     - Live test on the range: a two-stop route ends on the second stop after CDDA's question for each leg. An
       `interrupt()` partway keeps the rest. An unreachable stop gives CDDA's sentence. Travel by car uses
       autodrive.
4. **Overlays** that CDDA's map shows, and only when it shows them: hordes in sight, the player's vehicles, camps,
   mission targets, city names.
5. **3D map (later)**, planned with lead-world when it is scheduled. C8 Horizon could reuse the same pages.

## Bridge data (agreed with lead-bridge 2026-11-26; contract `contracts/overmap.md`)

- **Read:** `query_overmap(d)` {origin [x, y, z] in absolute OMT, path?}, answered through `take_query_result`.
  - The origin must be a multiple of 32 so pages line up; any other origin is refused. Levels are -10 to 10, and
    x and y are bounded.
  - A page is 32x32 cells (OMTs) on one level. The cells come as flat int arrays: the look index, CDDA's
    `om_vision_level` (0 unseen, 1 vague, 2 outlines, 3 details, 4 full) and a `flags` int.
  - A look is what CDDA's own map screen draws at that vision level: `oter_t::get_name` / `get_symbol` /
    `get_color(om_vision_level)`. The looks come in a list in the same answer.
  - Cut 1 sends no terrain id at any level, only the look. Ids for full-vision cells can come later if lead-world
    needs them for 3D or C8.
  - The page carries its notes: `overmap_buffer::note`, with symbol and colour parsed by CDDA's
    `get_note_display_info`, `is_marked_dangerous` and `note_danger_radius`. Map-extra auto notes are ordinary
    notes and come with the rest.
  - The player's destination path (`avatar::omt_path`) comes only when the query asks for it (`path: true`).
- **The read never creates ground.** It uses only the calls that look at overmaps that already exist: `seen`,
  `ter_existing`, `note`, `has_note`, `is_marked_dangerous`. It never uses `ter()` or anything that goes through
  `get_om_global`, because those generate a whole overmap. A page over ground with no overmap yet is all unseen.
- **Flags:** `flags` is there from cut 1, so the overlays can come later without a new shape. It covers:
  - the explored mark (`is_explored`; a command to set it comes later);
  - vehicles the player chose to track (`has_vehicle`);
  - camps (`has_camp`);
  - the active mission's target;
  - city labels (level 0; a toggle in CDDA).
- **Not sent:** anything CDDA's map screen hides. That is cells not seen, and the real type below full vision.
  Hordes and NPCs appear only inside the player's overmap sight range, as CDDA draws them. Map memory (the
  remembered tiles inside the bubble) stays where it is today.
- **Caps:**
  - Query answers are at most 64 KB.
  - A page holds 1024 cells, 256 looks and 256 notes. A cell beyond the 256 looks gets look 0, and the page says
    `truncated`.
  - The path is at most 2048 cells.
- **Paging:**
  - The client asks for the pages on screen, one query out at a time, and takes each answer before posting the
    next. The map gets its own small share of waiting results.
  - Pages are kept for as long as the map is open, at most 256.
  - The player's page is read again when the player enters a new cell, and all pages are dropped when the map
    closes.
  - The player's cell comes from the snapshot (`bubble_origin` plus the player's position).
- **Commands:** `queue_overmap(d)` {cmd "note" | "unnote" | "route" | "travel", omt [x, y, z], text?, danger?,
  radius?, tag?}. Each is answered by a new event kind, `map_result` {tag, 1 started or done, 0 refused, CDDA's
  sentence}. The fork checks everything again.
  - `note` uses `add_note` / `mark_note_dangerous`. It is refused on a cell whose overmap doesn't exist yet,
    because `add_note` would create it. The danger radius is bounded to CDDA's own range ("Danger radius in
    overmap squares? (0-N)").
  - `unnote` uses `delete_note`. On a cell without a note it is refused with a sentence.
  - `route` sets the path, which is CDDA's first step: `get_overmap_path_to`, lifted out of overmap_ui into an
    FP3D-marked function.
    - It finds nothing for an unseen destination or one on another level, and its search radius is four
      overmaps (720 cells).
    - lead-bridge checks whether that search can create overmaps and bounds it if so.
  - `travel` is CDDA's second step; on its own it works out the path itself. It runs
    `try_travel_to_destination`'s steps.
    - Its one question comes as a yes/no `popup` request: "Travel to / Drive to this point?", overburdened, or
      walking while in a vehicle.
    - Its failure boxes ("Unable to find a path from the current location:", "Auto travel requires source and
      destination on same Z level:") become the refusal sentence, not a request.
    - "Started" means ACT_TRAVELLING or autodrive was assigned. From then on it is an activity like any other:
      no snapshot until it ends, asks something or is interrupted.
  - Driving is never sent: the fork decides it (`in_vehicle` and `controlling_vehicle`), as overmap_ui does.

## Security

- Note text comes from the player and from save files, which may come from other people. Both sides treat it as
  hostile.
  - Outgoing (the read): capped by columns and bytes and cut on a character boundary, like every other text
    field.
  - Incoming (the command): at most 450 columns (CDDA's input box) and a byte cap, control characters removed.
    CDDA's own "symbol:colour;" prefix stays allowed, because that is how a player picks them.
  - The client shows the text as plain text only, never BBCode.
- Every list in an answer is capped, and every look index is checked against its list. Coordinates are range
  checked on both sides.
- The client never keeps more than 256 pages.
- Neither reads nor commands may create ground. The route search is bounded.

## Project Zomboid (the user's main reference)

- **Taken from PZ:**
  - The map as a thing you look at: a paper-map look, and in VR a map in the hands.
  - Fog over what you haven't seen.
  - Symbols and short notes you put on the map yourself.
  - Map items that reveal an area.
- **What CDDA already does the same way:**
  - What the player has seen, with finer levels than PZ (vague, outlines, details, full).
  - Map items that reveal a radius (`reveal_map_actor`: road maps, tourist maps).
  - Notes with a symbol and colour, and danger notes, which auto-travel avoids.
- **Where they differ:** PZ writes notes onto a map item; CDDA's notes belong to the character. We keep CDDA's.
- PZ has no auto-travel; that part is CDDA's.

## Decided (user, 2026-11-26)

1. **Look:** CDDA's symbols and colours first; a PZ-style paper look is a later pass.
2. **Routes:** several stops, each leg CDDA's own route and travel (slice 3).
