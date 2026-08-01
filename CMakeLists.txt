# Builds the installable artifact: a libz.so.1 a program compiled against the reference can
# load unchanged.
#
# SwiftPM builds the Swift libraries and drives the tests, and is the right tool for both. It
# cannot build this, because the three things that make substitution work — the soname, the
# install name, and the export list — have no expression in Package.swift. So there are two
# build systems on purpose, over the same sources, and neither is generated from the other.
#
# The Swift targets are built as one static library each, mirroring the SwiftPM target graph,
# rather than compiling everything into a single blob. Keeping the module boundaries means the
# Embedded and hosted builds are the same modules in the same shapes.

cmake_minimum_required(VERSION 3.26)

project(swift-zlib LANGUAGES C Swift)

set(CMAKE_Swift_LANGUAGE_VERSION 6)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

# The version the library reports and the soname it is loaded by. These come from the reference
# build and are not this project's to choose: a client checks the first against what it was
# compiled with, and the dynamic linker finds the library by the second.
set(SWIFTZLIB_VERSION 1.3.1)
set(SWIFTZLIB_SONAME_VERSION 1)

# -- generated inputs ---------------------------------------------------------
#
# Regenerated at configure time so that editing scripts/symbols.txt or implemented.txt cannot
# leave a stale export list or a stale stub file behind.

find_package(Python3 REQUIRED COMPONENTS Interpreter)

execute_process(
    COMMAND ${Python3_EXECUTABLE} ${CMAKE_SOURCE_DIR}/scripts/gen_symbols.py
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
    RESULT_VARIABLE gen_symbols_result
    OUTPUT_VARIABLE gen_symbols_output
)
if(NOT gen_symbols_result EQUAL 0)
    message(FATAL_ERROR "gen_symbols.py failed: ${gen_symbols_output}")
endif()
message(STATUS "${gen_symbols_output}")

execute_process(
    COMMAND ${Python3_EXECUTABLE} ${CMAKE_SOURCE_DIR}/scripts/gen_stubs.py
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
    RESULT_VARIABLE gen_stubs_result
    OUTPUT_VARIABLE gen_stubs_output
)
if(NOT gen_stubs_result EQUAL 0)
    message(FATAL_ERROR "gen_stubs.py failed: ${gen_stubs_output}")
endif()
message(STATUS "${gen_stubs_output}")

# -- the engine ---------------------------------------------------------------

add_library(LZ77 STATIC
    Sources/LZ77/BitReader.swift
    Sources/LZ77/BitWriter.swift
    Sources/LZ77/Deflate.swift
    Sources/LZ77/DeflateError.swift
    Sources/LZ77/DeflateTables.swift
    Sources/LZ77/HuffmanTable.swift
    Sources/LZ77/Inflate.swift
)
target_compile_options(LZ77 PRIVATE -parse-as-library)

add_library(SwiftZlib STATIC
    Sources/Zlib/Adler32.swift
    Sources/Zlib/Compressor.swift
    Sources/Zlib/Crc32.swift
    Sources/Zlib/Decompressor.swift
    Sources/Zlib/DeflateError.swift
)
set_target_properties(SwiftZlib PROPERTIES Swift_MODULE_NAME Zlib)
target_compile_options(SwiftZlib PRIVATE -parse-as-library)
target_link_libraries(SwiftZlib PUBLIC LZ77)

# -- the C parts --------------------------------------------------------------

add_library(CZlib STATIC
    Sources/CZlib/zlib_diagnostics.c
    Sources/CZlib/zlib_variadic.c
    Sources/CZlib/gen/zlib_stubs.c
)
target_include_directories(CZlib PUBLIC Sources/CZlib/include)

# -- the boundary -------------------------------------------------------------

add_library(ZlibABI STATIC
    Sources/ZlibABI/Boundary.swift
    Sources/ZlibABI/ChecksumAPI.swift
    Sources/ZlibABI/UtilityAPI.swift
    Sources/ZlibABI/Version.swift
)
target_compile_options(ZlibABI PRIVATE
    -parse-as-library
    -Xcc -I${CMAKE_SOURCE_DIR}/Sources/CZlib/include
)
target_link_libraries(ZlibABI PUBLIC SwiftZlib CZlib)

# -- the shipped library ------------------------------------------------------

add_library(z SHARED Sources/ZlibABI/Empty.swift)

# Driven by the Swift linker so the runtime and metadata registration come along; a C link
# would produce something that loads and then fails the moment Swift code runs.
set_target_properties(z PROPERTIES
    LINKER_LANGUAGE Swift
    # So that editing the symbol list relinks. Without it the export control is applied once
    # and then silently kept stale, which is the one failure this whole arrangement exists to
    # prevent.
    LINK_DEPENDS "${CMAKE_SOURCE_DIR}/build/zlib.map;${CMAKE_SOURCE_DIR}/build/zlib.exported"
    OUTPUT_NAME z
    VERSION ${SWIFTZLIB_VERSION}
    SOVERSION ${SWIFTZLIB_SONAME_VERSION}
)

if(APPLE)
    target_link_options(z PRIVATE
        "SHELL:-Xlinker -exported_symbols_list -Xlinker ${CMAKE_SOURCE_DIR}/build/zlib.exported"
        # dyld refuses a library offering a lower compatibility version than the one a client
        # recorded, so this matches the reference's rather than the project's own.
        "SHELL:-Xlinker -compatibility_version -Xlinker ${SWIFTZLIB_SONAME_VERSION}"
    )
    target_link_libraries(z PRIVATE ZlibABI)
else()
    target_link_options(z PRIVATE
        "SHELL:-Xlinker --version-script=${CMAKE_SOURCE_DIR}/build/zlib.map"
    )
    # Nothing inside the library calls the exported functions — they exist only to be called
    # from outside — so ordinary archive resolution drops every one of them and produces a
    # shared object that exports nothing at all.
    #
    # Every archive is kept whole, not only the two holding exported functions. The engine's
    # objects are reached only from the boundary, and leaving them to the linker's usual
    # what-have-I-seen-so-far rule is how this ends up with unresolved Swift symbols that fail
    # nowhere until something tries to link against it. Keeping everything costs a little size
    # and nothing else, because the version script decides what is published and
    # check_exports.sh proves what was published.
    #
    # Named by path in link options rather than through target_link_libraries, because the
    # archives have to sit *between* the two linker flags and a library list cannot express it.
    target_link_options(z PRIVATE
        "SHELL:-Xlinker --whole-archive \
-Xlinker $<TARGET_FILE:ZlibABI> \
-Xlinker $<TARGET_FILE:CZlib> \
-Xlinker $<TARGET_FILE:SwiftZlib> \
-Xlinker $<TARGET_FILE:LZ77> \
-Xlinker --no-whole-archive"
    )
    add_dependencies(z ZlibABI CZlib SwiftZlib LZ77)
endif()

install(TARGETS z LIBRARY DESTINATION lib)
install(FILES
    Sources/CZlib/include/zlib.h
    Sources/CZlib/include/zconf.h
    DESTINATION include
)
