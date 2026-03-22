# Cervos — Build Requirements

Everything needed to build, flash, and run the firmware and Flutter app from scratch.

## Firmware (nRF52840 Dongle)

### 1. Zephyr RTOS workspace

```bash
pip install west
west init ~/zephyr-workspace
cd ~/zephyr-workspace && west update
```

Set `ZEPHYR_BASE` to `<workspace>/zephyr`.

### 2. GNU Arm Embedded Toolchain (13.x+)

Download from [Arm Developer](https://developer.arm.com/Tools%20and%20Software/GNU%20Toolchain).

Set `GNUARMEMB_TOOLCHAIN_PATH` to the install directory (the one containing `bin/arm-none-eabi-gcc`).

### 3. CMake 3.20+

Any CMake will do. The Android SDK bundles one (`sdkmanager "cmake;3.22.1"`), or install standalone.

### 4. nrfutil (Go binary)

Download the **Go-based nrfutil** from [Nordic's download page](https://www.nordicsemi.com/Products/Development-tools/nrf-util). Place it somewhere on your PATH or set `NRFUTIL` to the binary path.

After installing, add the DFU tools:
```bash
nrfutil install nrf5sdk-tools
```

> **WARNING:** Do NOT use `pip install nrfutil` or `pip install adafruit-nrfutil` for flashing. These Python packages are broken on Python 3.13 (pyserial drops the USB CDC connection during DFU transfer). The Go-based nrfutil binary is the only reliable option.

### 5. google/liblc3

Cloned into the firmware lib directory (gitignored):
```bash
git clone https://github.com/google/liblc3.git firmware/lib/liblc3
```

### 6. Python packages for `west`

```bash
pip install west "pyyaml>=6.0"
```

> **Note:** PyYAML 4.x is broken on Python 3.13 (`collections.Hashable` removed). Must use 6.0+.

---

## Flutter App (Android)

### 1. Flutter SDK 3.16+

Install from [flutter.dev](https://docs.flutter.dev/get-started/install).

### 2. Android SDK

Required components (install via `sdkmanager`):
```bash
sdkmanager "platforms;android-34" "build-tools;34.0.0" "ndk;25.1.8937393" "cmake;3.22.1"
```

### 3. Java 17+

Any JDK 17+ works (Adoptium, JetBrains bundled JBR, Oracle). Set `JAVA_HOME`.

### 4. google/liblc3 (for Android NDK decoder)

Cloned into the NDK source directory (gitignored):
```bash
git clone https://github.com/google/liblc3.git mobile/android/app/src/main/cpp/liblc3
```

---

## Quick Setup (all at once)

```bash
# Clone the repo
git clone https://github.com/yourname/cervos.git && cd cervos

# Clone LC3 codec into both locations
git clone https://github.com/google/liblc3.git firmware/lib/liblc3
git clone https://github.com/google/liblc3.git mobile/android/app/src/main/cpp/liblc3

# Install Python deps
pip install west "pyyaml>=6.0"

# Edit env.sh paths for your machine
nano scripts/env.sh

# Source environment
source scripts/env.sh

# Build firmware
cd firmware && "$WEST" build -b nrf52840dongle/nrf52840 -p always . && cd ..

# Generate DFU package
"$NRFUTIL" nrf5sdk-tools pkg generate \
  --application firmware/build/zephyr/zephyr.hex \
  --hw-version 52 --sd-req 0x00 --application-version 1 \
  firmware/build/cervos_dfu.zip

# Flash (press reset on dongle first)
"$NRFUTIL" nrf5sdk-tools dfu serial \
  -pkg firmware/build/cervos_dfu.zip -p COM4 -b 115200

# Build and install Flutter app
cd mobile && flutter pub get && flutter build apk --debug
flutter install -d <device-id> --use-application-binary build/app/outputs/flutter-apk/app-debug.apk
```

---

## Known Issues

| Issue | Cause | Fix |
|-------|-------|-----|
| `west` crashes with `collections.Hashable` error | PyYAML 4.x on Python 3.13 | `pip install "pyyaml>=6.0"` |
| `nrfutil dfu serial` fails with "port not open" | pip `nrfutil`/`adafruit-nrfutil` pyserial bug on Python 3.13 | Use Go-based `nrfutil` from Nordic |
| LC3 `ltpf.c` fails with `alignas` error | liblc3 ARM code requires C11 | Already handled in CMakeLists.txt (`-std=c11` flag) |
| `BT_L2CAP_DYNAMIC_CHANNEL` Kconfig warning | Missing `BT_SMP` dependency | Already set in prj.conf |
