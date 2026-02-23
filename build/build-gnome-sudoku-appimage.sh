#!/bin/bash
set -e
export APPIMAGE_EXTRACT_AND_RUN=1
VERSION="49.4"
REPO_URL="https://gitlab.gnome.org/GNOME/gnome-sudoku.git"
PROJECT_DIR="gnome-sudoku-$VERSION"
APPDIR="AppDir"

cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"
echo "Repo root: $REPO_ROOT"

rm -rf "$APPDIR" "$PROJECT_DIR" blueprint-dest gtk-dest
mkdir -p "$APPDIR"

# Helper for building deps
build_dep() {
    local name=$1 url=$2 version=$3 dest=$4
    echo "=== Building $name $version ==-"
    git clone --depth 1 --branch "$version" "$url" "$name-src"
    cd "$name-src"
    meson setup build --prefix=/usr --libdir=lib
    DESTDIR="$dest" meson install -C build
    export PKG_CONFIG_PATH="$dest/usr/lib/pkgconfig:$PKG_CONFIG_PATH"
    export LD_LIBRARY_PATH="$dest/usr/lib:$LD_LIBRARY_PATH"
    export PATH="$dest/usr/bin:$PATH"
    cd "$REPO_ROOT"
}

# 1. Build dependencies from source
build_dep "blueprint-compiler" "https://gitlab.gnome.org/jwestman/blueprint-compiler.git" "v0.16.0" "$REPO_ROOT/blueprint-dest"
build_dep "gtk" "https://gitlab.gnome.org/GNOME/gtk.git" "4.14.4" "$REPO_ROOT/gtk-dest"
build_dep "libadwaita" "https://gitlab.gnome.org/GNOME/libadwaita.git" "v1.5.0" "$REPO_ROOT/gtk-dest"

# 2. Build gnome-sudoku
echo "=== Fetching gnome-sudoku $VERSION ==-"
git clone --depth 1 --branch "$VERSION" "$REPO_URL" "$PROJECT_DIR"
cd "$PROJECT_DIR"
echo "=== Building gnome-sudoku ==-"
meson setup build --prefix=/usr -Dbuildtype=release
meson compile -C build
DESTDIR="$REPO_ROOT/$APPDIR" meson install -C build
cd "$REPO_ROOT"

# 3. Bundle everything with linuxdeploy
wget -q https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage -O linuxdeploy
wget -q https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/master/linuxdeploy-plugin-gtk.sh -O linuxdeploy-plugin-gtk.sh
chmod +x linuxdeploy linuxdeploy-plugin-gtk.sh

# Copy built libs to AppDir
cp -a "$REPO_ROOT/gtk-dest/usr/lib"/* "$APPDIR/usr/lib/" 2>/dev/null || true

export VERSION
./linuxdeploy --appdir "$APPDIR" \
    -e "$APPDIR/usr/bin/gnome-sudoku" \
    --plugin gtk \
    --output appimage
