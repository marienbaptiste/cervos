cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(cervos_dongle)

# --- App sources ---
target_sources(app PRIVATE
    src/main.c
    src/audio_buffer.c
    src/usb_audio_capture.c
    src/ble_l2cap_stream.c
    src/lc3_encoder.c
)

# --- LC3 codec library (google/liblc3) ---
set(LC3_DIR ${CMAKE_CURRENT_SOURCE_DIR}/lib/liblc3)

target_sources(app PRIVATE
    ${LC3_DIR}/src/attdet.c
    ${LC3_DIR}/src/bits.c
    ${LC3_DIR}/src/bwdet.c
    ${LC3_DIR}/src/energy.c
    ${LC3_DIR}/src/lc3.c
    ${LC3_DIR}/src/ltpf.c
    ${LC3_DIR}/src/mdct.c
    ${LC3_DIR}/src/plc.c
    ${LC3_DIR}/src/sns.c
    ${LC3_DIR}/src/spec.c
    ${LC3_DIR}/src/tables.c
    ${LC3_DIR}/src/tns.c
)

target_include_directories(app PRIVATE
    ${LC3_DIR}/include
)

# Disable ARM DSP optimizations — they produce bitstream incompatible
# with the generic C path used on the phone (AArch64).
# Force generic C code path by undefining __arm__.
target_compile_definitions(app PRIVATE
    LC3_DISABLE_ARM
)

# Override the ARM detection in liblc3 sources
set_source_files_properties(
    ${LC3_DIR}/src/ltpf.c
    ${LC3_DIR}/src/mdct.c
    ${LC3_DIR}/src/sns.c
    ${LC3_DIR}/src/spec.c
    PROPERTIES COMPILE_FLAGS "-U__arm__ -U__ARM_ARCH -std=c11"
)

target_compile_options(app PRIVATE -O2)
target_link_libraries(app PRIVATE -lm)
