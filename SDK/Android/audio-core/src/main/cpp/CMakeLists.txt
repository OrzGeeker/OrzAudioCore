cmake_minimum_required(VERSION 3.22)
project(orzaudio LANGUAGES C CXX)

# Builds the JNI bridge around a prebuilt, self-contained OrzAudioCore static
# archive (the merged libOrzAudioCore.a from package-android-sdk.sh).
# script/build-android-aar.sh supplies both paths; Gradle itself never needs a
# NDK to consume the resulting AAR.

if(NOT DEFINED ORZ_PREBUILT_CORE OR NOT EXISTS "${ORZ_PREBUILT_CORE}")
    message(FATAL_ERROR "ORZ_PREBUILT_CORE is missing: ${ORZ_PREBUILT_CORE}")
endif()
if(NOT DEFINED ORZ_PREBUILT_INCLUDE OR NOT EXISTS "${ORZ_PREBUILT_INCLUDE}/orz_audio_core.h")
    message(FATAL_ERROR "ORZ_PREBUILT_INCLUDE is missing: ${ORZ_PREBUILT_INCLUDE}")
endif()

add_library(orzaudio SHARED orz_jni.c)
target_include_directories(orzaudio PRIVATE "${ORZ_PREBUILT_INCLUDE}")
target_compile_definitions(orzaudio PRIVATE ORZ_AUDIO_CORE_BUILD=1)
target_compile_options(orzaudio PRIVATE -O2 -fPIC -ffunction-sections -fdata-sections -fvisibility=hidden)

# The core is C++ internally; link with the C++ driver so libc++ symbols are
# resolved even though this target only has a C translation unit.
set_target_properties(orzaudio PROPERTIES
    C_STANDARD 11
    CXX_STANDARD 17
    CXX_STANDARD_REQUIRED ON
    LINKER_LANGUAGE CXX
)
target_link_libraries(orzaudio PRIVATE "${ORZ_PREBUILT_CORE}" z m log android c++_static c++abi)
target_link_options(orzaudio PRIVATE
    -Wl,--gc-sections
    -Wl,-z,max-page-size=16384
    -Wl,--version-script=${CMAKE_CURRENT_SOURCE_DIR}/orzaudio.map
)
