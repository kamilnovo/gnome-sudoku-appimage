#!/bin/bash
set -e

# Setup paths
export REPO_ROOT="$PWD"
export DEPS_PREFIX="$REPO_ROOT/deps-dist"
# Force our prefix to be FIRST in all paths
export PATH="$DEPS_PREFIX/bin:$REPO_ROOT/venv_build/bin:$PATH"
export PKG_CONFIG_PATH="$DEPS_PREFIX/lib64/pkgconfig:$DEPS_PREFIX/lib/pkgconfig:$DEPS_PREFIX/share/pkgconfig:$PKG_CONFIG_PATH"
export LD_LIBRARY_PATH="$DEPS_PREFIX/lib64:$DEPS_PREFIX/lib:$LD_LIBRARY_PATH"
export PYTHONPATH="$DEPS_PREFIX/lib/python3/site-packages:$PYTHONPATH"

mkdir -p "$DEPS_PREFIX/bin"

# Use absolute paths for Meson
MESON="$REPO_ROOT/venv_build/bin/meson"

check_dep() {
    local pkg=$1
    local version=$2
    if pkg-config --atleast-version="$version" "$pkg"; then
        echo "System $pkg is adequate (>= $version)"
        return 0
    else
        echo "System $pkg is missing or too old (< $version), will build from source"
        return 1
    fi
}

safe_extract() {
    local tarball=$1
    local dir=$2
    echo "Extracting $tarball to $dir..."
    mkdir -p "$dir"
    tar -xf "$tarball" -C "$dir" --strip-components=1 || tar -xf "$tarball" -C "$dir"
}

build_component() {
    local name=$1
    local src_dir=$2
    local extra_args=$3
    local check_file=$4

    echo "=== Building $name ==="
    
    local actual_src="$REPO_ROOT/$src_dir"
    if [ ! -f "$actual_src/meson.build" ]; then
        actual_src=$(grep -r "project(" "$REPO_ROOT/$src_dir" --include="meson.build" -l | head -n 1 | xargs dirname || true)
    fi

    if [ -z "$actual_src" ] || [ ! -f "$actual_src/meson.build" ]; then
        echo "Error: Could not find root meson.build in $src_dir"
        exit 1
    fi
    
    actual_src=$(realpath "$actual_src")
    local build_dir="$actual_src/build"
    
    rm -rf "$build_dir"
    cd "$actual_src"
    "$MESON" setup "$build_dir" . --prefix="$DEPS_PREFIX" --libdir="lib" -Dbuildtype=release $extra_args
    
    "$MESON" compile -C "$build_dir"
    "$MESON" install -C "$build_dir"
    cd "$REPO_ROOT"
    echo "Successfully built and installed $name"
}

# 1. Blueprint Compiler (always needed)
if [ ! -f "$DEPS_PREFIX/bin/blueprint-compiler" ]; then
    echo "Building Blueprint Compiler..."
    if [ -d "blueprint-src" ]; then rm -rf blueprint-src; fi
    wget -q https://gitlab.gnome.org/jwestman/blueprint-compiler/-/archive/v0.16.0/blueprint-compiler-v0.16.0.tar.gz -O blueprint.tar.gz
    safe_extract blueprint.tar.gz blueprint-src
    build_component "Blueprint" "blueprint-src" "" "bin/blueprint-compiler"
fi

# 2. Libadwaita (check if system has >= 1.6)
if ! check_dep libadwaita-1 1.6; then
    if [ ! -f "$DEPS_PREFIX/lib/pkgconfig/libadwaita-1.pc" ]; then
        echo "Building Libadwaita from source..."
        if [ -d "adwaita-src" ]; then rm -rf adwaita-src; fi
        wget -q https://download.gnome.org/sources/libadwaita/1.7/libadwaita-1.7.0.tar.xz -O adwaita.tar.xz
        safe_extract adwaita.tar.xz adwaita-src
        build_component "Libadwaita" "adwaita-src" "-Dintrospection=enabled -Dtests=false -Dexamples=false -Dvapi=true" "lib/pkgconfig/libadwaita-1.pc"
    fi
fi

echo "All dependencies prepared in $DEPS_PREFIX"
