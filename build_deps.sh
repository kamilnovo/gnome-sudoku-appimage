#!/bin/bash
set -e

# Setup paths
export REPO_ROOT="$PWD"
export DEPS_PREFIX="$REPO_ROOT/deps-dist"
export PATH="$DEPS_PREFIX/bin:$REPO_ROOT/venv_build/bin:$PATH"
export PKG_CONFIG_PATH="$DEPS_PREFIX/lib/x86_64-linux-gnu/pkgconfig:$DEPS_PREFIX/lib/pkgconfig:$DEPS_PREFIX/share/pkgconfig:$PKG_CONFIG_PATH"
export LD_LIBRARY_PATH="$DEPS_PREFIX/lib/x86_64-linux-gnu:$DEPS_PREFIX/lib:$LD_LIBRARY_PATH"
export PYTHONPATH="$DEPS_PREFIX/lib/python3/dist-packages:$PYTHONPATH"

mkdir -p "$DEPS_PREFIX/bin"
MESON="$REPO_ROOT/venv_build/bin/meson"

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
    echo "=== Building $name ==="
    local actual_src="$REPO_ROOT/$src_dir"
    cd "$actual_src"
    rm -rf build
    "$MESON" setup build . --prefix="$DEPS_PREFIX" -Dbuildtype=release $extra_args
    "$MESON" compile -C build
    "$MESON" install -C build
    cd "$REPO_ROOT"
}

# 1. GLib (Need >= 2.76)
if [ ! -f "$DEPS_PREFIX/lib/x86_64-linux-gnu/pkgconfig/glib-2.0.pc" ]; then
    wget -q https://download.gnome.org/sources/glib/2.78/glib-2.78.0.tar.xz -O glib.tar.xz
    safe_extract glib.tar.xz glib-src
    build_component "GLib" "glib-src" "-Dtests=false"
fi

# 2. GTK 4 (Need >= 4.12 for Sudoku 47)
if [ ! -f "$DEPS_PREFIX/lib/x86_64-linux-gnu/pkgconfig/gtk4.pc" ]; then
    wget -q https://download.gnome.org/sources/gtk/4.12/gtk-4.12.5.tar.xz -O gtk.tar.xz
    safe_extract gtk.tar.xz gtk-src
    build_component "GTK4" "gtk-src" "-Dbuild-examples=false -Dbuild-tests=false -Dintrospection=enabled -Dmedia-gstreamer=disabled"
fi

# 3. Libadwaita (Need >= 1.6)
if [ ! -f "$DEPS_PREFIX/lib/x86_64-linux-gnu/pkgconfig/libadwaita-1.pc" ]; then
    wget -q https://download.gnome.org/sources/libadwaita/1.6/libadwaita-1.6.0.tar.xz -O adwaita.tar.xz
    safe_extract adwaita.tar.xz adwaita-src
    # Force it to use our built GTK4 and not try to build its own
    build_component "Libadwaita" "adwaita-src" "-Dintrospection=enabled -Dtests=false -Dexamples=false -Dvapi=true"
fi

# 4. Blueprint
if [ ! -f "$DEPS_PREFIX/bin/blueprint-compiler" ]; then
    wget -q https://gitlab.gnome.org/jwestman/blueprint-compiler/-/archive/v0.16.0/blueprint-compiler-v0.16.0.tar.gz -O blueprint.tar.gz
    safe_extract blueprint.tar.gz blueprint-src
    build_component "Blueprint" "blueprint-src" ""
fi

# 5. qqwing
if [ ! -f "$DEPS_PREFIX/lib/pkgconfig/qqwing.pc" ]; then
    wget -q https://qqwing.com/qqwing-1.3.4.tar.gz -O qqwing.tar.gz
    safe_extract qqwing.tar.gz qqwing-src
    cd qqwing-src
    ./configure --prefix="$DEPS_PREFIX"
    make -j$(nproc) install
    cd "$REPO_ROOT"
fi

echo "All dependencies prepared in $DEPS_PREFIX"
