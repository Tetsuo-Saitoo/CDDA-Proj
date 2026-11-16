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
        godot::String start_new_game( const godot::String &data_dir, const godot::String &user_dir,
                                      const godot::String &world, bool fresh_world, bool chargen,
                                      bool world_setup );
        godot::String start_load( const godot::String &data_dir, const godot::String &user_dir,
                                  const godot::String &world, const godot::String &save );
        godot::PackedStringArray list_worlds( const godot::String &user_dir ) const;
        godot::PackedStringArray list_saves( const godot::String &user_dir, const godot::String &world ) const;
        godot::String delete_save( const godot::String &user_dir, const godot::String &world,
                                   const godot::String &save, bool delete_empty_world );
        void stop();
        godot::String get_state() const;
        godot::String get_error() const;
        godot::Dictionary get_boot_info() const;

        godot::Dictionary get_request() const;
        bool answer( const godot::Dictionary &a );
        bool queue_action( const godot::String &action );
        bool queue_item_action( const godot::Dictionary &a );
        bool use_stairs( const godot::Vector3i &pos, int64_t dir );
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
        void set_auto_pause( bool on );
        void interrupt();

        bool save_game( bool only_if_changed );
        godot::Dictionary get_held() const;
        godot::Dictionary get_save_status() const;

        bool set_cheat( const godot::String &name, bool on );
        void set_cheats_allowed( bool on );
        godot::Dictionary get_cheats() const;
        godot::Array get_weather_types() const;
        bool give_test_kit();
        // The test range (contracts/bridge_api.md "Test range").
        godot::String start_test_range( const godot::String &data_dir, const godot::String &user_dir );
        int64_t range_spawn_item( int64_t itype, int64_t count, const godot::Vector3i &pos );
        int64_t range_spawn_monster( const godot::String &id, const godot::Vector3i &pos );
        int64_t range_teleport( int64_t zone );
        int64_t range_rebuild_zone( int64_t zone );
        int64_t range_set_time( int64_t minute );
        int64_t range_advance( int64_t minutes );
        int64_t range_set_ai_frozen( bool on );
        int64_t range_heal();
        godot::Dictionary get_range_info() const;
        // The teleport cheat, in any game while cheats are allowed (contracts/bridge_api.md "Cheats").
        int64_t cheat_teleport( const godot::Vector3i &pos );
        int64_t cheat_set_weather( const godot::String &id, double wind );

        int64_t match_recipes( const godot::Dictionary &container );
        godot::String take_query_result( int64_t id );
};

#endif // FP3D_BRIDGE_CDDA_SIM_H
