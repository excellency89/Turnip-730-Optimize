#!/bin/bash -e

# Define colors for terminal output
green='\033[0;32m'
red='\033[0;31m'
yellow='\033[1;33m'
nocolor='\033[0m'

# Define Android NDK version and download URL
ndkdir="android-ndk-r30-beta1"
ndkver="https://dl.google.com/android/repository/${ndkdir}-linux.zip"
sdkver="34"

# Define Mesa version and download URL
mesadir="mesa-mesa-25.1.0"
mesaver="https://gitlab.freedesktop.org/mesa/mesa/-/archive/mesa-25.1.0/mesa-mesa-25.1.0.zip?ref_type=tags"

# Define working directories
workdir="$(pwd)/turnip_workdir"

DRIVER_FILE="vulkan.turnip.so"
META_FILE="meta.json"
ZIP_FILE_EMULATOR="turnip-25.1.0-R1-Adreno730-Optimized.zip"

# Log file
LOG_FILE="build.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# List of required packages
deps="meson ninja patchelf unzip curl flex bison zip glslangValidator"

clear
echo "============================================="
echo "  Turnip Driver Builder - Adreno 730 Optimized"
echo "  Mesa Version: 25.1.0 R1"
echo "  Started at: $(date)"
echo "============================================="
echo ""
echo "Checking system for required dependencies..."

# Check for required dependencies
deps_missing=0
for deps_chk in $deps; do
    sleep 0.5
    if command -v "$deps_chk" >/dev/null 2>&1; then
        echo -e "$green ✓ $deps_chk found $nocolor"
    else
        echo -e "$red ✗ $deps_chk not found $nocolor"
        deps_missing=1
    fi
done

if [ "$deps_missing" == "1" ]; then
    echo ""
    echo -e "$yellow Missing dependencies detected, installing them now... $nocolor"
    sudo apt update
    sudo apt install -y meson ninja-build patchelf unzip curl python3-pip \
        flex bison zip python3-mako vulkan-tools python-is-python3
    
    if ! command -v glslangValidator >/dev/null 2>&1; then
        sudo apt install -y glslang-tools || sudo apt install -y glslang-dev
    fi
    echo "Dependencies installation completed."
fi

sleep 1.5
clear

# Clean work directory if it exists
if [ -d "$workdir" ]; then
    echo "Work directory already exists. Cleaning before proceeding..."
    rm -rf "$workdir"
    sleep 2
fi

echo "Creating and entering the work directory..."
mkdir -p "$workdir" && cd "$_"

# Download Android NDK
echo ""
echo "Downloading Android NDK ($ndkdir)..."
if ! curl -L "$ndkver" --output "$ndkdir.zip" 2>&1; then
    echo -e "$red Failed to download NDK $nocolor"
    exit 1
fi
echo -e "$green ✓ NDK downloaded successfully $nocolor"

clear
echo "Extracting Android NDK..."
if ! unzip -q "$ndkdir.zip" 2>&1; then
    echo -e "$red Failed to extract NDK $nocolor"
    exit 1
fi
echo -e "$green ✓ NDK extracted successfully $nocolor"

# Download Mesa source
echo ""
echo "Downloading Mesa source ($mesadir)..."
if ! curl -L "$mesaver" --output "$mesadir.zip" 2>&1; then
    echo -e "$red Failed to download Mesa $nocolor"
    exit 1
fi
echo -e "$green ✓ Mesa downloaded successfully $nocolor"

clear
echo "Extracting Mesa source..."
if ! unzip -q "$mesadir.zip" 2>&1; then
    echo -e "$red Failed to extract Mesa $nocolor"
    exit 1
fi
echo -e "$green ✓ Mesa extracted successfully $nocolor"

cd "$mesadir"
echo "Entered Mesa directory: $(pwd)"

# Set NDK Clang bin directory
ndk_bin="$workdir/$ndkdir/toolchains/llvm/prebuilt/linux-x86_64/bin"
if [ ! -d "$ndk_bin" ]; then
    echo -e "$red NDK bin directory not found: $ndk_bin $nocolor"
    exit 1
fi
echo -e "$green ✓ NDK bin found: $ndk_bin $nocolor"

# Set toolchain variables
export CC=clang
export CXX=clang++
export AR=llvm-ar
export RANLIB=llvm-ranlib
export STRIP=llvm-strip
export OBJDUMP=llvm-objdump
export OBJCOPY=llvm-objcopy
export LDFLAGS="-fuse-ld=lld"

# Prepend NDK bin to PATH
export PATH="$ndk_bin:$PATH"

# Verify toolchain
echo ""
echo "Verifying toolchain..."
if ! command -v aarch64-linux-android${sdkver}-clang >/dev/null 2>&1; then
    echo -e "$red ✗ aarch64-linux-android${sdkver}-clang not found $nocolor"
    exit 1
fi
echo -e "$green ✓ Toolchain verified $nocolor"

echo ""
echo "Creating Meson cross file..."

# Cross file - ไม่มี static-libstdc++
cat <<EOF >"android-aarch64.txt"
[binaries]
ar = '$ndk_bin/llvm-ar'
c = ['$ndk_bin/aarch64-linux-android$sdkver-clang', '-Wno-deprecated-declarations', '-Wno-gnu-alignof-expression']
cpp = ['$ndk_bin/aarch64-linux-android$sdkver-clang++', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '-Wno-error=c++11-narrowing', '-Wno-deprecated-declarations', '-Wno-gnu-alignof-expression']
c_ld = '$ndk_bin/ld.lld'
cpp_ld = '$ndk_bin/ld.lld'
strip = '$ndk_bin/aarch64-linux-android-strip'

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

echo -e "$green ✓ Cross file created: android-aarch64.txt $nocolor"
echo ""
echo "Generating build files with Meson (Adreno 730 Optimized)..."

# =============================================
# 🔥 Adreno 730 OPTIMIZATION FLAGS 🔥
# =============================================
# -O3                    : High optimization
# -march=armv8.2a+fp16   : Adreno 730 supports FP16
# -mcpu=cortex-x2        : Optimize for X2 core (SD 8 Gen 1)
# -ffast-math            : Faster math (less precise)
# -funroll-loops         : Unroll loops for speed
# -fomit-frame-pointer   : Less overhead
# -fno-stack-protector   : Remove security checks (faster)
# -fno-math-errno        : Faster math
# -DNDEBUG               : Remove asserts
# -D_FORTIFY_SOURCE=0    : Disable fortify
# =============================================

OPTIMIZE_FLAGS="-O3 -march=armv8.2a+fp16 -mcpu=cortex-x2 -ffast-math -funroll-loops -fomit-frame-pointer -fno-stack-protector -fno-math-errno -DNDEBUG -D_FORTIFY_SOURCE=0"

if ! meson setup build-android-aarch64 \
    --cross-file "$workdir/$mesadir/android-aarch64.txt" \
    -Dbuildtype=release \
    -Dplatforms=android \
    -Dplatform-sdk-version="$sdkver" \
    -Dandroid-stub=true \
    -Dgallium-drivers= \
    -Dvulkan-drivers=freedreno \
    -Dfreedreno-kmds=kgsl \
    -Degl=disabled \
    -Dgles1=disabled \
    -Dgles2=disabled \
    -Dopengl=false \
    -Dgbm=disabled \
    -Dx11=disabled \
    -Dwayland=disabled \
    -Ddri3=disabled \
    -Dglx=disabled \
    -Dosmesa=disabled \
    -Dllvm=disabled \
    -Dshared-glapi=disabled \
    -Dasm=disabled \
    -Dvalgrind=disabled \
    -Dbuild-tests=disabled \
    -Dbuild-docs=disabled \
    -Ddemos=disabled \
    -Dstrip=true \
    -Dc_args="$OPTIMIZE_FLAGS -Wno-unused-command-line-argument" \
    -Dcpp_args="$OPTIMIZE_FLAGS -Wno-unused-command-line-argument" \
    -Dc_link_args="-flto -Wl,-O3 -Wl,--gc-sections -Wl,--as-needed" \
    -Dcpp_link_args="-flto -Wl,-O3 -Wl,--gc-sections -Wl,--as-needed" 2>&1; then
    echo -e "$red Meson setup failed! $nocolor"
    cat meson-log.txt 2>/dev/null || echo "meson-log.txt not found"
    exit 1
fi

echo -e "$green ✓ Meson setup completed successfully $nocolor"
echo ""
echo "Compiling build files with Ninja (Adreno 730 Optimized)..."
echo "Using $(nproc) cores..."

if ! ninja -C build-android-aarch64 -j$(nproc) 2>&1; then
    echo -e "$red Ninja build failed! $nocolor"
    echo "Showing last 50 lines of error..."
    ninja -C build-android-aarch64 -j1 2>&1 | tail -50
    exit 1
fi

echo -e "$green ✓ Ninja build completed successfully $nocolor"
echo ""

# Check if the driver was built
driver_source="$workdir/$mesadir/build-android-aarch64/src/freedreno/vulkan/libvulkan_freedreno.so"
if [ ! -f "$driver_source" ]; then
    echo -e "$red Build failed! libvulkan_freedreno.so not found $nocolor"
    ls -la "$workdir/$mesadir/build-android-aarch64/src/freedreno/vulkan/" 2>/dev/null || echo "Directory not found"
    exit 1
fi

echo -e "$green ✓ Driver built successfully: $driver_source $nocolor"

# Check file size
FILE_SIZE=$(stat -c%s "$driver_source" 2>/dev/null || stat -f%z "$driver_source" 2>/dev/null)
echo "Driver size: $FILE_SIZE bytes"

echo ""

# Copy driver to work directory
echo "Copying driver to work directory..."
if ! cp "$driver_source" "$workdir/$DRIVER_FILE" 2>&1; then
    echo -e "$red Failed to copy driver $nocolor"
    exit 1
fi

cd "$workdir"

# Verify driver exists
if [ ! -f "$DRIVER_FILE" ]; then
    echo -e "$red Build failed! $DRIVER_FILE not found $nocolor"
    exit 1
fi

echo ""
echo "Creating meta.json for emulator..."

cat <<EOF > "$META_FILE"
{
  "schemaVersion": 1,
  "name": "Turnip Driver 25.1.0 Adreno 730 Optimized",
  "description": "Optimized for Adreno 730 | Snapdragon 8 Gen 1 | Performance Focused",
  "author": "VanezZa",
  "packageVersion": "R1-Optimized",
  "vendor": "Mesa3D",
  "driverVersion": "Vulkan 1.3",
  "minApi": 34,
  "libraryName": "vulkan.turnip.so",
  "features": {
    "optimizedFor": "Adreno 730",
    "flags": "-O3 -march=armv8.2a+fp16 -mcpu=cortex-x2 -ffast-math -funroll-loops"
  }
}
EOF

if [ ! -f "$META_FILE" ]; then
    echo -e "$red Failed to create meta.json $nocolor"
    exit 1
fi
echo -e "$green ✓ meta.json created $nocolor"

echo ""
echo "Packing driver files into emulator zip..."

if ! zip "$ZIP_FILE_EMULATOR" "$DRIVER_FILE" "$META_FILE" >/dev/null 2>&1; then
    echo -e "$red Error: Zipping driver files failed. $nocolor"
    exit 1
fi

if [ ! -f "$ZIP_FILE_EMULATOR" ]; then
    echo -e "$red Error: Zip file was not created. $nocolor"
    exit 1
fi

clear
echo ""
echo "============================================="
echo -e "$green ✓ Build Finished Successfully! $nocolor"
echo "============================================="
echo ""
echo -e "$green ════════════════════════════════════════ $nocolor"
echo -e "$green  🔥 Adreno 730 OPTIMIZED Driver 🔥 $nocolor"
echo -e "$green ════════════════════════════════════════ $nocolor"
echo ""
echo -e "$green Emulator Driver:$nocolor"
echo "  $workdir/$ZIP_FILE_EMULATOR"
echo ""
echo -e "$yellow Optimizations applied:$nocolor"
echo "  • -O3 (High optimization)"
echo "  • -march=armv8.2a+fp16 (Adreno 730 FP16 support)"
echo "  • -mcpu=cortex-x2 (SD 8 Gen 1 optimized)"
echo "  • -ffast-math (Faster math)"
echo "  • -funroll-loops (Loop unrolling)"
echo "  • -fomit-frame-pointer (Less overhead)"
echo "  • -flto (Link Time Optimization)"
echo "  • Disabled: GL, EGL, GBM, X11, Wayland, LLVM"
echo ""
echo "  Finished at: $(date)"
echo "============================================="

# Cleanup
rm -f "$DRIVER_FILE" "$META_FILE"

echo ""
echo -e "$yellow 💡 Tips for Winlator/Eden:$nocolor"
echo "  1. Set environment: TU_DEBUG=perf"
echo "  2. Set: MESA_GL_THREAD_COUNT=auto"
echo "  3. Disable: TU_PERF_WARN=0"
echo "  4. Enable: MESA_GLSL_CACHE_MAX_SIZE=512MB"
echo ""

exit 0
