#pragma once
#ifndef FP3D_BRIDGE_CDDA_SIM_H
#define FP3D_BRIDGE_CDDA_SIM_H

// The Godot side of the bridge: the CddaSim class scripts use to run and play CDDA (contracts/bridge_api.md).
// CDDA's state is global, so every CddaSim talks to the one game in the process.

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string.hpp>

class CddaSim : public godot::RefCounted
{
        GDCLASS( CddaSim, godot::RefCounted )

    protected:
        static void _bind_methods();

    public:
        // Stops the game thread (extension unload).
        static void stop_session();

        godot::String start( const godot::String &data_dir, const godot::String &user_dir,
                             const godot::String &world );
        godot::String start_load( const godot::String &data_dir, const godot::String &user_dir,
                                  const godot::String &world, const godot::String &save );
        godot::PackedStringArray list_worlds( const godot::String &user_dir ) const;
        godot::PackedStringArray list_saves( const godot::String &user_dir, const godot::String &world ) const;
        void stop();
        godot::String get_state() const;
        godot::String get_error() const;

        godot::Dictionary get_request() const;
        bool answer( const godot::Dictionary &a );
        bool queue_action( const godot::String &action );
        void clear_actions();
        int64_t get_queued_actions() const;

        int64_t get_snapshot_seq() const;
        godot::String get_snapshot_json( int64_t z_below, int64_t z_above ) const;
        godot::String get_id_tables_json() const;
        godot::Array drain_events();
        int64_t get_events_dropped() const;

        godot::Dictionary get_clock() const;
        void set_real_time( bool on );
        void set_timescale( double scale );
        void set_paused( bool on );
        void interrupt();

        bool save_game( bool only_if_changed );
        godot::Dictionary get_held() const;
        godot::Dictionary get_save_status() const;
};

#endif // FP3D_BRIDGE_CDDA_SIM_H
