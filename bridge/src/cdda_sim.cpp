#include "cdda_sim.h"

#include <algorithm>
#include <atomic>
#include <climits>
#include <cstdlib>
#include <cmath>
#include <cstdint>
#include <exception>
#include <iterator>
#include <optional>
#include <string>
#include <vector>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3i.hpp>

#include "fp3d/bridge.h"
#include "fp3d/cheats.h"
#include "fp3d/events.h"
#include "fp3d/held.h"
#include "fp3d/test_range.h"
#include "sim_session.h"

using godot::Array;
using godot::Dictionary;
using godot::String;
using godot::Variant;
using godot::Vector2;
using godot::Vector3i;

namespace
{

// Answers come from scripts: anything bigger than this is not a real answer.
constexpr size_t max_action_bytes = 64;
// Absolute squares stay far inside this (the overmap grid is much smaller).
constexpr int max_abs_coord = 1 << 26;

std::atomic<uint64_t> events_dropped{ 0 };

std::string to_std( const String &s )
{
    const godot::CharString cs = s.utf8();
    return std::string( cs.get_data(), static_cast<size_t>( cs.length() ) );
}

String to_godot( const std::string &s )
{
    return String::utf8( s.data(), static_cast<int64_t>( s.size() ) );
}

Vector3i to_vec( const fp3d::ui_point &p )
{
    return Vector3i( p.x, p.y, p.z );
}

Dictionary request_dict( const fp3d::ui_request &r )
{
    Dictionary d;
    d["id"] = static_cast<int64_t>( r.id );
    d["kind"] = String( fp3d::kind_name( r.kind ) );
    d["context"] = to_godot( r.context );
    d["title"] = to_godot( r.title );
    d["text"] = to_godot( r.text );
    Array entries;
    for( const fp3d::ui_entry &e : r.entries ) {
        Dictionary ed;
        ed["id"] = e.id;
        ed["label"] = to_godot( e.label );
        ed["enabled"] = e.enabled;
        ed["description"] = to_godot( e.description );
        entries.push_back( ed );
    }
    d["entries"] = entries;
    godot::PackedStringArray actions;
    for( const std::string &a : r.actions ) {
        actions.push_back( to_godot( a ) );
    }
    d["actions"] = actions;
    d["allow_cancel"] = r.allow_cancel;
    d["max_len"] = r.max_len;
    d["mode"] = to_godot( r.mode );
    d["status"] = to_godot( r.status );
    d["origin"] = to_vec( r.origin );
    d["cursor"] = to_vec( r.cursor );
    d["range"] = r.range;
    d["allow_vertical"] = r.allow_vertical;
    Array candidates;
    for( const fp3d::ui_point &p : r.candidates ) {
        candidates.push_back( to_vec( p ) );
    }
    d["candidates"] = candidates;
    d["timed"] = r.timed;
    d["turn"] = static_cast<int64_t>( r.turn );
    d["paused"] = r.paused;
    d["pause_reason"] = to_godot( r.pause_reason );
    // Client-flown shots (fp3d/shot.h): a fire-mode target request's spread, and a shot request's rolled error.
    const auto positive = []( float v ) {
        return std::isfinite( v ) && v > 0.0f;
    };
    if( r.kind == fp3d::request_kind::target ) {
        if( positive( r.dispersion ) ) {
            d["dispersion"] = r.dispersion;
        }
        if( positive( r.dispersion_typical ) ) {
            d["dispersion_typical"] = r.dispersion_typical;
        }
        d["weapon_wielded"] = r.weapon_wielded;
    } else if( r.kind == fp3d::request_kind::shot ) {
        d["shot_error"] = std::isfinite( r.shot_error ) ? r.shot_error : 0.0f;
        d["shot_angle"] = std::isfinite( r.shot_angle ) ? r.shot_angle : 0.0f;
        d["dispersion"] = std::isfinite( r.dispersion ) ? r.dispersion : 0.0f;
    }
    return d;
}

const char *event_kind_name( fp3d::event_kind k )
{
    static const char *const names[] = { "sound", "message", "attack", "damage", "projectile", "explosion",
                                         "death", "anim", "turn_end"
                                       };
    const size_t i = static_cast<size_t>( k );
    return i < std::size( names ) ? names[i] : "unknown";
}

Dictionary event_dict( const fp3d::event &e )
{
    Dictionary d;
    d["kind"] = String( event_kind_name( e.kind ) );
    d["turn"] = static_cast<int64_t>( e.turn );
    d["seq"] = static_cast<int64_t>( e.seq );
    d["uid"] = static_cast<int64_t>( e.uid );
    d["other"] = static_cast<int64_t>( e.other );
    d["pos"] = to_vec( e.pos );
    d["amount"] = e.amount;
    d["heard"] = e.heard;
    d["type"] = static_cast<int64_t>( e.type );
    d["detail"] = static_cast<int64_t>( e.detail );
    d["text"] = to_godot( e.text );
    Array path;
    for( const fp3d::ui_point &p : e.path ) {
        path.push_back( to_vec( p ) );
    }
    d["path"] = path;
    return d;
}

// Optional typed field: true if absent or of `type`; `out` gets it when present.
bool field( const Dictionary &d, const char *key, Variant::Type type, Variant &out )
{
    if( !d.has( key ) ) {
        return true;
    }
    out = d[key];
    return out.get_type() == type;
}

} // namespace

void CddaSim::_bind_methods()
{
    using godot::ClassDB;
    using godot::D_METHOD;
    ClassDB::bind_method( D_METHOD( "start", "data_dir", "user_dir", "world" ), &CddaSim::start );
    ClassDB::bind_method( D_METHOD( "start_new_game", "data_dir", "user_dir", "world", "fresh_world", "chargen", "world_setup" ),
                          &CddaSim::start_new_game, DEFVAL( false ) );
    ClassDB::bind_method( D_METHOD( "start_load", "data_dir", "user_dir", "world", "save" ), &CddaSim::start_load );
    ClassDB::bind_method( D_METHOD( "list_worlds", "user_dir" ), &CddaSim::list_worlds );
    ClassDB::bind_method( D_METHOD( "list_saves", "user_dir", "world" ), &CddaSim::list_saves );
    ClassDB::bind_method( D_METHOD( "stop" ), &CddaSim::stop );
    ClassDB::bind_method( D_METHOD( "get_state" ), &CddaSim::get_state );
    ClassDB::bind_method( D_METHOD( "get_error" ), &CddaSim::get_error );
    ClassDB::bind_method( D_METHOD( "get_request" ), &CddaSim::get_request );
    ClassDB::bind_method( D_METHOD( "answer", "answer" ), &CddaSim::answer );
    ClassDB::bind_method( D_METHOD( "queue_action", "action" ), &CddaSim::queue_action );
    ClassDB::bind_method( D_METHOD( "queue_item_action", "action" ), &CddaSim::queue_item_action );
    ClassDB::bind_method( D_METHOD( "use_stairs", "pos", "dir" ), &CddaSim::use_stairs );
    ClassDB::bind_method( D_METHOD( "clear_actions" ), &CddaSim::clear_actions );
    ClassDB::bind_method( D_METHOD( "get_queued_actions" ), &CddaSim::get_queued_actions );
    ClassDB::bind_method( D_METHOD( "get_snapshot_seq" ), &CddaSim::get_snapshot_seq );
    ClassDB::bind_method( D_METHOD( "get_snapshot_json", "z_below", "z_above" ), &CddaSim::get_snapshot_json );
    ClassDB::bind_method( D_METHOD( "get_id_tables_json" ), &CddaSim::get_id_tables_json );
    ClassDB::bind_method( D_METHOD( "drain_events" ), &CddaSim::drain_events );
    ClassDB::bind_method( D_METHOD( "get_events_dropped" ), &CddaSim::get_events_dropped );
    ClassDB::bind_method( D_METHOD( "get_clock" ), &CddaSim::get_clock );
    ClassDB::bind_method( D_METHOD( "set_real_time", "on" ), &CddaSim::set_real_time );
    ClassDB::bind_method( D_METHOD( "set_timescale", "scale" ), &CddaSim::set_timescale );
    ClassDB::bind_method( D_METHOD( "set_paused", "on" ), &CddaSim::set_paused );
    ClassDB::bind_method( D_METHOD( "interrupt" ), &CddaSim::interrupt );
    ClassDB::bind_method( D_METHOD( "save_game", "only_if_changed" ), &CddaSim::save_game, DEFVAL( false ) );
    ClassDB::bind_method( D_METHOD( "get_save_status" ), &CddaSim::get_save_status );
    ClassDB::bind_method( D_METHOD( "get_held" ), &CddaSim::get_held );
    ClassDB::bind_method( D_METHOD( "set_auto_pause", "on" ), &CddaSim::set_auto_pause );
    ClassDB::bind_method( D_METHOD( "set_cheat", "name", "on" ), &CddaSim::set_cheat );
    ClassDB::bind_method( D_METHOD( "set_cheats_allowed", "on" ), &CddaSim::set_cheats_allowed );
    ClassDB::bind_method( D_METHOD( "get_cheats" ), &CddaSim::get_cheats );
    ClassDB::bind_method( D_METHOD( "give_test_kit" ), &CddaSim::give_test_kit );
    ClassDB::bind_method( D_METHOD( "start_test_range", "data_dir", "user_dir" ), &CddaSim::start_test_range );
    ClassDB::bind_method( D_METHOD( "range_spawn_item", "itype", "count", "pos" ), &CddaSim::range_spawn_item );
    ClassDB::bind_method( D_METHOD( "range_spawn_monster", "id", "pos" ), &CddaSim::range_spawn_monster );
    ClassDB::bind_method( D_METHOD( "range_teleport", "zone" ), &CddaSim::range_teleport );
    ClassDB::bind_method( D_METHOD( "range_set_time", "minute" ), &CddaSim::range_set_time );
    ClassDB::bind_method( D_METHOD( "range_advance", "minutes" ), &CddaSim::range_advance );
    ClassDB::bind_method( D_METHOD( "range_set_ai_frozen", "on" ), &CddaSim::range_set_ai_frozen );
    ClassDB::bind_method( D_METHOD( "range_heal" ), &CddaSim::range_heal );
    ClassDB::bind_method( D_METHOD( "get_range_info" ), &CddaSim::get_range_info );
    ClassDB::bind_method( D_METHOD( "match_recipes", "container" ), &CddaSim::match_recipes );
    ClassDB::bind_method( D_METHOD( "take_query_result", "id" ), &CddaSim::take_query_result );
}

void CddaSim::stop_session()
{
    fp3d_session::stop();
}

String CddaSim::start( const String &data_dir, const String &user_dir, const String &world )
{
    try {
        return to_godot( fp3d_session::start( to_std( data_dir ), to_std( user_dir ), to_std( world ) ) );
    } catch( const std::exception &e ) {
        return to_godot( std::string( "start failed: " ) + e.what() );
    }
}

String CddaSim::start_new_game( const String &data_dir, const String &user_dir, const String &world,
                                bool fresh_world, bool chargen, bool world_setup )
{
    try {
        return to_godot( fp3d_session::start_new_game( to_std( data_dir ), to_std( user_dir ), to_std( world ),
                         fresh_world, chargen, world_setup ) );
    } catch( const std::exception &e ) {
        return to_godot( std::string( "start failed: " ) + e.what() );
    }
}

String CddaSim::start_load( const String &data_dir, const String &user_dir, const String &world,
                            const String &save )
{
    if( save.is_empty() ) {
        return "no save given";
    }
    try {
        return to_godot( fp3d_session::start( to_std( data_dir ), to_std( user_dir ), to_std( world ),
                                              to_std( save ) ) );
    } catch( const std::exception &e ) {
        return to_godot( std::string( "start failed: " ) + e.what() );
    }
}

namespace
{
godot::PackedStringArray to_names( const std::vector<std::string> &names, const std::string &why,
                                   const char *what )
{
    if( !why.empty() ) {
        godot::UtilityFunctions::push_error( String( "CddaSim." ) + what + ": " + to_godot( why ) );
    }
    godot::PackedStringArray out;
    for( const std::string &n : names ) {
        out.push_back( to_godot( n ) );
    }
    return out;
}
} // namespace

godot::PackedStringArray CddaSim::list_worlds( const String &user_dir ) const
{
    std::string why;
    try {
        return to_names( fp3d_session::list_worlds( to_std( user_dir ), why ), why, "list_worlds" );
    } catch( const std::exception &e ) {
        return to_names( {}, e.what(), "list_worlds" );
    }
}

godot::PackedStringArray CddaSim::list_saves( const String &user_dir, const String &world ) const
{
    std::string why;
    try {
        return to_names( fp3d_session::list_saves( to_std( user_dir ), to_std( world ), why ), why,
                         "list_saves" );
    } catch( const std::exception &e ) {
        return to_names( {}, e.what(), "list_saves" );
    }
}

void CddaSim::stop()
{
    fp3d_session::stop();
}

String CddaSim::get_state() const
{
    return String( fp3d_session::state_name( fp3d_session::get_state() ) );
}

String CddaSim::get_error() const
{
    return to_godot( fp3d_session::error() );
}

Dictionary CddaSim::get_request() const
{
    const std::optional<fp3d::ui_request> r = fp3d::wait_request( 0 );
    return r ? request_dict( *r ) : Dictionary();
}

bool CddaSim::answer( const Dictionary &d )
{
    fp3d::ui_answer a;
    Variant v;
    if( !d.has( "id" ) || !field( d, "id", Variant::INT, v ) || static_cast<int64_t>( v ) < 1 ) {
        return false;
    }
    a.id = static_cast<uint64_t>( static_cast<int64_t>( v ) );
    if( !field( d, "cancel", Variant::BOOL, v ) ) {
        return false;
    }
    a.cancel = d.has( "cancel" ) && static_cast<bool>( v );
    if( !field( d, "action", Variant::STRING, v ) ) {
        return false;
    }
    if( d.has( "action" ) ) {
        a.action = fp3d::sanitize_text( to_std( v ), max_action_bytes );
    }
    if( !field( d, "entry", Variant::INT, v ) ) {
        return false;
    }
    if( d.has( "entry" ) ) {
        a.entry = static_cast<int>( std::clamp<int64_t>( v, -1, INT_MAX ) );
    }
    if( !field( d, "text", Variant::STRING, v ) ) {
        return false;
    }
    if( d.has( "text" ) ) {
        // The sim caps it again by request kind (only chargen takes the larger cap).
        a.text = fp3d::sanitize_text( to_std( v ), fp3d::max_answer_json );
    }
    if( !field( d, "picks", Variant::ARRAY, v ) ) {
        return false;
    }
    if( d.has( "picks" ) ) {
        const Array picks = v;
        if( picks.size() > static_cast<int64_t>( fp3d::max_answer_picks ) ) {
            return false;
        }
        for( int64_t i = 0; i < picks.size(); ++i ) {
            if( picks[i].get_type() != Variant::ARRAY ) {
                return false;
            }
            const Array pair = picks[i];
            if( pair.size() != 2 || pair[0].get_type() != Variant::INT || pair[1].get_type() != Variant::INT ) {
                return false;
            }
            a.picks.emplace_back( static_cast<int>( std::clamp<int64_t>( pair[0], 0, INT_MAX ) ),
                                  static_cast<int>( std::clamp<int64_t>( pair[1], 0, INT_MAX ) ) );
        }
    }
    if( !field( d, "pos", Variant::VECTOR3I, v ) ) {
        return false;
    }
    if( d.has( "pos" ) ) {
        const Vector3i p = v;
        a.pos = fp3d::ui_point{ std::clamp( p.x, -max_abs_coord, max_abs_coord ),
                                std::clamp( p.y, -max_abs_coord, max_abs_coord ),
                                std::clamp( p.z, -max_abs_coord, max_abs_coord ) };
    }
    if( !field( d, "shot", Variant::DICTIONARY, v ) ) {
        return false;
    }
    if( d.has( "shot" ) ) {
        // {end: Vector3i, hit_uid: int, part: String, quality: float}; the sim checks it again.
        const Dictionary s = v;
        Variant e;
        Variant u;
        Variant p;
        Variant q;
        if( !s.has( "end" ) || !field( s, "end", Variant::VECTOR3I, e ) || !field( s, "hit_uid", Variant::INT, u ) ||
            !field( s, "part", Variant::STRING, p ) || !field( s, "quality", Variant::FLOAT, q ) ) {
            return false;
        }
        fp3d::shot_answer sa;
        const Vector3i end = e;
        sa.end = fp3d::ui_point{ std::clamp( end.x, -max_abs_coord, max_abs_coord ),
                                 std::clamp( end.y, -max_abs_coord, max_abs_coord ),
                                 std::clamp( end.z, -max_abs_coord, max_abs_coord ) };
        sa.hit_uid = s.has( "hit_uid" ) ? static_cast<uint64_t>( std::max<int64_t>( u, 0 ) ) : 0;
        sa.part = s.has( "part" ) ? fp3d::sanitize_text( to_std( p ), 64 ) : std::string();
        const double quality = s.has( "quality" ) ? static_cast<double>( q ) : 0.3;
        if( !std::isfinite( quality ) ) {
            return false;
        }
        sa.quality = static_cast<float>( std::clamp( quality, 0.0, 0.99 ) );
        // `fly` (target answers): a bool; anything else counts as false.
        sa.fly = s.has( "fly" ) && s["fly"].get_type() == Variant::BOOL && static_cast<bool>( s["fly"] );
        a.shot = sa;
    }
    fp3d::answer( std::move( a ) );
    return true;
}

bool CddaSim::queue_action( const String &action )
{
    const std::string s = fp3d::sanitize_text( to_std( action ), max_action_bytes );
    return !s.empty() && fp3d::queue_action( s );
}

// One item, no menus (fp3d/item_hands.h, contracts/bridge_api.md). Every key is checked for type and range; a
// request with anything wrong or out of range is refused whole (false), as is one the queue has no room for.
bool CddaSim::queue_item_action( const Dictionary &d )
{
    fp3d::item_action a;
    Variant v;
    if( !d.has( "op" ) || !field( d, "op", Variant::STRING, v ) ) {
        return false;
    }
    const String op = v;
    if( op == "take" ) {
        a.op = fp3d::item_op::take;
    } else if( op == "put" ) {
        a.op = fp3d::item_op::put;
    } else if( op == "drop" ) {
        a.op = fp3d::item_op::drop;
    } else if( op == "unload" ) {
        a.op = fp3d::item_op::unload;
    } else if( op == "reload" ) {
        a.op = fp3d::item_op::reload;
    } else if( op == "clear" ) {
        a.op = fp3d::item_op::clear;
    } else {
        return false;
    }
    const auto ref = [&d]( const char *uid_key, const char *type_key, fp3d::item_ref & r ) {
        Variant u;
        Variant t;
        if( !d.has( uid_key ) || !d.has( type_key ) || !field( d, uid_key, Variant::INT, u ) ||
            !field( d, type_key, Variant::INT, t ) ) {
            return false;
        }
        const int64_t uid = u;
        const int64_t type = t;
        if( uid <= 0 || uid > static_cast<int64_t>( fp3d::max_item_uid ) || type <= 0 || type > INT32_MAX ) {
            return false;
        }
        r.uid = static_cast<uint64_t>( uid );
        r.type = static_cast<uint32_t>( type );
        return true;
    };
    if( !ref( "item", "type", a.item ) ) {
        return false;
    }
    if( !field( d, "pos", Variant::VECTOR3I, v ) ) {
        return false;
    }
    if( d.has( "pos" ) ) {
        const Vector3i p = v;
        const auto out = []( int32_t c ) {
            return c < -max_abs_coord || c > max_abs_coord;
        };
        if( out( p.x ) || out( p.y ) || out( p.z ) ) {
            return false;
        }
        a.pos = fp3d::ui_point{ p.x, p.y, p.z };
    } else if( a.op == fp3d::item_op::take || a.op == fp3d::item_op::drop ) {
        return false;
    }
    if( !field( d, "hand", Variant::STRING, v ) ) {
        return false;
    }
    if( d.has( "hand" ) ) {
        const String hand = v;
        if( hand == "pack" ) {
            a.hand = fp3d::item_hand::pack;
        } else if( hand == "main" ) {
            a.hand = fp3d::item_hand::main;
        } else if( hand == "off" ) {
            a.hand = fp3d::item_hand::off;
        } else {
            return false;
        }
    }
    if( a.op == fp3d::item_op::reload && !ref( "container", "container_type", a.container ) ) {
        return false;
    }
    if( a.op == fp3d::item_op::put ) {
        if( !ref( "container", "container_type", a.container ) || !field( d, "pocket", Variant::INT, v ) ) {
            return false;
        }
        if( d.has( "pocket" ) ) {
            const int64_t pocket = v;
            if( pocket < -1 || pocket > fp3d::max_item_pocket ) {
                return false;
            }
            a.pocket = static_cast<int>( pocket );
        }
    }
    if( !field( d, "spot", Variant::VECTOR2, v ) ) {
        return false;
    }
    if( d.has( "spot" ) ) {
        const Vector2 s = v;
        if( !std::isfinite( s.x ) || !std::isfinite( s.y ) || s.x < 0 || s.x > 1 || s.y < 0 || s.y > 1 ) {
            return false;
        }
        const auto permille = []( real_t f ) {
            return static_cast<uint16_t>( std::min<int>( fp3d::spot_scale - 1, static_cast<int>( f * fp3d::spot_scale ) ) );
        };
        a.has_spot = true;
        a.spot_x = permille( s.x );
        a.spot_y = permille( s.y );
    }
    return fp3d::queue_item_action( a );
}

bool CddaSim::use_stairs( const Vector3i &pos, int64_t dir )
{
    if( dir != 1 && dir != -1 ) {
        return false;
    }
    fp3d::stairs_action a;
    a.pos = fp3d::ui_point{ pos.x, pos.y, pos.z };
    a.dir = static_cast<int>( dir );
    return fp3d::queue_stairs_action( a );   // checks the square's range and the queue
}

void CddaSim::clear_actions()
{
    fp3d::clear_actions();
}

int64_t CddaSim::get_queued_actions() const
{
    return static_cast<int64_t>( fp3d::queued_actions() );
}

int64_t CddaSim::get_snapshot_seq() const
{
    return static_cast<int64_t>( fp3d_session::snapshot_seq() );
}

String CddaSim::get_snapshot_json( int64_t z_below, int64_t z_above ) const
{
    try {
        uint64_t seq = 0;
        return to_godot( fp3d_session::snapshot_json( static_cast<int>( std::clamp<int64_t>( z_below, 0, 64 ) ),
                         static_cast<int>( std::clamp<int64_t>( z_above, 0, 64 ) ), seq ) );
    } catch( const std::exception &e ) {
        godot::UtilityFunctions::push_error( String( "CddaSim: snapshot JSON failed: " ) + e.what() );
        return String();
    }
}

String CddaSim::get_id_tables_json() const
{
    try {
        uint32_t generation = 0;
        return to_godot( fp3d_session::id_tables_json( generation ) );
    } catch( const std::exception &e ) {
        godot::UtilityFunctions::push_error( String( "CddaSim: id tables JSON failed: " ) + e.what() );
        return String();
    }
}

Array CddaSim::drain_events()
{
    std::vector<fp3d::event> evs;
    events_dropped += fp3d::drain_events( evs );
    Array out;
    for( const fp3d::event &e : evs ) {
        out.push_back( event_dict( e ) );
    }
    return out;
}

int64_t CddaSim::get_events_dropped() const
{
    return static_cast<int64_t>( events_dropped.load() );
}

Dictionary CddaSim::get_clock() const
{
    const fp3d::clock_state c = fp3d::get_clock();
    Dictionary d;
    d["real_time"] = c.mode == fp3d::clock_mode::real_time;
    d["timescale"] = c.timescale;
    d["paused"] = c.paused;
    d["auto_pause"] = c.auto_pause_hostiles;
    d["pause_reason"] = to_godot( c.pause_reason );
    return d;
}

void CddaSim::set_real_time( bool on )
{
    fp3d::set_clock_mode( on ? fp3d::clock_mode::real_time : fp3d::clock_mode::turn_based );
}

void CddaSim::set_timescale( double scale )
{
    fp3d::set_timescale( scale );
}

void CddaSim::set_paused( bool on )
{
    fp3d::set_paused( on );
}

void CddaSim::set_auto_pause( bool on )
{
    fp3d::set_auto_pause_hostiles( on );
}

void CddaSim::interrupt()
{
    fp3d::interrupt();
}

bool CddaSim::save_game( bool only_if_changed )
{
    // Only while a game runs: the sim takes it at the main loop.
    return fp3d_session::get_state() == fp3d_session::state::running && fp3d::request_save( only_if_changed );
}

// L9: what a container's contents can become (fp3d/cooking.h, contracts/bridge_api.md "Recipe queries"). Hostile
// input: every key is checked for type and range; anything wrong is refused whole (0) and nothing is posted.
int64_t CddaSim::match_recipes( const Dictionary &d )
{
    if( fp3d_session::get_state() != fp3d_session::state::running ) {
        return 0;
    }
    Variant u;
    Variant t;
    Variant p;
    if( !d.has( "uid" ) || !d.has( "type" ) || !d.has( "pos" ) || !field( d, "uid", Variant::INT, u ) ||
        !field( d, "type", Variant::INT, t ) || !field( d, "pos", Variant::VECTOR3I, p ) ) {
        return 0;
    }
    const int64_t uid = u;
    const int64_t type = t;
    const Vector3i pos = p;
    if( uid <= 0 || uid > static_cast<int64_t>( fp3d::max_item_uid ) || type <= 0 || type > INT32_MAX ||
        pos.x < -max_abs_coord || pos.x > max_abs_coord || pos.y < -max_abs_coord || pos.y > max_abs_coord ||
        pos.z < -max_abs_coord || pos.z > max_abs_coord ) {
        return 0;
    }
    const fp3d::item_ref ref{ static_cast<uint64_t>( uid ), static_cast<uint32_t>( type ) };
    return static_cast<int64_t>( fp3d::post_recipe_query( ref, fp3d::ui_point{ pos.x, pos.y, pos.z } ) );
}

String CddaSim::take_query_result( int64_t id )
{
    if( id <= 0 ) {
        return String();
    }
    const std::optional<std::string> result = fp3d::take_query_result( static_cast<uint64_t>( id ) );
    return result ? to_godot( *result ) : String();
}

bool CddaSim::set_cheat( const String &name, bool on )
{
    // Hostile input: only the exact names in fp3d/cheats.h, and only while a game runs.
    if( name.length() > 32 || fp3d_session::get_state() != fp3d_session::state::running ) {
        return false;
    }
    const std::optional<fp3d::cheat> c = fp3d::cheat_from_name( to_std( name ) );
    return c && fp3d::request_cheat( *c, on );
}

void CddaSim::set_cheats_allowed( bool on )
{
    fp3d::set_cheats_allowed( on );
}

Dictionary CddaSim::get_cheats() const
{
    const fp3d::cheats_view v = fp3d::latest_cheats();
    Dictionary on;
    for( size_t i = 0; i < fp3d::cheat_count; i++ ) {
        on[String( fp3d::cheat_name( static_cast<fp3d::cheat>( i ) ) )] = ( v.on >> i & 1U ) != 0;
    }
    Dictionary d;
    d["seq"] = static_cast<int64_t>( std::min<uint64_t>( v.seq, INT64_MAX ) );
    d["kits_given"] = static_cast<int64_t>( std::min<uint64_t>( v.kits_given, INT64_MAX ) );
    d["cheats"] = on;
    d["allowed"] = fp3d::cheats_allowed();
    return d;
}

bool CddaSim::give_test_kit()
{
    return fp3d_session::get_state() == fp3d_session::state::running && fp3d::request_test_kit();
}

String CddaSim::start_test_range( const String &data_dir, const String &user_dir )
{
    try {
        return to_godot( fp3d_session::start_test_range( to_std( data_dir ), to_std( user_dir ) ) );
    } catch( const std::exception &e ) {
        return to_godot( std::string( "start failed: " ) + e.what() );
    }
}

namespace
{
// The operation's id, 0 when refused (fp3d::request_range_op checks the rest; the game checks the operation).
int64_t queue_range( const fp3d::range_op &op )
{
    if( fp3d_session::get_state() != fp3d_session::state::running ) {
        return 0;
    }
    return static_cast<int64_t>( std::min<uint64_t>( fp3d::request_range_op( op ), INT64_MAX ) );
}

fp3d::ui_point range_square( const Vector3i &pos )
{
    return fp3d::ui_point{ pos.x, pos.y, pos.z };
}
} // namespace

int64_t CddaSim::range_spawn_item( int64_t itype, int64_t count, const Vector3i &pos )
{
    if( itype <= 0 || itype > UINT32_MAX ) {
        return 0;
    }
    fp3d::range_op op;
    op.kind = fp3d::range_op_kind::spawn_item;
    op.itype = static_cast<uint32_t>( itype );
    op.number = count;
    op.square = range_square( pos );
    return queue_range( op );
}

int64_t CddaSim::range_spawn_monster( const String &id, const Vector3i &pos )
{
    if( id.is_empty() || id.length() > static_cast<int64_t>( fp3d::max_monster_id ) ) {
        return 0;
    }
    fp3d::range_op op;
    op.kind = fp3d::range_op_kind::spawn_monster;
    op.monster = to_std( id );
    op.square = range_square( pos );
    return queue_range( op );
}

int64_t CddaSim::range_teleport( int64_t zone )
{
    fp3d::range_op op;
    op.kind = fp3d::range_op_kind::teleport;
    op.number = zone;
    return queue_range( op );
}

int64_t CddaSim::range_set_time( int64_t minute )
{
    fp3d::range_op op;
    op.kind = fp3d::range_op_kind::time_of_day;
    op.number = minute;
    return queue_range( op );
}

int64_t CddaSim::range_advance( int64_t minutes )
{
    fp3d::range_op op;
    op.kind = fp3d::range_op_kind::advance;
    op.number = minutes;
    return queue_range( op );
}

int64_t CddaSim::range_set_ai_frozen( bool on )
{
    fp3d::range_op op;
    op.kind = fp3d::range_op_kind::ai_frozen;
    op.number = on ? 1 : 0;
    return queue_range( op );
}

int64_t CddaSim::range_heal()
{
    fp3d::range_op op;
    op.kind = fp3d::range_op_kind::heal;
    return queue_range( op );
}

Dictionary CddaSim::get_range_info() const
{
    const fp3d::range_info v = fp3d::latest_range_info();
    Array zones;
    for( const fp3d::range_zone_info &z : v.zones ) {
        Dictionary d;
        d["id"] = to_godot( z.id );
        d["name"] = to_godot( z.name );
        d["kind"] = to_godot( z.kind );
        d["built"] = z.built;
        zones.push_back( d );
    }
    Array results;
    for( const fp3d::range_op_result &r : fp3d::latest_range_results() ) {
        Dictionary d;
        d["id"] = static_cast<int64_t>( std::min<uint64_t>( r.id, INT64_MAX ) );
        d["error"] = to_godot( r.error );
        results.push_back( d );
    }
    Dictionary d;
    d["seq"] = static_cast<int64_t>( std::min<uint64_t>( v.seq, INT64_MAX ) );
    d["range"] = v.range;
    d["ai_frozen"] = v.ai_frozen;
    d["zones"] = zones;
    d["zone"] = v.zone;
    d["results"] = results;
    return d;
}

Dictionary CddaSim::get_save_status() const
{
    const fp3d::save_status s = fp3d::get_save_status();
    Dictionary d;
    d["pending"] = s.pending;
    d["done"] = static_cast<int64_t>( std::min<uint64_t>( s.done, INT64_MAX ) );
    d["ok"] = s.ok;
    return d;
}

namespace
{
Dictionary hand_dict( const fp3d::hand_view &h )
{
    Dictionary d;
    if( !h.held ) {
        return d;
    }
    d["id"] = to_godot( h.id );
    d["name"] = to_godot( h.name );
    d["liquid"] = to_godot( h.liquid );
    d["ml"] = h.ml;
    d["capacity_ml"] = h.capacity_ml;
    return d;
}
} // namespace

Dictionary CddaSim::get_held() const
{
    const fp3d::held_view v = fp3d::latest_held();
    Dictionary d;
    d["seq"] = static_cast<int64_t>( std::min<uint64_t>( v.seq, INT64_MAX ) );
    d["turn"] = v.turn;
    d["main"] = hand_dict( v.main );
    d["off"] = hand_dict( v.off );
    d["activity"] = to_godot( v.activity );
    return d;
}
