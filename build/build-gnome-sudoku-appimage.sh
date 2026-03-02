#!/bin/bash
set -e

# Configuration
VERSION="47.1.1"
REPO_ROOT="$(pwd)"
PROJECT_DIR="$REPO_ROOT/sudoku-source-$VERSION"
DEPS_PREFIX="$REPO_ROOT/deps-dist"
APPDIR="$REPO_ROOT/AppDir"

# Export paths - ensure our custom build is FIRST
export PATH="$DEPS_PREFIX/bin:$REPO_ROOT/venv_build/bin:$PATH"
export PKG_CONFIG_PATH="$DEPS_PREFIX/lib/x86_64-linux-gnu/pkgconfig:$DEPS_PREFIX/lib/pkgconfig:$DEPS_PREFIX/share/pkgconfig:$PKG_CONFIG_PATH"
export LD_LIBRARY_PATH="$DEPS_PREFIX/lib/x86_64-linux-gnu:$DEPS_PREFIX/lib:$LD_LIBRARY_PATH"
export XDG_DATA_DIRS="$DEPS_PREFIX/share:$XDG_DATA_DIRS"

# Ensure valac finds our custom built VAPIs
export VALAFLAGS="--vapidir=$DEPS_PREFIX/share/vala/vapi --pkg=pangocairo"

echo "=== Ensuring GNOME Sudoku $VERSION source is present ==="
if [ ! -d "$PROJECT_DIR" ]; then
    wget -q https://download.gnome.org/sources/gnome-sudoku/47/gnome-sudoku-$VERSION.tar.xz
    tar -xJf gnome-sudoku-$VERSION.tar.xz
    mv gnome-sudoku-$VERSION "$PROJECT_DIR"
    rm gnome-sudoku-$VERSION.tar.xz
fi

echo "=== Building GNOME Sudoku $VERSION ==="
cd "$PROJECT_DIR"

# Use our blueprint-compiler wrapper
# Try a few common patterns or just look for 'blueprint-compiler'
sed -i "s/find_program(['\"]blueprint-compiler['\"].*)/find_program('$REPO_ROOT\/blueprint-wrapper.sh')/" meson.build
if ! grep -q "blueprint-wrapper.sh" meson.build; then
    echo "Failed to patch meson.build. Content of meson.build near blueprint-compiler:"
    grep -C 5 "blueprint-compiler" meson.build || echo "blueprint-compiler not found in meson.build"
    exit 1
fi

rm -rf build
meson setup build --prefix=/usr --buildtype=release
meson compile -C build
DESTDIR="$APPDIR" meson install -C build

echo "=== Creating AppImage ==="
cd "$REPO_ROOT"

# Create basic AppDir structure
mkdir -p "$APPDIR/usr/bin"
mkdir -p "$APPDIR/usr/lib"

# Copy our custom built dependencies into AppDir - this is critical for MX Linux compatibility
echo "=== Bundling dependencies into AppDir ==="
mkdir -p "$APPDIR/usr/lib"
mkdir -p "$APPDIR/usr/share"

# Copy all .so files from DEPS_PREFIX
find "$DEPS_PREFIX/lib" -name "*.so*" -not -path "*/pkgconfig/*" -exec cp -P {} "$APPDIR/usr/lib/" \; 2>/dev/null || true

# Copy share directory (icons, schemas, etc.)
cp -r "$DEPS_PREFIX/share/"* "$APPDIR/usr/share/" 2>/dev/null || true

# Copy GdkPixbuf loaders and GIO modules if they exist
if [ -d "$DEPS_PREFIX/lib/x86_64-linux-gnu/gdk-pixbuf-2.0" ]; then
    mkdir -p "$APPDIR/usr/lib/gdk-pixbuf-2.0"
    cp -r "$DEPS_PREFIX/lib/x86_64-linux-gnu/gdk-pixbuf-2.0/"* "$APPDIR/usr/lib/gdk-pixbuf-2.0/"
elif [ -d "$DEPS_PREFIX/lib/gdk-pixbuf-2.0" ]; then
    mkdir -p "$APPDIR/usr/lib/gdk-pixbuf-2.0"
    cp -r "$DEPS_PREFIX/lib/gdk-pixbuf-2.0/"* "$APPDIR/usr/lib/gdk-pixbuf-2.0/"
fi

if [ -d "$DEPS_PREFIX/lib/x86_64-linux-gnu/gio/modules" ]; then
    mkdir -p "$APPDIR/usr/lib/gio/modules"
    cp -r "$DEPS_PREFIX/lib/x86_64-linux-gnu/gio/modules/"* "$APPDIR/usr/lib/gio/modules/"
elif [ -d "$DEPS_PREFIX/lib/gio/modules" ]; then
    mkdir -p "$APPDIR/usr/lib/gio/modules"
    cp -r "$DEPS_PREFIX/lib/gio/modules/"* "$APPDIR/usr/lib/gio/modules/"
fi

# Compile GSettings schemas in the AppDir
if [ -d "$APPDIR/usr/share/glib-2.0/schemas" ]; then
    echo "Compiling GSettings schemas..."
    glib-compile-schemas "$APPDIR/usr/share/glib-2.0/schemas"
fi

# Download linuxdeploy and AppImage plugin
if [ ! -f linuxdeploy ]; then
    wget -q https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage -O linuxdeploy
    chmod +x linuxdeploy
fi
if [ ! -f linuxdeploy-plugin-appimage.AppImage ]; then
    wget -q https://github.com/linuxdeploy/linuxdeploy-plugin-appimage/releases/download/continuous/linuxdeploy-plugin-appimage-x86_64.AppImage -O linuxdeploy-plugin-appimage.AppImage
    chmod +x linuxdeploy-plugin-appimage.AppImage
fi
if [ ! -f linuxdeploy-plugin-gtk.sh ]; then
    wget -q https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/master/linuxdeploy-plugin-gtk.sh -O linuxdeploy-plugin-gtk.sh
    chmod +x linuxdeploy-plugin-gtk.sh
fi

# Extract tools to avoid FUSE dependency
rm -rf linuxdeploy-root plugin-appimage-root squashfs-root
./linuxdeploy --appimage-extract
mv squashfs-root linuxdeploy-root
./linuxdeploy-plugin-appimage.AppImage --appimage-extract
mv squashfs-root plugin-appimage-root

export APPIMAGE_EXTRACT_AND_RUN=1
export NO_STRIP=1
export STRIP="/usr/bin/strip"
export PATH="$(pwd)/plugin-appimage-root/usr/bin:$PATH"

# Bundle everything
# Note: --plugin gtk will handle many GTK specific things
./linuxdeploy-root/AppRun --appdir "$APPDIR" \
    --executable "$APPDIR/usr/bin/gnome-sudoku" \
    --desktop-file "$APPDIR/usr/share/applications/org.gnome.Sudoku.desktop" \
    --icon-file "$APPDIR/usr/share/icons/hicolor/scalable/apps/org.gnome.Sudoku.svg" \
    --plugin gtk \
    --output appimage

echo "AppImage created."
