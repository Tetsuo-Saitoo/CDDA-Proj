# Contracts (v0 draft)

The interface between `libcdda` (sim, block B) and everything else (client, tools). Block B owns these files;
other blocks propose changes by PR. `CONTRACT_VERSION` = **0** until M2; after that, additive changes bump the
minor version and breaking changes bump the major.

| File | Direction | Summary |
|---|---|---|
| [snapshot.md](snapshot.md) | sim → client | Read-only world state, once per turn and after each player action |
| [events.md](events.md) | sim → client | Things that happened (sounds, hits, projectiles, messages) |
| [id_tables.md](id_tables.md) | sim → client | What the ids mean: names, symbols, looks_like, flags, connect groups; once per world |
| [actions.md](actions.md) | client → sim | What the player wants to do |
| [ui_requests.md](ui_requests.md) | sim ⇄ client | Blocking prompts the sim asks and the client answers |
| [bridge_api.md](bridge_api.md) | Godot ⇄ sim | The GDExtension class `CddaSim` that carries all of the above in-process |
| [assets.md](assets.md) | data | `fp3d_model` registry and art fallback chain |
| [ids.md](ids.md) | sim → client | Id tables (ter/furn/trap/field/item/monster/vpart) sent once per session |

## Rules for every contract

- **Coordinates are absolute** map squares (`tripoint_abs_ms`, x/y/z ints) or absolute submaps
  (`tripoint_abs_sm`). Never bubble-relative: the bubble shifts (`map::shift`) and relative coords would go
  stale. The client converts to Godot space in one place (block C1).
- **Ids are session indices** (`uint32`) into the tables from `ids.md`. Strings cross the bridge only once.
- **The sim is authoritative.** The client may predict (movement, animation) but must reconcile with the next
  snapshot. Nothing the client sends is trusted: the sim validates every action and answer (range, ownership,
  reachability) exactly as CDDA would for keyboard input.
- **Hidden information stays hidden.** Creatures, items and fields the player can't perceive are not in the
  snapshot. Terrain and furniture of the whole bubble are sent (they are the physical world); the client darkens
  them using the light/visibility values.
- **Bounded sizes.** Every list has a hard cap (listed per field). The bridge drops and logs anything over the
  cap instead of growing without limit.
- Mock data for building without the sim lives in `mock/` (block B dumps it from a real save).
