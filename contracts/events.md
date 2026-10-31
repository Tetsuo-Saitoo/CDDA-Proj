# Events (sim → client)

A queue of things that *happened*, stamped with `turn` and `seq` of the snapshot they belong to. The client
uses them for sound, animation one-shots, effects and the message feed. Events about things the player can't
perceive are dropped by the sim (sounds are the exception: they carry `heard_volume`).

| Event | Fields | CDDA source to hook |
|---|---|---|
| `sound` | pos, volume, heard_volume, category (`sound_t`), id/variant, description | `sounds::sound()` (sounds.cpp) |
| `message` | text, type (`game_message_type`) | `add_msg*` → message log |
| `attack` | attacker uid, target uid or pos, weapon itype, technique id, hit/miss | melee code (`Character::melee_attack`, monster attacks) |
| `damage` | target uid, body part, amount, type, is_crit | `Creature::deal_damage` |
| `projectile` | from pos (+subtile), path [pos…] (cap 256), ammo itype, hit uid/pos | `game::draw_bullet` / `projectile_attack` |
| `explosion` | pos, radius, type (fire/shrapnel/emp) | `explosion_handler` + `game::draw_explosion` |
| `death` | uid, corpse itype | `monster::die`, `Character::die` |
| `anim` | uid, name (reload, eat, read, climb, fall, open, …) | activity/action starts |
| `map_changed` | submap pos list (cap 1331) | anything that bumps a SubmapView revision; lets the client rebuild meshes early |
| `ui_sound` | id | menus, inventory moves |
| `turn_end` | turn | end of `game::do_turn` |

Positions are `tripoint_abs_ms` (+ optional `subtile` vec3f). Cap: 4096 events per snapshot; overflow drops the
oldest `sound`/`anim` events first, never `message`/`death`/`damage`.
