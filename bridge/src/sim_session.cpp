#include "sim_session.h"

#include <algorithm>
#include <atomic>
#include <filesystem>
#include <memory>
#include <mutex>
#include <random>
#include <sstream>
#include <stdexcept>
#include <system_error>

#include "debug.h"
#include "do_turn.h"
#include "fp3d/boot.h"
#include "fp3d/bridge.h"
#include "fp3d/events.h"
#include "fp3d/game_access.h"
#include "fp3d/id_tables.h"
#include "fp3d/snapshot.h"
#include "game.h"
#include "map_scale_constants.h"
#include "rng.h"

#if defined(_WIN32)
#include <process.h>
#include "platform_win.h"
#else
#include <thread>
#endif

namespace fp3d_session
{
namespace
{

constexpr size_t max_path_bytes = 1024;
constexpr size_t max_world_name = 32;
// CDDA was written for a main thread; Windows gives new threads 1 MB of stack unless asked.
constexpr unsigned sim_stack_bytes = 8u << 20;

std::atomic<int> cur_state{ static_cast<int>( state::idle ) };
std::mutex error_mutex;
std::string error_text;
std::string boot_data_dir;
std::string boot_user_dir;
std::string boot_world;
#if defined(_WIN32)
HANDLE sim_thread = nullptr;
#else
std::thread sim_thread;
#endif

void set_state( state s )
{
    cur_state.store( static_cast<int>( s ) );
}

void set_error( const std::string &e )
{
    std::lock_guard<std::mutex> lk( error_mutex );
    error_text = fp3d::sanitize_text( e, 1024 );
}

// On the thread that made CDDA's window, before Godot unloads the DLL (see fp3d::shutdown_world).
void teardown()
{
    try {
        fp3d::shutdown_world();
    } catch( const std::exception &e ) {
        set_error( std::string( "teardown: " ) + e.what() );
    }
}

void sim_main()
{
    try {
        fp3d::init_paths( boot_data_dir, boot_user_dir );
        setupDebug( DebugOutput::file );
        rng_set_engine_seed( std::random_device{}() );
        fp3d::boot_world( boot_world, true );
        if( !fp3d_game_access::start_game( *g ) ) {
            throw std::runtime_error( "start_game failed" );
        }
        // The client reads the world while the sim waits for it, so every request comes with a fresh snapshot.
        fp3d::set_before_ask_hook( [] {
            fp3d::publish_snapshot( fp3d::capture_snapshot() );
        } );
        set_state( state::running );
        while( !do_turn() ) {
        }
        set_error( g->uquit == QUIT_DIED || g->uquit == QUIT_WATCH ? "the character died" : "the game ended" );
        set_state( state::ended );
    } catch( const fp3d::shutdown_signal & ) {
        set_state( state::stopped );
    } catch( const std::exception &e ) {
        set_error( e.what() );
        set_state( state::failed );
    }
    fp3d::shutdown();
    teardown();
}

#if defined(_WIN32)
unsigned __stdcall sim_entry( void * )
{
    sim_main();
    return 0;
}
#endif

// An absolute, existing directory (made if `create`), as UTF-8 with forward slashes; "" if not acceptable.
std::string checked_dir( const std::string &utf8, bool create, std::string &why )
{
    if( utf8.empty() || utf8.size() > max_path_bytes || utf8.find( '\0' ) != std::string::npos ) {
        why = "path empty or too long";
        return "";
    }
    std::error_code ec;
    const std::filesystem::path p = std::filesystem::u8path( utf8 ).lexically_normal();
    if( !p.is_absolute() ) {
        why = "path not absolute: " + utf8;
        return "";
    }
    if( create ) {
        std::filesystem::create_directories( p, ec );
    }
    if( !std::filesystem::is_directory( p, ec ) ) {
        why = "not a directory: " + utf8;
        return "";
    }
    std::string out = p.generic_u8string();
    if( out.back() != '/' ) {
        out += '/';
    }
    return out;
}

} // namespace

const char *state_name( state s )
{
    switch( s ) {
        case state::idle:
            return "idle";
        case state::booting:
            return "booting";
        case state::running:
            return "running";
        case state::ended:
            return "ended";
        case state::failed:
            return "failed";
        case state::stopped:
            return "stopped";
    }
    return "unknown";
}

std::string start( const std::string &data_dir, const std::string &user_dir, const std::string &world )
{
    if( get_state() != state::idle ) {
        return "already started (CDDA runs once per process)";
    }
    std::string why;
    const std::string data = checked_dir( data_dir, false, why );
    if( data.empty() ) {
        return why;
    }
    std::error_code ec;
    if( !std::filesystem::is_directory( std::filesystem::u8path( data + "data/json" ), ec ) ) {
        return "no data/json in " + data_dir;
    }
    const std::string user = checked_dir( user_dir, true, why );
    if( user.empty() ) {
        return why;
    }
    // The name becomes a folder under the user dir that boot deletes first: keep it a plain name.
    const bool name_ok = !world.empty() && world.size() <= max_world_name &&
    std::all_of( world.begin(), world.end(), []( char ch ) {
        return ( ch >= 'a' && ch <= 'z' ) || ( ch >= 'A' && ch <= 'Z' ) || ( ch >= '0' && ch <= '9' ) ||
               ch == '_' || ch == '-';
    } );
    if( !name_ok ) {
        return "bad world name";
    }
    boot_data_dir = data;
    boot_user_dir = user;
    boot_world = world;
    fp3d::set_active( true );
    fp3d::set_events_enabled( true );
    set_state( state::booting );
#if defined(_WIN32)
    sim_thread = reinterpret_cast<HANDLE>( _beginthreadex( nullptr, sim_stack_bytes, sim_entry, nullptr,
                                           STACK_SIZE_PARAM_IS_A_RESERVATION, nullptr ) );
    if( sim_thread == nullptr ) {
        set_state( state::failed );
        set_error( "cannot create the game thread" );
        return "cannot create the game thread";
    }
#else
    sim_thread = std::thread( sim_main );
#endif
    return "";
}

void stop()
{
    fp3d::shutdown();
#if defined(_WIN32)
    if( sim_thread != nullptr ) {
        WaitForSingleObject( sim_thread, INFINITE );
        CloseHandle( sim_thread );
        sim_thread = nullptr;
    }
#else
    if( sim_thread.joinable() ) {
        sim_thread.join();
    }
#endif
    if( get_state() == state::booting || get_state() == state::running ) {
        set_state( state::stopped );
    }
}

state get_state()
{
    return static_cast<state>( cur_state.load() );
}

std::string error()
{
    std::lock_guard<std::mutex> lk( error_mutex );
    return error_text;
}

uint64_t snapshot_seq()
{
    const std::shared_ptr<const fp3d::snapshot> s = fp3d::latest_snapshot();
    return s ? s->seq : 0;
}

std::string snapshot_json( int z_below, int z_above, uint64_t &seq )
{
    const std::shared_ptr<const fp3d::snapshot> s = fp3d::latest_snapshot();
    seq = s ? s->seq : 0;
    if( !s ) {
        return "";
    }
    const int levels = OVERMAP_DEPTH + OVERMAP_HEIGHT;
    const int pz = s->player.pos.z;
    std::ostringstream out;
    fp3d::write_snapshot_json( out, *s, std::max( -OVERMAP_DEPTH, pz - std::clamp( z_below, 0, levels ) ),
                               std::min( OVERMAP_HEIGHT, pz + std::clamp( z_above, 0, levels ) ) );
    return out.str();
}

std::string id_tables_json( uint32_t &generation )
{
    const std::shared_ptr<const fp3d::id_tables> t = fp3d::latest_id_tables();
    generation = t ? t->generation : 0;
    if( !t ) {
        return "";
    }
    std::ostringstream out;
    fp3d::write_id_tables_json( out, *t );
    return out.str();
}

} // namespace fp3d_session
