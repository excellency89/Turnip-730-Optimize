#!/bin/bash -e

# Define colors for terminal output
green='\033[0;32m'
red='\033[0;31m'
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
ZIP_FILE_EMULATOR="Turnip-25.1.0-R1.zip"

# List of required packages
deps="meson ninja patchelf unzip curl flex bison zip glslang-tools"

clear
echo "============================================="
echo "  Turnip Driver Builder - Emulator Only"
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
    echo "Missing dependencies detected, installing them now..."
    sudo apt update
    sudo apt install -y meson ninja-build patchelf unzip curl python3-pip \
        flex bison zip python3-mako glslang-tools vulkan-tools python-is-python3
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
curl -L "$ndkver" --output "$ndkdir.zip"
if [ $? -ne 0 ]; then
    echo -e "$red Failed to download NDK $nocolor"
    exit 1
fi

clear
echo "Extracting Android NDK..."
unzip -q "$ndkdir.zip"
if [ $? -ne 0 ]; then
    echo -e "$red Failed to extract NDK $nocolor"
    exit 1
fi

# Download Mesa source
echo ""
echo "Downloading Mesa source ($mesadir)..."
curl -L "$mesaver" --output "$mesadir.zip"
if [ $? -ne 0 ]; then
    echo -e "$red Failed to download Mesa $nocolor"
    exit 1
fi

clear
echo "Extracting Mesa source..."
unzip -q "$mesadir.zip"
if [ $? -ne 0 ]; then
    echo -e "$red Failed to extract Mesa $nocolor"
    exit 1
fi

cd "$mesadir"
echo "Entered Mesa directory: $(pwd)"

# Set NDK Clang bin directory
ndk_bin="$workdir/$ndkdir/toolchains/llvm/prebuilt/linux-x86_64/bin"
if [ ! -d "$ndk_bin" ]; then
    echo -e "$red NDK bin directory not found: $ndk_bin $nocolor"
    exit 1
fi

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

echo ""
echo "Creating Meson cross file..."

cat <<EOF >"android-aarch64.txt"
[binaries]
ar = '$ndk_bin/llvm-ar'
c = ['$ndk_bin/aarch64-linux-android$sdkver-clang', '-Wno-deprecated-declarations', '-Wno-gnu-alignof-expression']
cpp = ['$ndk_bin/aarch64-linux-android$sdkver-clang++', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '-static-libstdc++', '-Wno-error=c++11-narrowing', '-Wno-deprecated-declarations', '-Wno-gnu-alignof-expression']
c_ld = '$ndk_bin/ld.lld'
cpp_ld = '$ndk_bin/ld.lld'
strip = '$ndk_bin/aarch64-linux-android-strip'

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

echo "Cross file created: android-aarch64.txt"
echo ""
echo "Generating build files with Meson..."

meson setup build-android-aarch64 \
    --cross-file "$workdir/$mesadir/android-aarch64.txt" \
    -Dbuildtype=release \
    -Dplatforms=android \
    -Dplatform-sdk-version="$sdkver" \
    -Dandroid-stub=true \
    -Dgallium-drivers= \
    -Dvulkan-drivers=freedreno \
    -Dfreedreno-kmds=kgsl \
    -Degl=disabled \
    -Dstrip=true

if [ $? -ne 0 ]; then
    echo -e "$red Meson setup failed! $nocolor"
    exit 1
fi

echo ""
echo "Meson setup completed successfully."
echo ""
echo "Compiling build files with Ninja..."

# Compile build files using Ninja
ninja -C build-android-aarch64 -j$(nproc)

if [ $? -ne 0 ]; then
    echo -e "$red Ninja build failed! $nocolor"
    exit 1
fi

echo ""
echo "Ninja build completed successfully."
echo ""

# Check if the driver was built
driver_source="$workdir/$mesadir/build-android-aarch64/src/freedreno/vulkan/libvulkan_freedreno.so"
if [ ! -f "$driver_source" ]; then
    echo -e "$red Build failed! libvulkan_freedreno.so not found $nocolor"
    echo "Checked path: $driver_source"
    exit 1
fi

echo "Driver built successfully: $driver_source"
echo ""

# Copy driver to work directory
echo "Copying driver to work directory..."
cp "$driver_source" "$workdir/$DRIVER_FILE"
if [ $? -ne 0 ]; then
    echo -e "$red Failed to copy driver $nocolor"
    exit 1
fi

cd "$workdir"
echo "Changed to work directory: $(pwd)"

# Verify driver exists
if [ ! -f "$DRIVER_FILE" ]; then
    echo -e "$red Build failed! $DRIVER_FILE not found $nocolor"
    exit 1
fi

echo ""
echo "Creating meta.json for emulator..."

# Create meta.json file for turnip emulator
cat <<EOF > "$META_FILE"
{
  "schemaVersion": 1,
  "name": "Freedreno Turnip Driver 25.1.0",
  "description": "Optimized for Adreno 730",
  "author": "VanezZa",
  "packageVersion": "3",
  "vendor": "Mesa3D",
  "driverVersion": "Vulkan 3D",
  "minApi": 27,
  "libraryName": "vulkan.turnip.so"
}
EOF

if [ ! -f "$META_FILE" ]; then
    echo -e "$red Failed to create meta.json $nocolor"
    exit 1
fi

echo ""
echo "Packing driver files into emulator zip..."

# Zip the turnip .so file and meta.json file
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
echo -e "$green Emulator Driver:$nocolor"
echo "  $workdir/$ZIP_FILE_EMULATOR"
echo ""
echo "============================================="

# Cleanup temporary files
echo ""
echo "Cleaning up temporary files..."
rm -f "$DRIVER_FILE" "$META_FILE"

# Final cleanup
echo "Build completed. Exiting."
echo ""

exit 0
