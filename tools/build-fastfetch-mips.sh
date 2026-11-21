#!/bin/sh
# Cross-builds a static fastfetch for the ONU: MIPS32r2, big-endian, musl, no PIE.
# Everything lands in build/fastfetch-mips (gitignored).
set -eu

ZIG_VERSION=0.17.1
FF_VERSION=2.71.0
ROOT="$(cd "$(dirname "$0")/.." && pwd)/build/fastfetch-mips"
export UV_CACHE_DIR="$ROOT/.uv-cache"
mkdir -p "$ROOT"

# zig ships only as a Python wheel; uv unpacks it into a throwaway venv
if [ ! -x "$ROOT/venv/bin/python" ]; then
    uv venv -q "$ROOT/venv"
    uv pip install -q --python "$ROOT/venv/bin/python" "ziglang==$ZIG_VERSION"
fi
ZIG="$(find "$ROOT/venv" -type f -path '*/site-packages/ziglang/zig' | head -1)"
[ -x "$ZIG" ] || { echo "zig not found in $ROOT/venv" >&2; exit 1; }

for tool in ar ranlib; do
    printf '#!/bin/sh\nexport ZIG_GLOBAL_CACHE_DIR="%s/.zig-cache"\nexec "%s" %s "$@"\n' \
        "$ROOT" "$ZIG" "$tool" > "$ROOT/zig-$tool"
    chmod +x "$ROOT/zig-$tool"
done

# musleabi is the only ABI zig supports for big-endian mips; mips32r2 is the SoC's ISA
cat > "$ROOT/zig-cc" <<EOF
#!/bin/sh
export ZIG_GLOBAL_CACHE_DIR="$ROOT/.zig-cache"
exec "$ZIG" cc -target mips-linux-musleabi -mcpu=mips32r2 "\$@"
EOF
chmod +x "$ROOT/zig-cc"

cat > "$ROOT/toolchain.cmake" <<EOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR mips)
set(CMAKE_C_COMPILER $ROOT/zig-cc)
set(CMAKE_AR $ROOT/zig-ar CACHE FILEPATH "")
set(CMAKE_RANLIB $ROOT/zig-ranlib CACHE FILEPATH "")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
EOF

cd "$ROOT"
[ -d "fastfetch-$FF_VERSION" ] || {
    curl -sL -o fastfetch.tar.gz "https://github.com/fastfetch-cli/fastfetch/archive/refs/tags/$FF_VERSION.tar.gz"
    tar xzf fastfetch.tar.gz
}

# modules that cannot answer on a headless MIPS ONU: no desktop, GPU, battery, bluetooth, ports
MODULES_DISABLE="battery bluetooth bluetoothradio bootmgr brightness btrfs camera chassis codec cursor
display editor font gamepad gpu icons keyboard lm media monitor mouse opencl opengl physicaldisk
physicalmemory player poweradapter publicip sound terminalfont terminaltheme theme top tpm vulkan
wallpaper weather wifi wm wmtheme zpool"

# opkg is the one manager a Realtek SDK build plausibly has; the rest is dead code
PACKAGES_DISABLE="APK AM APPIMAGE BREW CARDS CHOCO CRUX DPKG EMERGE EOPKG FLATPAK GUIX HPKG
INSTALLRELEASE KISS LINGLONG LPKG LPKGBUILD MACPORTS MOSS MPORT NIX PACMAN PACSTALL PALUDIS PISI PKG
PKGTOOL PKGSRC PORG RPM RUM SCOOP SNAP SOAR SORCERY WINGET XBPS"

FF_FLAGS=""
for m in $MODULES_DISABLE; do
    FF_FLAGS="$FF_FLAGS -DMODULE_DISABLE_$(echo "$m" | tr 'a-z' 'A-Z')=ON"
done
for p in $PACKAGES_DISABLE; do
    FF_FLAGS="$FF_FLAGS -DPACKAGES_DISABLE_$p=ON"
done

cmake -S "fastfetch-$FF_VERSION" -B build \
    -DCMAKE_TOOLCHAIN_FILE="$ROOT/toolchain.cmake" \
    -DCMAKE_BUILD_TYPE=MinSizeRel \
    -DCMAKE_C_FLAGS=-Wno-date-time \
    -DCMAKE_EXE_LINKER_FLAGS=-static \
    -DBUILD_FLASHFETCH=OFF -DBUILD_TESTS=OFF \
    -DENABLE_LTO=OFF -DENABLE_LIBZFS=OFF \
    -DENABLE_IMAGE_LOGO=OFF -DENABLE_SIXEL=OFF -DENABLE_CHAFA=OFF \
    -DENABLE_IMAGEMAGICK6=OFF -DENABLE_IMAGEMAGICK7=OFF \
    -DENABLE_LUA=OFF -DENABLE_QUICKJS=OFF -DENABLE_WORDEXP=OFF \
    -DPACKAGES_REMOVE_DISABLED=ON \
    $FF_FLAGS >/dev/null

cmake --build build --target fastfetch -j"$(sysctl -n hw.ncpu 2>/dev/null || echo 4)" >/dev/null 2>&1 || {
    cmake --build build --target fastfetch -j4 2>&1 | grep -v 'warning:' | tail -30; exit 1; }
ls -l build/fastfetch
file build/fastfetch
