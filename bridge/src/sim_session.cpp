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
#include <pthread.h>
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
        if( boot_range ) {
            fp3d::boot_new_game_data( boot_world, true, true, false, true );
            fp3d::boot_test_range( 1 );
            fp3d::set_cheats_allowed( true );
        } else if( boot_save.empty() ) {
            if( boot_chargen || boot_world_setup || !boot_fresh_world || !boot_replace_world ) {
                fp3d::boot_new_game_data( boot_world, boot_fresh_world, true, boot_world_setup,
                                          boot_replace_world );
                if( boot_chargen ) {
                    if( !fp3d::run_chargen() ) {
                        throw std::runtime_error( "character creation cancelled" );
                    }
                } else {
                    get_avatar().create( character_type::NOW );
                }
            } else {
                fp3d::boot_world( boot_world, true );
            }
            if( !fp3d_game_access::start_game( *g ) ) {
                throw std::runtime_error( "start_game failed" );
            }
        } else {
            fp3d::boot_saved_game( boot_world, boot_save, true );
            fp3d::reset_snapshots();
        }
        // The client reads the world while the sim waits for it, so every request comes with a fresh snapshot.
        fp3d::set_before_ask_hook( [] {
            // Test range operations first (main-loop requests only), so the snapshot shows what they did.
            fp3d::run_range_requests();
            fp3d::capture_range_info();
            fp3d::publish_snapshot( fp3d::capture_snapshot() );
            fp3d::publish_held();
        } );
        set_state( state::running );
        while( !do_turn() ) {
        }
        set_error( g->uquit == QUIT_DIED || g->uquit == QUIT_WATCH ? "the character died" :
                   g->uquit == QUIT_SAVED ? "saved and quit" : "the game ended" );
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

namespace fs = std::filesystem;

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
#if defined(_WIN32)
    if( sim_thread != nullptr ) {
        WaitForSingleObject( sim_thread, INFINITE );
        CloseHandle( sim_thread );
        sim_thread = nullptr;
    }
#else
    if( sim_thread_running ) {
        pthread_join( sim_thread, nullptr );
        sim_thread_running = false;
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
