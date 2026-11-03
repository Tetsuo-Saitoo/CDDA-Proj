#pragma once
#ifndef FP3D_BRIDGE_SIM_SESSION_H
#define FP3D_BRIDGE_SIM_SESSION_H

// The CDDA side of the GDExtension: owns the game thread. Only std types here, so cdda_sim.cpp (the Godot side)
// needs no CDDA headers beyond fp3d/bridge.h and fp3d/events.h.

#include <cstdint>
#include <string>

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
// debug.log under `user_dir`, and a new game in world `world` (an existing world of that name is deleted first).
// Both paths must be absolute; `world` is 1-32 of A-Z a-z 0-9 _ -. Once per process: CDDA's state is global.
// Returns "" when started, otherwise why not.
std::string start( const std::string &data_dir, const std::string &user_dir, const std::string &world );
// Shuts the bridge down and waits for the game thread. While booting that wait lasts until loading finishes.
void stop();
state get_state();
std::string error();

// The newest snapshot (0 before the first one).
uint64_t snapshot_seq();
// The newest snapshot as JSON (contracts/snapshot.md) with the levels from the player's z - z_below to
// z + z_above; "" before the first snapshot. `seq` gets the snapshot's seq.
std::string snapshot_json( int z_below, int z_above, uint64_t &seq );
// The id tables as JSON (contracts/id_tables.md); "" before the game data has loaded.
std::string id_tables_json( uint32_t &generation );

} // namespace fp3d_session

#endif // FP3D_BRIDGE_SIM_SESSION_H
