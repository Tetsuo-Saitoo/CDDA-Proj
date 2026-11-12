#include "sim_session.h"

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstdint>
#include <ctime>
#include <filesystem>
#include <memory>
#include <mutex>
#include <random>
#include <sstream>
#include <stdexcept>
#include <system_error>

#include "avatar.h"
#include "debug.h"
#include "do_turn.h"
#include "fp3d/boot.h"
#include "fp3d/bridge.h"
#include "fp3d/chargen.h"
#include "fp3d/cheats.h"
#include "fp3d/events.h"
#include "fp3d/game_access.h"
#include "fp3d/held.h"
#include "fp3d/id_tables.h"
#include "fp3d/snapshot.h"
#include "fp3d/test_range.h"
#include "game.h"
#include "map_scale_constants.h"
#include "rng.h"

#if defined(_WIN32)
#include <process.h>
#include "platform_win.h"
#else
#include <fcntl.h>
#include <pthread.h>
#include <sys/file.h>
#include <unistd.h>
#endif

namespace fp3d_session
{
namespace
{

constexpr size_t max_path_bytes = 1024;
constexpr size_t max_world_name = 32;
// Names read from the user dir (CDDA allows 32 UTF-8 characters for worlds; character names are free text).
constexpr size_t max_name_bytes = 128;
// Folder entries looked at per listing, so a huge or hostile folder can't stall the caller.
constexpr size_t max_dir_entries = 4096;
// Entries delete_save removes at most (a big world's map folders hold many files) and how deep it goes.
constexpr size_t max_delete_entries = 1000000;
constexpr int max_delete_depth = 8;
// CDDA was written for a main thread; new threads get 1 MB (Windows) or 512 KB (macOS) unless asked.
constexpr unsigned sim_stack_bytes = 8u << 20;

std::atomic<int> cur_state{ static_cast<int>( state::idle ) };
std::mutex error_mutex;
std::string error_text;
std::string boot_data_dir;
std::string boot_user_dir;
std::string boot_world;
std::string boot_save;
// New games: false = a new character in an existing world; true = CDDA's character creation through the client.
bool boot_fresh_world = true;
bool boot_replace_world = false;  // start(): FP3D's own throwaway world may be replaced
bool boot_chargen = false;
bool boot_world_setup = false;
bool boot_range = false;          // start_test_range()
#if defined(_WIN32)
HANDLE sim_thread = nullptr;
#else
pthread_t sim_thread;
bool sim_thread_running = false;
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

bool move_state( state from, state to )
{
    int f = static_cast<int>( from );
    return cur_state.compare_exchange_strong( f, static_cast<int>( to ) );
}

// The game thread's last word (and the boot watchdog's): only over booting or running, so a boot the watchdog gave
// up on stays failed with its reason even if the game thread gets going again later.
bool finish( state to, const std::string &e )
{
    std::lock_guard<std::mutex> lk( error_mutex );
    if( !move_state( state::booting, to ) && !move_state( state::running, to ) ) {
        return false;
    }
    error_text = fp3d::sanitize_text( e, 1024 );
    return true;
}

// The last debug message CDDA logged, for a failure's reason.
std::string with_last_cdda_error( const std::string &e )
{
    const fp3d::boot_progress p = fp3d::latest_boot_progress();
    return p.last_error.empty() ? e : e + " (CDDA's last error: " + p.last_error + ")";
}

// A boot that stopped moving: no boot step (CDDA's loading screen notes one per data file) and no request waiting
// on the client for boot_stall_limit. Waiting on the player (character creation, world settings) doesn't count.
// The game thread can't be stopped from outside: the boot is reported failed, the game thread is told to shut
// down (it ends at its next request if it ever gets there), and stop() waits for it only so long.
constexpr std::chrono::seconds boot_stall_limit{ 180 };
constexpr std::chrono::seconds abandoned_join_limit{ 10 };
std::mutex watch_mutex;
uint64_t watch_steps = 0;
std::chrono::steady_clock::time_point watch_since;
std::atomic<bool> boot_abandoned{ false };
// The game thread has finished (its teardown done) or never started: its files are closed.
std::atomic<bool> sim_done{ false };

// One process per world: a game holds an OS lock on its world's lock file (user_dir/fp3d_locks/...) until its game
// thread is done; the OS lets go when the process ends, crashed or not. delete_save takes it while it deletes.
#if defined(_WIN32)
using os_lock = HANDLE;
const os_lock no_lock = INVALID_HANDLE_VALUE;
#else
using os_lock = int;
const os_lock no_lock = -1;
#endif
enum class lock_result { taken, held_elsewhere, failed };
std::mutex game_lock_mutex;
os_lock game_lock = no_lock;

void check_boot_stall()
{
    if( static_cast<state>( cur_state.load() ) != state::booting ) {
        return;
    }
    const fp3d::boot_progress p = fp3d::latest_boot_progress();
    const auto now = std::chrono::steady_clock::now();
    std::lock_guard<std::mutex> lk( watch_mutex );
    if( p.steps != watch_steps || watch_since == std::chrono::steady_clock::time_point() ||
        fp3d::wait_request( 0 ).has_value() ) {
        watch_steps = p.steps;
        watch_since = now;
        return;
    }
    if( now - watch_since < boot_stall_limit ) {
        return;
    }
    const std::string why = with_last_cdda_error( "the game stopped booting: nothing moved for " +
                            std::to_string( boot_stall_limit.count() ) + " s in \"" +
                            ( p.phase.empty() ? std::string( "the start" ) : p.phase ) +
                            "\"; CDDA's log is config/debug.log in the game's user folder" );
    if( finish( state::failed, why ) ) {
        boot_abandoned.store( true );
        fp3d::shutdown();
    }
}

namespace fs = std::filesystem;

// The lock file's name: the world name's first 60 bytes in hex and a 64-bit hash of all of it, ASCII letters
// lower-cased first (Windows folder names ignore case; callers pass the folder's own spelling, which list_worlds
// gives, so other letters match too), so no world name can make a path, a device name or an overlong name. The test
// range's worlds (fp3d-range, fp3d-range-N) share one: its boot picks which itself.
fs::path lock_path( const fs::path &user, const std::string &world )
{
    std::string key = world;
    if( key.rfind( "fp3d-range-", 0 ) == 0 && key.size() > 11 &&
        std::all_of( key.begin() + 11, key.end(), []( char ch ) {
        return ch >= '0' && ch <= '9';
    } ) ) {
        key = "fp3d-range";
    }
    static const char *const digits = "0123456789abcdef";
    std::string hex;
    uint64_t hash = 14695981039346656037ull;   // FNV-1a
    for( size_t i = 0; i < key.size(); i++ ) {
        unsigned char c = static_cast<unsigned char>( key[i] );
        if( c >= 'A' && c <= 'Z' ) {
            c = static_cast<unsigned char>( c - 'A' + 'a' );
        }
        hash = ( hash ^ c ) * 1099511628211ull;
        if( i < 60 ) {
            hex += digits[c >> 4];
            hex += digits[c & 15];
        }
    }
    hex += '-';
    for( int shift = 60; shift >= 0; shift -= 4 ) {
        hex += digits[( hash >> shift ) & 15];
    }
    return user / "fp3d_locks" / ( hex + ".lock" );
}

// Takes the world's lock without waiting. A planted link in place of the lock file is opened itself, not followed.
lock_result take_lock( const fs::path &user, const std::string &world, os_lock &out )
{
    out = no_lock;
    const fs::path dir = user / "fp3d_locks";
    std::error_code ec;
    fs::create_directory( dir, ec );
    if( fs::symlink_status( dir, ec ).type() != fs::file_type::directory ) {
        return lock_result::failed;
    }
    const fs::path p = lock_path( user, world );
#if defined(_WIN32)
    const HANDLE h = CreateFileW( p.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_ALWAYS,
                                  FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr );
    if( h == INVALID_HANDLE_VALUE ) {
        return GetLastError() == ERROR_SHARING_VIOLATION ? lock_result::held_elsewhere : lock_result::failed;
    }
    out = h;
#else
    const int fd = open( p.c_str(), O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600 );
    if( fd < 0 ) {
        return lock_result::failed;
    }
    if( flock( fd, LOCK_EX | LOCK_NB ) != 0 ) {
        const int e = errno;
        close( fd );
        return e == EWOULDBLOCK ? lock_result::held_elsewhere : lock_result::failed;
    }
    out = fd;
#endif
    return lock_result::taken;
}

void release_lock( os_lock &l )
{
    if( l == no_lock ) {
        return;
    }
#if defined(_WIN32)
    CloseHandle( l );
#else
    close( l );
#endif
    l = no_lock;
}

void release_game_lock()
{
    std::lock_guard<std::mutex> lk( game_lock_mutex );
    release_lock( game_lock );
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
        fp3d::note_boot_step( "Paths and log" );
        fp3d::init_paths( boot_data_dir, boot_user_dir );
        setupDebug( DebugOutput::file );
        rng_set_engine_seed( std::random_device{}() );
        if( boot_range ) {
            fp3d::boot_new_game_data( boot_world, true, true, false, true );
            fp3d::note_boot_step( "Building the test range" );
            fp3d::boot_test_range( 1 );
            fp3d::set_cheats_allowed( true );
        } else if( boot_save.empty() ) {
            if( boot_chargen || boot_world_setup || !boot_fresh_world || !boot_replace_world ) {
                fp3d::boot_new_game_data( boot_world, boot_fresh_world, true, boot_world_setup,
                                          boot_replace_world );
                if( boot_chargen ) {
                    fp3d::note_boot_step( "Character creation" );
                    if( !fp3d::run_chargen() ) {
                        throw std::runtime_error( "character creation cancelled" );
                    }
                } else {
                    get_avatar().create( character_type::NOW );
                }
            } else {
                fp3d::boot_world( boot_world, true );
            }
            fp3d::note_boot_step( "Starting the game (world and map)" );
            if( !fp3d_game_access::start_game( *g ) ) {
                throw std::runtime_error( "start_game failed" );
            }
        } else {
            fp3d::boot_saved_game( boot_world, boot_save, true );
            // A saved test range (only in one of FP3D's own range worlds: the save alone never makes one) is a range
            // game again, with the range operations allowed as when it started.
            if( fp3d::resume_test_range() ) {
                fp3d::set_cheats_allowed( true );
            }
            fp3d::reset_snapshots();
        }
        // The client reads the world while the sim waits for it, so every request but a `shot` one (fp3d::ask skips
        // the hook for those: a burst asks once per round) comes with a fresh snapshot and held state.
        fp3d::set_before_ask_hook( [] {
            // Test range operations first (main-loop requests only), so the snapshot shows what they did.
            fp3d::run_range_requests();
            fp3d::capture_range_info();
            fp3d::publish_snapshot( fp3d::capture_snapshot() );
            fp3d::publish_held();
        } );
        fp3d::note_boot_step( "Running" );
        // Not when the boot watchdog gave up on it meanwhile (check_boot_stall): that stays failed.
        if( move_state( state::booting, state::running ) ) {
            while( !do_turn() ) {
            }
            finish( state::ended, g->uquit == QUIT_DIED || g->uquit == QUIT_WATCH ? "the character died" :
                    g->uquit == QUIT_SAVED ? "saved and quit" : "the game ended" );
        }
    } catch( const fp3d::shutdown_signal & ) {
        finish( state::stopped, "" );
    } catch( const std::exception &e ) {
        finish( state::failed, with_last_cdda_error( e.what() ) );
    }
    fp3d::shutdown();
    teardown();
    release_game_lock();
    sim_done.store( true );
}

#if defined(_WIN32)
unsigned __stdcall sim_entry( void * )
{
    sim_main();
    return 0;
}
#else
void *sim_entry( void * )
{
    sim_main();
    return nullptr;
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

// An absolute path from a script, normalised; empty (and `why`) if not acceptable.
fs::path checked_path( const std::string &utf8, std::string &why )
{
    if( utf8.empty() || utf8.size() > max_path_bytes || utf8.find( '\0' ) != std::string::npos ) {
        why = "path empty or too long";
        return {};
    }
    const fs::path p = fs::u8path( utf8 ).lexically_normal();
    if( !p.is_absolute() ) {
        why = "path not absolute: " + utf8;
        return {};
    }
    return p;
}

// A new world's name becomes a folder that boot deletes first: keep it a plain name.
bool new_world_name_ok( const std::string &name )
{
    return !name.empty() && name.size() <= max_world_name &&
    std::all_of( name.begin(), name.end(), []( char ch ) {
        return ( ch >= 'a' && ch <= 'z' ) || ( ch >= 'A' && ch <= 'Z' ) || ( ch >= '0' && ch <= '9' ) ||
               ch == '_' || ch == '-';
    } );
}

// 1..max_bytes of valid UTF-8 (no overlong forms, surrogates or code points past U+10FFFF), no control characters.
bool plain_text( const std::string &s, size_t max_bytes )
{
    if( s.empty() || s.size() > max_bytes ) {
        return false;
    }
    static const uint32_t min_cp[] = { 0, 0, 0x80, 0x800, 0x10000 };
    size_t i = 0;
    while( i < s.size() ) {
        const unsigned char c = static_cast<unsigned char>( s[i] );
        if( c < 0x80 ) {
            if( c < 0x20 || c == 0x7f ) {
                return false;
            }
            i++;
            continue;
        }
        size_t len = 0;
        uint32_t cp = 0;
        if( ( c & 0xe0 ) == 0xc0 ) {
            len = 2;
            cp = c & 0x1f;
        } else if( ( c & 0xf0 ) == 0xe0 ) {
            len = 3;
            cp = c & 0x0f;
        } else if( ( c & 0xf8 ) == 0xf0 ) {
            len = 4;
            cp = c & 0x07;
        } else {
            return false;
        }
        if( i + len > s.size() ) {
            return false;
        }
        for( size_t k = 1; k < len; k++ ) {
            const unsigned char cc = static_cast<unsigned char>( s[i + k] );
            if( ( cc & 0xc0 ) != 0x80 ) {
                return false;
            }
            cp = ( cp << 6 ) | ( cc & 0x3f );
        }
        // C1 controls (U+0080-U+009F) are out too.
        if( cp < min_cp[len] || cp < 0xa0 || cp > 0x10ffff || ( cp >= 0xd800 && cp <= 0xdfff ) ) {
            return false;
        }
        i += len;
    }
    return true;
}

// An existing world's folder name: plain text that can't be a path or a name Windows changes.
bool world_name_ok( const std::string &name )
{
    return plain_text( name, max_name_bytes ) && name.find_first_of( "/\\:*?\"<>|" ) == std::string::npos &&
           name.front() != '.' && name.front() != ' ' && name.back() != '.' && name.back() != ' ';
}

// A character name (CDDA's save id). CDDA keeps a name that starts with '#' unencoded as the file name: refused.
bool save_name_ok( const std::string &name )
{
    return plain_text( name, max_name_bytes ) && name.front() != '#';
}

int base64_digit( char ch )
{
    if( ch >= 'A' && ch <= 'Z' ) {
        return ch - 'A';
    }
    if( ch >= 'a' && ch <= 'z' ) {
        return ch - 'a' + 26;
    }
    if( ch >= '0' && ch <= '9' ) {
        return ch - '0' + 52;
    }
    return ch == '+' ? 62 : ch == '-' ? 63 : -1;
}

// The character name in a save file name: '#', CDDA's base64 (A-Z a-z 0-9 + -, '=' padding), then ".sav" or
// ".sav.zzip" (compressed worlds). "" if it isn't one, or if CDDA wouldn't encode the name back to this file.
std::string save_name_of_file( const std::string &file )
{
    std::string digits;
    for( const std::string ext : { ".sav", ".sav.zzip" } ) {
        if( file.size() > ext.size() + 1 && file[0] == '#' &&
            file.compare( file.size() - ext.size(), ext.size(), ext ) == 0 ) {
            digits = file.substr( 1, file.size() - ext.size() - 1 );
            break;
        }
    }
    if( digits.empty() || digits.size() % 4 != 0 || digits.size() > 4 * ( ( max_name_bytes + 2 ) / 3 ) ) {
        return "";
    }
    const size_t pad = digits.back() != '=' ? 0 : digits[digits.size() - 2] == '=' ? 2 : 1;
    digits.resize( digits.size() - pad );
    std::string out;
    uint32_t acc = 0;
    int bits = 0;
    for( const char ch : digits ) {
        const int v = base64_digit( ch );
        if( v < 0 ) {
            return "";
        }
        acc = ( ( acc << 6 ) | static_cast<uint32_t>( v ) ) & 0xffffff;
        bits += 6;
        if( bits >= 8 ) {
            bits -= 8;
            out += static_cast<char>( ( acc >> bits ) & 0xff );
        }
    }
    // Leftover bits must be zero, or the name encodes to a different file.
    if( ( acc & ( ( 1u << bits ) - 1 ) ) != 0 ) {
        return "";
    }
    return save_name_ok( out ) ? out : "";
}

// Names of the entries in `dir` of exactly `type` (symlinks and junctions are not followed), at most
// max_dir_entries looked at; names that don't convert to UTF-8 are skipped. Empty if `dir` can't be read.
std::vector<std::string> dir_names( const fs::path &dir, fs::file_type type )
{
    std::vector<std::string> out;
    std::error_code ec;
    fs::directory_iterator it( dir, fs::directory_options::skip_permission_denied, ec );
    for( size_t n = 0; !ec && it != fs::directory_iterator() && n < max_dir_entries; it.increment( ec ), n++ ) {
        std::error_code ec2;
        if( it->symlink_status( ec2 ).type() != type || ec2 ) {
            continue;
        }
        try {
            out.push_back( it->path().filename().u8string() );
        } catch( const std::exception & ) {
            // not valid UTF-16
        }
    }
    return out;
}

// What CDDA counts as a world folder (worldfactory::init): one holding its options or a master save.
bool is_world_dir( const fs::path &dir )
{
    std::error_code ec;
    if( fs::symlink_status( dir, ec ).type() != fs::file_type::directory ) {
        return false;
    }
    for( const char *f : { "worldoptions.json", "master.gsav" } ) {
        if( fs::symlink_status( dir / f, ec ).type() == fs::file_type::regular ) {
            return true;
        }
    }
    return false;
}

void sort_and_cap( std::vector<std::string> &v )
{
    std::sort( v.begin(), v.end() );
    v.erase( std::unique( v.begin(), v.end() ), v.end() );
    if( v.size() > max_listed ) {
        v.resize( max_listed );
    }
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

namespace
{
std::string start_impl( const std::string &data_dir, const std::string &user_dir, const std::string &world,
                        const std::string &save, bool fresh_world, bool chargen, bool world_setup, bool replace_world,
                        bool range = false );
} // namespace

std::string start( const std::string &data_dir, const std::string &user_dir, const std::string &world,
                   const std::string &save )
{
    // A new game here may replace FP3D's own throwaway world of that name (--quick, the tests); nothing else.
    return start_impl( data_dir, user_dir, world, save, true, false, false, true );
}

std::string start_new_game( const std::string &data_dir, const std::string &user_dir, const std::string &world,
                            bool fresh_world, bool chargen, bool world_setup )
{
    // A fresh world from the menu never replaces one: the game thread refuses a name in use (any case).
    return start_impl( data_dir, user_dir, world, "", fresh_world, chargen, world_setup && fresh_world, false );
}

std::string start_test_range( const std::string &data_dir, const std::string &user_dir )
{
    return start_impl( data_dir, user_dir, "fp3d-range", "", true, false, false, true, true );
}

namespace
{
std::string start_impl( const std::string &data_dir, const std::string &user_dir, const std::string &world,
                        const std::string &save, bool fresh_world, bool chargen, bool world_setup, bool replace_world,
                        bool range )
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
    // A load needs saves that are already there: don't make the folder for one.
    const std::string user = checked_dir( user_dir, save.empty(), why );
    if( user.empty() ) {
        return why;
    }
    if( save.empty() && fresh_world ) {
        if( !new_world_name_ok( world ) ) {
            return "bad world name";
        }
        // fp3d- names are kept for quick starts and tests, which replace only worlds they made (fp3d/boot.h).
        if( fp3d::reserved_world_name( world ) && !( replace_world && fp3d::replaceable_world( world ) ) ) {
            return "world names starting with fp3d- are kept for quick starts and tests";
        }
    } else if( save.empty() ) {
        // A new character in an existing world: only a world list_worlds offers.
        if( !world_name_ok( world ) ) {
            return "bad world name";
        }
        const std::vector<std::string> worlds = list_worlds( user, why );
        if( std::find( worlds.begin(), worlds.end(), world ) == worlds.end() ) {
            return "no world " + world;
        }
    } else {
        if( !world_name_ok( world ) ) {
            return "bad world name";
        }
        if( !save_name_ok( save ) ) {
            return "bad save name";
        }
        // Only what list_saves offers; the game thread checks again against CDDA's own world list.
        const std::vector<std::string> saves = list_saves( user, world, why );
        if( std::find( saves.begin(), saves.end(), save ) == saves.end() ) {
            return "no save " + save + " in world " + world;
        }
    }
    // Another process playing this world (or deleting from it) refuses the start; without a lock file at all (a
    // folder that can't be written) the game still starts, unguarded.
    {
        os_lock l = no_lock;
        if( take_lock( std::filesystem::u8path( user ), range ? "fp3d-range" : world, l ) ==
            lock_result::held_elsewhere ) {
            return "that world is in use by another game";
        }
        std::lock_guard<std::mutex> lk( game_lock_mutex );
        game_lock = l;
    }
    boot_data_dir = data;
    boot_user_dir = user;
    boot_world = world;
    boot_save = save;
    boot_fresh_world = fresh_world;
    boot_replace_world = replace_world && fp3d::replaceable_world( world );
    boot_chargen = chargen;
    boot_world_setup = world_setup;
    boot_range = range;
    fp3d::set_active( true );
    fp3d::set_events_enabled( true );
    fp3d::begin_boot();
    {
        std::lock_guard<std::mutex> lk( watch_mutex );
        watch_steps = 0;
        watch_since = std::chrono::steady_clock::time_point();
    }
    boot_abandoned.store( false );
    set_state( state::booting );
#if defined(_WIN32)
    sim_thread = reinterpret_cast<HANDLE>( _beginthreadex( nullptr, sim_stack_bytes, sim_entry, nullptr,
                                           STACK_SIZE_PARAM_IS_A_RESERVATION, nullptr ) );
    if( sim_thread == nullptr ) {
        set_state( state::failed );
        set_error( "cannot create the game thread" );
        release_game_lock();
        sim_done.store( true );
        return "cannot create the game thread";
    }
#else
    pthread_attr_t attr;
    bool started = pthread_attr_init( &attr ) == 0;
    if( started ) {
        started = pthread_attr_setstacksize( &attr, sim_stack_bytes ) == 0 &&
                  pthread_create( &sim_thread, &attr, sim_entry, nullptr ) == 0;
        pthread_attr_destroy( &attr );
    }
    if( !started ) {
        set_state( state::failed );
        set_error( "cannot create the game thread" );
        release_game_lock();
        sim_done.store( true );
        return "cannot create the game thread";
    }
    sim_thread_running = true;
#endif
    return "";
}

} // namespace

void stop()
{
    fp3d::shutdown();
    // A game thread stuck in a boot the watchdog gave up on may never return: wait for it only so long, then
    // leave it to the process's exit (its own teardown can't run then).
    const bool abandoned = boot_abandoned.load();
#if defined(_WIN32)
    if( sim_thread != nullptr ) {
        const DWORD ms = abandoned ? static_cast<DWORD>( abandoned_join_limit.count() * 1000 ) : INFINITE;
        WaitForSingleObject( sim_thread, ms );
        CloseHandle( sim_thread );
        sim_thread = nullptr;
    }
#else
    if( sim_thread_running ) {
        if( abandoned ) {
#if defined(__GLIBC__)
            timespec until{};
            clock_gettime( CLOCK_REALTIME, &until );
            until.tv_sec += abandoned_join_limit.count();
            if( pthread_timedjoin_np( sim_thread, nullptr, &until ) != 0 ) {
                pthread_detach( sim_thread );
            }
#else
            pthread_detach( sim_thread );
#endif
        } else {
            pthread_join( sim_thread, nullptr );
        }
        sim_thread_running = false;
    }
#endif
    finish( state::stopped, "" );
}

state get_state()
{
    check_boot_stall();
    return static_cast<state>( cur_state.load() );
}

std::string error()
{
    std::lock_guard<std::mutex> lk( error_mutex );
    return error_text;
}

std::vector<std::string> list_worlds( const std::string &user_dir, std::string &why )
{
    std::vector<std::string> out;
    const fs::path user = checked_path( user_dir, why );
    if( user.empty() ) {
        return out;
    }
    const fs::path saves = user / "save";
    for( std::string &name : dir_names( saves, fs::file_type::directory ) ) {
        if( world_name_ok( name ) && is_world_dir( saves / fs::u8path( name ) ) ) {
            out.push_back( std::move( name ) );
        }
    }
    sort_and_cap( out );
    return out;
}

std::vector<std::string> list_saves( const std::string &user_dir, const std::string &world, std::string &why )
{
    std::vector<std::string> out;
    const fs::path user = checked_path( user_dir, why );
    if( user.empty() ) {
        return out;
    }
    if( !world_name_ok( world ) ) {
        why = "bad world name";
        return out;
    }
    const fs::path dir = user / "save" / fs::u8path( world );
    if( !is_world_dir( dir ) ) {
        return out;
    }
    for( const std::string &file : dir_names( dir, fs::file_type::regular ) ) {
        std::string name = save_name_of_file( file );
        if( !name.empty() ) {
            out.push_back( std::move( name ) );
        }
    }
    sort_and_cap( out );
    return out;
}

namespace
{
// Removes `p` and, when it is a real folder, everything in it; a link or junction is removed itself, never
// followed. Counts each entry against `budget`. False when anything is left.
bool remove_tree( const fs::path &p, size_t &budget, int depth )
{
    std::error_code ec;
    const fs::file_type type = fs::symlink_status( p, ec ).type();
    if( type == fs::file_type::not_found ) {
        return true;
    }
    if( ec ) {
        return false;
    }
    bool ok = true;
    if( type == fs::file_type::directory ) {
        if( depth >= max_delete_depth ) {
            return false;
        }
        std::vector<fs::path> inside;
        fs::directory_iterator it( p, ec );
        for( ; !ec && it != fs::directory_iterator() && inside.size() < budget; it.increment( ec ) ) {
            inside.push_back( it->path() );
        }
        ok = !ec;
        for( const fs::path &q : inside ) {
            ok = remove_tree( q, budget, depth + 1 ) && ok;
        }
    }
    if( budget == 0 ) {
        return false;
    }
    budget--;
    fs::remove( p, ec );
    return ok && !ec;
}

bool is_save_file( const std::string &name )
{
    for( const std::string ext : { ".sav", ".sav.zzip" } ) {
        if( name.size() > ext.size() && name.compare( name.size() - ext.size(), ext.size(), ext ) == 0 ) {
            return true;
        }
    }
    return false;
}

struct lock_guard_os {
    os_lock l = no_lock;
    ~lock_guard_os() {
        release_lock( l );
    }
};
} // namespace

std::string delete_save( const std::string &user_dir, const std::string &world, const std::string &save,
                         bool delete_empty_world )
{
    if( get_state() != state::idle && !sim_done.load() ) {
        return "not while a game runs";
    }
    std::string why;
    const fs::path user = checked_path( user_dir, why );
    if( user.empty() ) {
        return why;
    }
    if( !world_name_ok( world ) ) {
        return "bad world name";
    }
    if( !save_name_ok( save ) ) {
        return "bad save name";
    }
    // The world folder's own spelling (the lock's name depends on it), in a save folder that is no link.
    const std::vector<std::string> worlds = list_worlds( user_dir, why );
    if( std::find( worlds.begin(), worlds.end(), world ) == worlds.end() ) {
        return "no world " + world;
    }
    std::error_code sec;
    if( fs::symlink_status( user / "save", sec ).type() != fs::file_type::directory ) {
        return "the save folder is a link";
    }
    const std::vector<std::string> saves = list_saves( user_dir, world, why );
    if( std::find( saves.begin(), saves.end(), save ) == saves.end() ) {
        return "no save " + save + " in world " + world;
    }
    const fs::path dir = user / "save" / fs::u8path( world );
    // CDDA names everything it keeps for a character <base>.<something> after its save file <base>.sav[.zzip]
    // (base: '#' and base64, no '.'): the log, map memory folder, seen overmaps, zones, auto-pickup rules, ...
    std::string base;
    for( const std::string &file : dir_names( dir, fs::file_type::regular ) ) {
        if( save_name_of_file( file ) == save ) {
            base = file.substr( 0, file.find( '.' ) );
            break;
        }
    }
    if( base.empty() ) {
        return "no save " + save + " in world " + world;
    }
    lock_guard_os held;
    switch( take_lock( user, world, held.l ) ) {
        case lock_result::held_elsewhere:
            return "that world is in use by another game";
        case lock_result::failed:
            return "cannot check whether another game uses that world";
        case lock_result::taken:
            break;
    }
    const std::string prefix = base + ".";
    std::vector<std::string> mine;
    std::error_code ec;
    fs::directory_iterator it( dir, ec );
    for( size_t n = 0; !ec && it != fs::directory_iterator() && n < max_delete_entries; it.increment( ec ), n++ ) {
        try {
            std::string name = it->path().filename().u8string();
            if( name.compare( 0, prefix.size(), prefix ) == 0 ) {
                mine.push_back( std::move( name ) );
            }
        } catch( const std::exception & ) {
            // not valid UTF-16: not CDDA's
        }
    }
    if( ec ) {
        return "cannot read the world's folder";
    }
    // The save file last: if anything else stays, the character is still listed and can be deleted again.
    std::stable_partition( mine.begin(), mine.end(), []( const std::string & n ) {
        return !is_save_file( n );
    } );
    size_t budget = max_delete_entries;
    std::vector<std::string> left;
    for( const std::string &name : mine ) {
        if( !remove_tree( dir / fs::u8path( name ), budget, 0 ) ) {
            left.push_back( name );
        }
    }
    if( !left.empty() ) {
        std::string list;
        for( size_t i = 0; i < left.size() && i < 4; i++ ) {
            list += ( i == 0 ? "" : ", " ) + left[i];
        }
        return "could not delete " + list + ( left.size() > 4 ? " and " + std::to_string( left.size() - 4 ) +
                                              " more" : "" );
    }
    if( delete_empty_world ) {
        // Any save file at all keeps the world (also ones list_saves doesn't show), and so does a folder that
        // couldn't be read to the end.
        bool keep = false;
        size_t n = 0;
        fs::directory_iterator w( dir, ec );
        for( ; !ec && !keep && w != fs::directory_iterator() && n < max_delete_entries; w.increment( ec ), n++ ) {
            try {
                keep = is_save_file( w->path().filename().u8string() );
            } catch( const std::exception & ) {
                keep = true;
            }
        }
        if( !keep && !ec && w == fs::directory_iterator() ) {
            budget = max_delete_entries;
            if( !remove_tree( dir, budget, 0 ) ) {
                return "the character is deleted, but the world's folder could not be removed completely";
            }
        }
    }
    return "";
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
