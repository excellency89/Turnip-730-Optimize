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
mesadir="mesa-25.1.0"
mesaver="https://archive.mesa3d.org/mesa-25.1.0.tar.xz"

# Define working directories
workdir="$(pwd)/turnip_workdir"         # Base directory for all operations      # Directory to create the Magisk module

DRIVER_FILE="vulkan.ad0730.so"          # Output Vulkan Driver (emulator)
META_FILE="meta.json"                   # Metadata

ZIP_FILE_EMULATOR="Turnip-25.1.0-EMULATOR.zip" 

# List of required packages to build the Turnip driver
deps="meson ninja patchelf unzip curl pip flex bison zip glslang"
clear

echo "Checking system for required dependencies..."

# Check for required dependencies 
for deps_chk in $deps; do

    sleep 0.5
    if command -v "$deps_chk" >/dev/null 2>&1; then
        echo -e "$green - $deps_chk found $nocolor"
    else
        echo -e "$red - $deps_chk not found, cannot continue. $nocolor"
        deps_missing=1

        if [ "$deps_missing" == "1" ]; then
            echo "Missing dependencies, installing them now..." $'\n'
            sudo apt install -y meson-1.5 patchelf unzip curl python3-pip flex bison zip python3-mako glslang-tools vulkan-tools python-is-python3 &> /dev/null
        fi
    fi
done

sleep 1.5
clear

# Clean work directory if it exists
if [ -d "$workdir" ]; then
    echo "Work directory already exists. Cleaning before proceeding..." $'\n'
    rm -rf "$workdir"
    sleep 2
fi

echo "Creating and entering the work directory..." $'\n'
mkdir -p "$workdir" && cd "$_"

# Download Android NDK
echo "Downloading Android NDK..." $'\n'
curl -L "$mesaver" -o "$mesadir.tar.xz" &> /dev/null

clear

echo "Extracting Android NDK..." $'\n'
tar -xf "$mesadir".tar.xz

# Download Mesa source
echo "Downloading Latest Mesa source ..." $'\n'
curl -L "$mesaver" -o "$mesadir.tar.xz"

clear

echo "Extracting Mesa source..." $'\n'
tar -xf "$mesadir.tar.xz"
cd $mesadir

# Set NDK Clang bin directory
ndk_bin="$workdir/$ndkdir/toolchains/llvm/prebuilt/linux-x86_64/bin"

# Set toolchain variables
export CC=clang
export CXX=clang++
export AR=llvm-ar
export RANLIB=llvm-ranlib
export STRIP=llvm-strip
export OBJDUMP=llvm-objdump
export OBJCOPY=llvm-objcopy
export LDFLAGS="-fuse-ld=lld"

# Create a temporary directory for fake cc/c++
fakecc_dir="$workdir/fake-cc"
mkdir -p "$fakecc_dir"

# Create symbolic links to NDK-Clang
ln -sf "$ndk_bin/clang" "$fakecc_dir/cc"
ln -sf "$ndk_bin/clang++" "$fakecc_dir/c++"

# Prepend both fake-cc and NDK bin to PATH
export PATH="$fakecc_dir:$ndk_bin:$PATH"

echo "Creating Meson cross file..." $'\n'

cat <<EOF >"android-aarch64.txt"
[binaries]
ar = '$ndk_bin/llvm-ar'
c = ['ccache', '$ndk_bin/aarch64-linux-android$sdkver-clang', '-Wno-deprecated-declarations', '-Wno-gnu-alignof-expression']
cpp = ['ccache', '$ndk_bin/aarch64-linux-android$sdkver-clang++', '--start-no-unused-arguments', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '-static-libstdc++', '--end-no-unused-arguments', '-Wno-error=c++11-narrowing', '-Wno-deprecated-declarations', '-Wno-gnu-alignof-expression']
c_ld = '$ndk_bin/ld.lld'
cpp_ld = '$ndk_bin/ld.lld'
strip = '$ndk_bin/aarch64-linux-android-strip'
pkg-config = ['env', 'PKG_CONFIG_LIBDIR=NDKDIR/pkg-config', '/usr/bin/pkg-config']

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

cat <<EOF >"native.txt"
[build_machine]
c = ['ccache', 'clang']
cpp = ['ccache', 'clang++']
ar = 'llvm-ar'
strip = 'llvm-strip'
c_ld = 'ld.lld'
cpp_ld = 'ld.lld'
system = 'linux'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF

echo "Generating build files..." $'\n'
CC=clang CXX=clang++ meson setup build-android-aarch64 \
    --cross-file "$workdir/$mesadir/android-aarch64.txt" \
    --native-file "$workdir/$mesadir/native.txt" \
    -Dbuildtype=release \
    -Dplatforms=android \
    -Dplatform-sdk-version="$sdkver" \
    -Dandroid-stub=true \
    -Dgallium-drivers= \
    -Dvulkan-drivers=freedreno \
    -Dfreedreno-kmds=kgsl \
    -Degl=disabled \
    -Dstrip=true &> $workdir/meson_log

# Compile build files using Ninja
echo "Compiling build files..." $'\n'
ninja -C build-android-aarch64 &> "$workdir"/ninja_log

echo "Using patchelf to match .so name..." $'\n'
cp "$workdir"/"$mesadir"/build-android-aarch64/src/freedreno/vulkan/libvulkan_freedreno.so "$workdir"
cd "$workdir"



if ! [ -a libvulkan_freedreno.so ]; then
    echo -e "$red Build failed! libvulkan_freedreno.so not found $nocolor" && exit 1
fi

echo "Prepare magisk module structure..." $'\n'
p1="system/vendor/lib64/hw"
mkdir -p "$magiskdir/$p1"
cd "$magiskdir"

echo "Copy necessary files from the work directory..." $'\n'
cp "$workdir"/libvulkan_freedreno.so "$workdir"/vulkan.adreno.so
cp "$workdir"/vulkan.adreno.so "$magiskdir/$p1"

meta="META-INF/com/google/android"
mkdir -p "$meta"

# Create update-binary
cat <<EOF >"$meta/update-binary"
#!/sbin/sh

# echo before loading util_functions
ui_print() { echo "\$1"; }

require_new_

    echo " Its time to create Turnip build for EMULATOR"

    sleep 2

    cd ..

    mv vulkan.adreno.so vulkan.turnip.so

# Create meta.json file for turnip emulator
 cat <<EOF > "$META_FILE"
{
  "schemaVersion": 1,
  "name": "Turnip Driver V1",
  "description": "Optimize For Adreno 730",
  "author": "VanezZa",
  "packageVersion": "3",
  "vendor": "Mesa3D",
  "driverVersion": "Vulkan 3D",
  "minApi": 34,
  "libraryName": "vulkan.a730.so"
}
EOF

# Zip the turnip .so file and meta.json file
    if ! zip "$workdir/$ZIP_FILE_EMULATOR" "$DRIVER_FILE" "$META_FILE" &> /dev/null; then
        echo -e "${red}Error: Zipping driver files failed.${nocolor}"
        exit 1
    fi

    clear

    echo -e "$green Build Finished :). $nocolor" $'\n'
    echo -e "$green-All done, you can take your drivers from here;$nocolor" $'\n'
    echo -e "Magisk-KSU Module : $workdir/$ZIP_FILE_MAGISK" $'\n' 
    echo -e "Emulator : $workdir/$ZIP_FILE_EMULATOR" $'\n'

    # Cleanup 
    rm "$DRIVER_FILE" "$META_FILE"

    # Clean up fake-cc directory and symbolic links on exit
    rm -rf "$fakecc_dir"

fi
