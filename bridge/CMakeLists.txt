# The GDExtension that runs CDDA inside Godot (M0 "Godot project loads the bridge"). It links the game library
# (cataclysm-tiles-common), so it is built as part of the cdda/ build: cdda/src/fp3d/CMakeLists.txt adds this
# directory when it and bridge/godot-cpp exist. Output: client/bin/fp3d_cdda.windows.x86_64.dll.

# CDDA code throws and catches; one exception setting for every translation unit in the DLL.
set(GODOTCPP_DISABLE_EXCEPTIONS OFF CACHE BOOL "" FORCE)
set(GODOTCPP_API_VERSION "4.7" CACHE STRING "" FORCE)
add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/godot-cpp ${CMAKE_CURRENT_BINARY_DIR}/godot-cpp EXCLUDE_FROM_ALL)
# godot-cpp would put its pdb in ${CMAKE_SOURCE_DIR}/bin, i.e. inside the cdda source tree.
set_target_properties(godot-cpp PROPERTIES PDB_OUTPUT_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/godot-cpp)

set(FP3D_CLIENT_BIN "${CMAKE_CURRENT_SOURCE_DIR}/../client/bin" CACHE PATH "Where the bridge DLL is copied")

add_library(fp3d-cdda SHARED
    src/register_types.cpp
    src/cdda_sim.cpp
    src/sim_session.cpp
    ${MESSAGES_CPP})
target_link_libraries(fp3d-cdda PRIVATE cataclysm-tiles-common godot::cpp)
target_include_directories(fp3d-cdda PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_compile_definitions(fp3d-cdda PRIVATE SDL_MAIN_HANDLED)
# CDDA builds with /GS-; the bridge's own code handles data from scripts, so it keeps stack cookies.
set_source_files_properties(src/register_types.cpp src/cdda_sim.cpp src/sim_session.cpp PROPERTIES COMPILE_OPTIONS "/GS")
set_target_properties(fp3d-cdda PROPERTIES OUTPUT_NAME "fp3d_cdda.windows.x86_64")
add_custom_command(TARGET fp3d-cdda POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory ${FP3D_CLIENT_BIN}
    COMMAND ${CMAKE_COMMAND} -E copy_if_different $<TARGET_FILE:fp3d-cdda> ${FP3D_CLIENT_BIN}
    COMMENT "Copying the bridge DLL to client/bin")
