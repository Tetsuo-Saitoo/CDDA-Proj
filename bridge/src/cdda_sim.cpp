#include "cdda_sim.h"

#include <algorithm>
#include <atomic>
#include <climits>
#include <cmath>
#include <exception>
#include <iterator>
#include <optional>
#include <string>
#include <vector>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/vector3i.hpp>

#include "fp3d/bridge.h"
#include "fp3d/events.h"
#include "sim_session.h"

using godot::Array;
using godot::Dictionary;
using godot::String;
using godot::Variant;
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
    ClassDB::bind_method( D_METHOD( "start_new_game", "data_dir", "user_dir", "world", "fresh_world", "chargen" ),
                          &CddaSim::start_new_game );
    ClassDB::bind_method( D_METHOD( "start_load", "data_dir", "user_dir", "world", "save" ), &CddaSim::start_load );
    ClassDB::bind_method( D_METHOD( "list_worlds", "user_dir" ), &CddaSim::list_worlds );
    ClassDB::bind_method( D_METHOD( "list_saves", "user_dir", "world" ), &CddaSim::list_saves );
    ClassDB::bind_method( D_METHOD( "stop" ), &CddaSim::stop );
    ClassDB::bind_method( D_METHOD( "get_state" ), &CddaSim::get_state );
    ClassDB::bind_method( D_METHOD( "get_error" ), &CddaSim::get_error );
    ClassDB::bind_method( D_METHOD( "get_request" ), &CddaSim::get_request );
    ClassDB::bind_method( D_METHOD( "answer", "answer" ), &CddaSim::answer );
    ClassDB::bind_method( D_METHOD( "queue_action", "action" ), &CddaSim::queue_action );
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
                                bool fresh_world, bool chargen )
{
    try {
        return to_godot( fp3d_session::start_new_game( to_std( data_dir ), to_std( user_dir ), to_std( world ),
                         fresh_world, chargen ) );
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
    fp3d::answer( std::move( a ) );
    return true;
}

bool CddaSim::queue_action( const String &action )
{
    const std::string s = fp3d::sanitize_text( to_std( action ), max_action_bytes );
    return !s.empty() && fp3d::queue_action( s );
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

void CddaSim::interrupt()
{
    fp3d::interrupt();
}
