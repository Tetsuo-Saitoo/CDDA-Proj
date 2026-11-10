#pragma once
#ifndef FP3D_BRIDGE_SIM_SESSION_H
#define FP3D_BRIDGE_SIM_SESSION_H

// The CDDA side of the GDExtension: owns the game thread. Only std types here, so cdda_sim.cpp (the Godot side)
// needs no CDDA headers beyond fp3d/bridge.h and fp3d/events.h.

#include <cstdint>
#include <string>
#include <vector>

namespace fp3d_session
{

enum class state : int {
    idle,       // not started
    booting,    // loading data and starting a new game (~30 s)
    running,    // playing: requests, snapshots and events flow
    ended,      // the game ended (death, quit); error() says why
    failed,     // boot or the game threw; error() says why
    stopped,    // stop() was called
};
const char *state_name( state s );

// Starts CDDA on its own thread with data from `data_dir` (the folder holding data/ and gfx/), config, saves and
// debug.log under `user_dir`. With `save` empty: a new game in world `world` (an existing world of that name is
// deleted first; `world` is 1-32 of A-Z a-z 0-9 _ -). Otherwise: loads the character `save` from the existing
// world `world`, deleting nothing; both must be names list_saves() gives. Both paths must be absolute.
// Once per process: CDDA's state is global. Returns "" when started, otherwise why not.
std::string start( const std::string &data_dir, const std::string &user_dir, const std::string &world,
                   const std::string &save = "" );
// A new game, like start() with no save, but: `fresh_world` false puts a new character into the existing world
// `world` (one list_worlds() gives; nothing is deleted), and `chargen` asks the client for the character with a
// `chargen` request (contracts/ui_requests.md) instead of a random one; `world_setup` (fresh worlds) asks
// for the world's settings and mods with a `world_setup` request first. Cancelling it ends the session (failed).
std::string start_new_game( const std::string &data_dir, const std::string &user_dir, const std::string &world,
                            bool fresh_world, bool chargen, bool world_setup = false );
// The test range (fork fp3d/test_range.h): a new game in FP3D's own throwaway world `fp3d-range` (or the next free
// `fp3d-range-N` when someone else's world has that name), rebuilt on every start, with cheats allowed.
std::string start_test_range( const std::string &data_dir, const std::string &user_dir );
// Shuts the bridge down and waits for the game thread. While booting that wait lasts until loading finishes.
void stop();
state get_state();
std::string error();

// Worlds under `user_dir`/save (folders holding worldoptions.json or master.gsav) and the characters saved in
// one, sorted, at most max_listed each. Read straight from the folders, so they work before start(). Names that
// aren't plain text or could be paths are left out. Empty if there are none; `why` says if the input was bad.
constexpr size_t max_listed = 256;
std::vector<std::string> list_worlds( const std::string &user_dir, std::string &why );
std::vector<std::string> list_saves( const std::string &user_dir, const std::string &world, std::string &why );

// The newest snapshot (0 before the first one).
uint64_t snapshot_seq();
// The newest snapshot as JSON (contracts/snapshot.md) with the levels from the player's z - z_below to
// z + z_above; "" before the first snapshot. `seq` gets the snapshot's seq.
std::string snapshot_json( int z_below, int z_above, uint64_t &seq );
// The id tables as JSON (contracts/id_tables.md); "" before the game data has loaded.
std::string id_tables_json( uint32_t &generation );

} // namespace fp3d_session

#endif // FP3D_BRIDGE_SIM_SESSION_H
