cmake_minimum_required(VERSION 3.22.1)
project(cervos_lc3)

# LC3 codec (google/liblc3) — clone into this directory
set(LC3_DIR ${CMAKE_CURRENT_SOURCE_DIR}/liblc3)

add_library(lc3_decoder SHARED
    lc3_decoder_jni.c
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

target_include_directories(lc3_decoder PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${LC3_DIR}/include
)

target_link_libraries(lc3_decoder
    android
    log
    m
)
