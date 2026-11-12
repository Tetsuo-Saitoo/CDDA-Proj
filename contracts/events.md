# Events (sim → client)

A queue of things that *happened*, for sound, one-shot animations, effects and the message feed. Implemented in
`cdda/src/fp3d/events.h` (block B4). The sim thread emits from hooks in CDDA's code, only while events are enabled
(`set_events_enabled`) and only what the player perceives; the client drains the queue (`drain_events`, any
thread). Each event carries:
- `turn`: the game turn it happened in;
- `seq`: the snapshot that shows its outcome. Play it when showing that snapshot (or at once if it is older).

Positions are absolute squares (`ui_point`, like the snapshot). Creature uids are the snapshot's uids.
`type` indexes a session table (see snapshot.md "Ids"); the snapshot JSON lists all tables.

```cpp
struct event {
    event_kind kind;   // sound, message, attack, damage, projectile, explosion, death, anim, turn_end
    int64 turn; uint64 seq;
    uint64 uid;        // actor (0 none)
    uint64 other;      // second creature (0 none)
    ui_point pos;
    int32 amount, heard;
    uint32 type, detail;
    string text;                 // cap 1024 bytes, cut on a UTF-8 boundary
    std::vector<ui_point> path;
};
```

| kind | uid | other | pos | amount | heard | type | detail | text / path | Sent when | CDDA hook |
|---|---|---|---|---|---|---|---|---|---|---|
| `sound` | | | source | volume | volume at the player | `sound` ("id/variant", footsteps "footstep") | `sound_t` | description | the player hears it | `sounds::process_sound_markers` |
| `message` | | | | | | | `game_message_type` | text without colour tags | always (it's the player's log) | `Messages` `add_msg_string` |
| `attack` | attacker | target | target's square | the player's hit only: technique family (0 none, 1 strike, 2 down, 3 stun, 4 disarm, 5 push) | | `itype` weapon (0 unarmed / monster) | 1 hit, 0 miss | the player's hit only: the technique's name (plain, cap 64 bytes; empty: none) | the player sees either | `Character::melee_attack_abstract`, `monster::melee_attack` |
| `damage` | target | source: the player or a creature the player sees (0 none or unseen) | target's square | HP lost | | `damage_type` (largest share) | `body_part` | | the player sees the target | `Creature::deal_damage` |
| `projectile` | shooter | creature hit | where it stopped | | | `itype` thrown item / arrow (0 bullets) | | path from the shooter's square (cap 256) | the player sees any square of it, the shooter or the hit | `projectile_attack` (ballistics.cpp) |
| `explosion` | | | centre | radius | | `explosion`: blast, fire_blast, flashbang, shockwave | `itype` of what exploded (grenade, C4, rocket ammo; 0 unknown) | text = the kind name; path = blast area (cap 1024) | the player sees the centre or any square | `do_blast`, `flashbang`, `shockwave` |
| `death` | the dead | | where | | | `mtype` (monsters) | | | the player sees it | `monster::die`, `Character::die` |
| `anim` | busy character | | where | | | `activity` (e.g. ACT_WAIT) | | | the player sees them | `Character::assign_activity` |
| `turn_end` | | | | | | | | | every turn | `do_turn` |

A melee hit's `attack` event comes before its `damage`, once per hit; a hit may have no `damage` event (no HP
lost, or a technique that kills at once: then its `death` follows).

Queue cap 4096 (nothing draining, or too slowly): overflow drops the oldest `sound` / `anim` / `turn_end` first,
then the oldest event of any kind; `drain_events` returns how many were dropped.

## Not yet

- `map_changed`: not needed; the snapshot's per-submap revisions tell the client what to rebuild.
- `ui_sound` (menus, inventory moves) and CDDA's `sfx::` calls (gun, melee hit, footstep variants): SOUND is off in
  our build, so they are stubs; hook them when the client's audio needs them.
- Ammo itype for bullets, sub-tile offsets, spell effects (`draw_custom_explosion` callers
  outside explosion.cpp).

## Done-when (B4)

`fp3d-events-test` checks each kind (fields, uids matching the snapshot, the `seq` stamp), that a death out of
sight is not sent, the overflow rule and the text cut. `fp3d-sim-test` drains events at every request while it
plays and checks turn ends, messages, the thrown rock and activity starts arrive with none dropped.
