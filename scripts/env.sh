#!/bin/bash
# Cervos build environment — source this before building
# Usage: source scripts/env.sh
#
# Edit the paths below for your machine. All tools must be installed first
# (see requirements.md for installation instructions).

# ---- Flutter SDK ----
export PATH="${FLUTTER_HOME:-/c/dev/flutter}/bin:$PATH"

# ---- Java (for Gradle / Android SDK manager) ----
# Set JAVA_HOME to any JDK 17+. Examples:
#   JetBrains bundled: /c/Program Files/JetBrains/.../jbr
#   Adoptium:          /c/Program Files/Eclipse Adoptium/jdk-17
export JAVA_HOME="${JAVA_HOME:-/c/Program Files/JetBrains/JetBrains Rider 2025.1.4/jbr}"

# ---- Android SDK ----
export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-/c/dev/android-sdk}"
# CMake from Android SDK (needed for NDK builds)
ANDROID_CMAKE_VERSION="${ANDROID_CMAKE_VERSION:-3.22.1}"
export PATH="$ANDROID_SDK_ROOT/cmake/$ANDROID_CMAKE_VERSION/bin:$PATH"

# ---- Zephyr RTOS (firmware builds) ----
export ZEPHYR_BASE="${ZEPHYR_BASE:-/c/dev/zephyr-workspace/zephyr}"
export ZEPHYR_TOOLCHAIN_VARIANT=gnuarmemb
export GNUARMEMB_TOOLCHAIN_PATH="${GNUARMEMB_TOOLCHAIN_PATH:-/c/dev/arm-gnu-toolchain-13.3.rel1-mingw-w64-i686-arm-none-eabi}"

# ---- West (Zephyr meta-tool, pip install west) ----
# Find west executable — prefer explicit path, fall back to PATH
if [ -n "$WEST" ] && [ -f "$WEST" ]; then
    : # already set
elif command -v west &>/dev/null; then
    export WEST="$(command -v west)"
else
    # Common pip Scripts location on Windows
    export WEST="$(python -c 'import sysconfig; print(sysconfig.get_path("scripts"))' 2>/dev/null)/west.exe"
fi

# ---- nrfutil (Go binary from Nordic — NOT pip nrfutil) ----
# Download from: https://www.nordicsemi.com/Products/Development-tools/nrf-util
# CRITICAL: pip nrfutil / adafruit-nrfutil are BROKEN on Python 3.13.
#           Always use the Go-based nrfutil binary.
if [ -n "$NRFUTIL" ] && [ -f "$NRFUTIL" ]; then
    : # already set
elif [ -f "/c/dev/nrfutil.exe" ]; then
    export NRFUTIL="/c/dev/nrfutil.exe"
elif [ -f "$HOME/.nrfutil/bin/nrfutil.exe" ]; then
    export NRFUTIL="$HOME/.nrfutil/bin/nrfutil.exe"
elif command -v nrfutil &>/dev/null; then
    export NRFUTIL="$(command -v nrfutil)"
else
    echo "WARNING: nrfutil not found. Firmware flashing will not work."
    echo "Download from: https://www.nordicsemi.com/Products/Development-tools/nrf-util"
fi

echo "Cervos build environment loaded."
echo "  ZEPHYR_BASE=$ZEPHYR_BASE"
echo "  WEST=$WEST"
echo "  NRFUTIL=$NRFUTIL"
echo "  JAVA_HOME=$JAVA_HOME"
