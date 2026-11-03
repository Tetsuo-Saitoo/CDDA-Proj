// GDExtension entry point: registers CddaSim and stops the game thread before the DLL unloads.

#include <gdextension_interface.h>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

#include "cdda_sim.h"

namespace
{

void initialize( godot::ModuleInitializationLevel level )
{
    if( level != godot::MODULE_INITIALIZATION_LEVEL_SCENE ) {
        return;
    }
    GDREGISTER_CLASS( CddaSim );
}

void uninitialize( godot::ModuleInitializationLevel level )
{
    if( level != godot::MODULE_INITIALIZATION_LEVEL_SCENE ) {
        return;
    }
    // The game thread runs code from this DLL; it must be gone before Godot unloads it.
    CddaSim::stop_session();
}

} // namespace

extern "C" GDExtensionBool GDE_EXPORT fp3d_cdda_init( GDExtensionInterfaceGetProcAddress get_proc_address,
        GDExtensionClassLibraryPtr library, GDExtensionInitialization *init )
{
    godot::GDExtensionBinding::InitObject init_obj( get_proc_address, library, init );
    init_obj.register_initializer( initialize );
    init_obj.register_terminator( uninitialize );
    init_obj.set_minimum_library_initialization_level( godot::MODULE_INITIALIZATION_LEVEL_SCENE );
    return init_obj.init();
}
