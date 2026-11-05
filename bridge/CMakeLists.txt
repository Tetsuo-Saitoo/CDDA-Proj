# The GDExtension that runs CDDA inside Godot (M0 "Godot project loads the bridge"). It links the game library
# (cataclysm-tiles-common), so it is built as part of the cdda/ build: cdda/src/fp3d/CMakeLists.txt adds this
# directory when it and bridge/godot-cpp exist. Output: client/bin/fp3d_cdda.<platform>.x86_64.<dll|so>.

if(WIN32)
    set(FP3D_PLATFORM windows)
elseif(APPLE)
    set(FP3D_PLATFORM macos)
else()
    set(FP3D_PLATFORM linux)
    # A shared library can only take position-independent code, and CDDA's targets are made before this
    # file runs, so the whole build must be configured that way (preset fp3d-linux does).
    if(NOT CMAKE_POSITION_INDEPENDENT_CODE)
        message(FATAL_ERROR "The bridge needs -DCMAKE_POSITION_INDEPENDENT_CODE=ON (use preset fp3d-linux)")
    endif()
endif()

# CDDA's warning set (-Werror -Wold-style-cast ...) is for CDDA's own code; godot-cpp and its headers don't
# follow it. Drop it for this directory only (CDDA's other flags, e.g. -fsigned-char, stay).
if(NOT MSVC AND CATA_WARNINGS)
    string(REPLACE "${CATA_WARNINGS}" "" CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS}")
    string(APPEND CMAKE_CXX_FLAGS " -Wall")
endif()

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
# The bridge's own code handles data from scripts, so it keeps stack protection (CDDA builds with /GS- on MSVC).
if(MSVC)
    set_source_files_properties(src/register_types.cpp src/cdda_sim.cpp src/sim_session.cpp PROPERTIES COMPILE_OPTIONS "/GS")
else()
    set_source_files_properties(src/register_types.cpp src/cdda_sim.cpp src/sim_session.cpp PROPERTIES COMPILE_OPTIONS "-fstack-protector-strong")
    # Export only the entry symbol: CDDA's and the static libraries' symbols stay inside the library, so they
    # can't clash with what Godot or other extensions bring, and the library's own calls bind to itself.
    # CDDA's code comes in as an OBJECT library (not an archive), so --exclude-libs doesn't cover it: the
    # version script does.
    set_target_properties(fp3d-cdda PROPERTIES CXX_VISIBILITY_PRESET hidden VISIBILITY_INLINES_HIDDEN ON)
    if(NOT APPLE)
        target_link_options(fp3d-cdda PRIVATE -Wl,--version-script=${CMAKE_CURRENT_SOURCE_DIR}/exports.map
            -Wl,--exclude-libs,ALL -Wl,-Bsymbolic -Wl,--no-undefined -Wl,-z,relro,-z,now)
        set_target_properties(fp3d-cdda PROPERTIES LINK_DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/exports.map)
    endif()
endif()
set_target_properties(fp3d-cdda PROPERTIES PREFIX "" OUTPUT_NAME "fp3d_cdda.${FP3D_PLATFORM}.x86_64")
add_custom_command(TARGET fp3d-cdda POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory ${FP3D_CLIENT_BIN}
    COMMAND ${CMAKE_COMMAND} -E copy_if_different $<TARGET_FILE:fp3d-cdda> ${FP3D_CLIENT_BIN}
    COMMENT "Copying the bridge library to client/bin")
