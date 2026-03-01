#!/bin/bash
set -e

# Configuration
VERSION="47.1.1"
REPO_ROOT="$(pwd)"
PROJECT_DIR="$REPO_ROOT/sudoku-source-$VERSION"
DEPS_PREFIX="$REPO_ROOT/deps-dist"
APPDIR="$REPO_ROOT/AppDir"

# Export paths for build - include lib64 for Fedora
export PATH="$DEPS_PREFIX/bin:$REPO_ROOT/venv_build/bin:$PATH"
export PKG_CONFIG_PATH="$DEPS_PREFIX/lib64/pkgconfig:$DEPS_PREFIX/lib/pkgconfig:$DEPS_PREFIX/share/pkgconfig:$PKG_CONFIG_PATH"
export LD_LIBRARY_PATH="$DEPS_PREFIX/lib64:$DEPS_PREFIX/lib:$LD_LIBRARY_PATH"
export XDG_DATA_DIRS="$DEPS_PREFIX/share:$XDG_DATA_DIRS"

# Fix Vala finding packages
export VALAFLAGS="--vapidir=$DEPS_PREFIX/share/vala/vapi --vapidir=/usr/share/vala/vapi --pkg=pangocairo"

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
sed -i "s|blueprintc = find_program('blueprint-compiler', version: '>= 0.16')|blueprintc = find_program('$REPO_ROOT/blueprint-wrapper.sh')|" meson.build || true

rm -rf build
meson setup build --prefix=/usr --buildtype=release
meson compile -C build
DESTDIR="$APPDIR" meson install -C build

echo "=== Creating AppImage ==="
cd "$REPO_ROOT"

# Create basic AppDir structure
mkdir -p "$APPDIR/usr/bin"
mkdir -p "$APPDIR/usr/lib"

# Copy our custom built dependencies into AppDir if they exist
if [ -d "$DEPS_PREFIX/lib" ]; then
    find "$DEPS_PREFIX/lib" -maxdepth 1 -name "*.so*" -exec cp -P {} "$APPDIR/usr/lib/" \; || true
fi
if [ -d "$DEPS_PREFIX/lib64" ]; then
    find "$DEPS_PREFIX/lib64" -maxdepth 1 -name "*.so*" -exec cp -P {} "$APPDIR/usr/lib/" \; || true
fi

# Download linuxdeploy and its AppImage plugin if not present
if [ ! -f linuxdeploy ]; then
    wget -q https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage -O linuxdeploy
    chmod +x linuxdeploy
fi
if [ ! -f linuxdeploy-plugin-appimage.AppImage ]; then
    wget -q https://github.com/linuxdeploy/linuxdeploy-plugin-appimage/releases/download/continuous/linuxdeploy-plugin-appimage-x86_64.AppImage -O linuxdeploy-plugin-appimage.AppImage
    chmod +x linuxdeploy-plugin-appimage.AppImage
fi

# Extract tools to avoid FUSE dependency in containers
rm -rf squashfs-root
./linuxdeploy --appimage-extract
mv squashfs-root linuxdeploy-root

rm -rf squashfs-root
./linuxdeploy-plugin-appimage.AppImage --appimage-extract
mv squashfs-root plugin-appimage-root

# Use extracted tools
export APPIMAGE_EXTRACT_AND_RUN=1
export OUTPUT="Sudoku-${VERSION}-x86_64.AppImage"

# Use system strip to avoid "Unable to recognise the format" errors
export STRIP="/usr/bin/strip"

# Ensure plugin is in PATH for linuxdeploy to find it
export PATH="$(pwd)/plugin-appimage-root/usr/bin:$PATH"

./linuxdeploy-root/AppRun --appdir "$APPDIR" \
    --executable "$APPDIR/usr/bin/gnome-sudoku" \
    --desktop-file "$APPDIR/usr/share/applications/org.gnome.Sudoku.desktop" \
    --icon-file "$APPDIR/usr/share/icons/hicolor/scalable/apps/org.gnome.Sudoku.svg" \
    --output appimage

echo "AppImage created: $OUTPUT"
