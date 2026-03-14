cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(cervhole_headset)

target_sources(app PRIVATE
    src/main.c
    src/audio_buffer.c
    src/usb_audio_capture.c
    src/ble_audio_stream.c
)
