#!/bin/bash
set -e
export APPIMAGE_EXTRACT_AND_RUN=1
VERSION="49.4"
REPO_URL="https://gitlab.gnome.org/GNOME/gnome-sudoku.git"
PROJECT_DIR="gnome-sudoku-$VERSION"
APPDIR="AppDir"

cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"

rm -rf "$APPDIR" "$PROJECT_DIR" deps-src deps-dest
mkdir -p "$APPDIR" deps-dest

# Helper for building deps from source on old systems
build_dep() {
    local name=$1 url=$2 version=$3
    echo "=== Building $name $version ==-"
    mkdir -p "deps-src/$name"
    git clone --depth 1 --branch "$version" "$url" "deps-src/$name"
    cd "deps-src/$name"
    # GLib needs special options to avoid system conflict
    if [ "$name" == "glib" ]; then
        meson setup build --prefix=/usr --libdir=lib -Dtests=false
    else
        meson setup build --prefix=/usr --libdir=lib
    fi
    DESTDIR="$REPO_ROOT/deps-dest" meson install -C build
    cd "$REPO_ROOT"
}

# 1. Build dependencies stack (needed because Debian 12 is too old)
# Order: glib -> blueprint -> gtk -> adwaita
export PKG_CONFIG_PATH="$REPO_ROOT/deps-dest/usr/lib/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig"
export LD_LIBRARY_PATH="$REPO_ROOT/deps-dest/usr/lib:$LD_LIBRARY_PATH"
export PATH="$REPO_ROOT/deps-dest/usr/bin:$PATH"

build_dep "glib" "https://gitlab.gnome.org/GNOME/glib.git" "2.82.4"
build_dep "blueprint-compiler" "https://gitlab.gnome.org/jwestman/blueprint-compiler.git" "v0.16.0"
build_dep "gtk" "https://gitlab.gnome.org/GNOME/gtk.git" "4.16.7"
build_dep "libadwaita" "https://gitlab.gnome.org/GNOME/libadwaita.git" "v1.6.3"

# 2. Fetch Sudoku source
echo "=== Fetching gnome-sudoku $VERSION ==-"
git clone --depth 1 --branch "$VERSION" "$REPO_URL" "$PROJECT_DIR"

# 3. Build Sudoku
cd "$PROJECT_DIR"
meson setup build --prefix=/usr -Dbuildtype=release
meson compile -C build -v
DESTDIR="$REPO_ROOT/$APPDIR" meson install -C build
cd "$REPO_ROOT"

# 4. Bundle
mkdir -p "$APPDIR/usr/lib"
cp -a deps-dest/usr/lib/*.so* "$APPDIR/usr/lib/"

# Handle GIO modules and schemas from our built deps
mkdir -p "$APPDIR/usr/lib/gio/modules"
cp -a deps-dest/usr/lib/gio/modules/*.so "$APPDIR/usr/lib/gio/modules/" 2>/dev/null || true

mkdir -p "$APPDIR/usr/share/glib-2.0/schemas"
cp -a deps-dest/usr/share/glib-2.0/schemas/*.xml "$APPDIR/usr/share/glib-2.0/schemas/" 2>/dev/null || true
glib-compile-schemas "$APPDIR/usr/share/glib-2.0/schemas"

# 5. Packaging
wget -q https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage -O linuxdeploy
wget -q https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage -O appimagetool
wget -q https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/master/linuxdeploy-plugin-gtk.sh -O linuxdeploy-plugin-gtk.sh
chmod +x linuxdeploy appimagetool linuxdeploy-plugin-gtk.sh

export PATH="$PWD:$PATH"
export VERSION

# Find desktop and icon
DESKTOP_FILE=$(find "$APPDIR" -name "org.gnome.Sudoku.desktop")
ICON_FILE=$(find "$APPDIR" -name "org.gnome.Sudoku.svg" | grep -v "symbolic" | head -n 1)

./linuxdeploy --appdir "$APPDIR" \
    -e "$APPDIR/usr/bin/gnome-sudoku" \
    ${DESKTOP_FILE:+ -d "$DESKTOP_FILE"} \
    ${ICON_FILE:+ -i "$ICON_FILE"} \
    --plugin gtk \
    --output appimage

# Final move to root
mv *.AppImage "$REPO_ROOT/" 2>/dev/null || true

echo "Done! Built on Debian 12 base."
