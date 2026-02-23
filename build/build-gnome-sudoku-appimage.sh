#!/bin/bash
set -e
export APPIMAGE_EXTRACT_AND_RUN=1
VERSION="49.4"
REPO_URL="https://gitlab.gnome.org/GNOME/gnome-sudoku.git"
PROJECT_DIR="gnome-sudoku-$VERSION"
APPDIR="AppDir"

cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"

rm -rf "$APPDIR" "$PROJECT_DIR"
mkdir -p "$APPDIR"

# 1. Fetch source
git clone --depth 1 --branch "$VERSION" "$REPO_URL" "$PROJECT_DIR"

# 2. Patch for Ubuntu 24.04 libraries (GLib 2.80, GTK 4.14)
# Sudoku 49.x might want GLib 2.82 or GTK 4.18, let's lower it.
sed -i "s/glib_version = '2.82.0'/glib_version = '2.80.0'/g" "$PROJECT_DIR/meson.build" || true
sed -i "s/gtk4', version: '>= 4.18.0'/gtk4', version: '>= 4.14.0'/g" "$PROJECT_DIR/meson.build" || true
sed -i "s/libadwaita-1', version: '>= 1.7'/libadwaita-1', version: '>= 1.5'/g" "$PROJECT_DIR/meson.build" || true

# 3. Build
cd "$PROJECT_DIR"
meson setup build --prefix=/usr -Dbuildtype=release
meson compile -C build
DESTDIR="$REPO_ROOT/$APPDIR" meson install -C build
cd "$REPO_ROOT"

# 4. Handle GIO and GSettings
mkdir -p "$APPDIR/usr/lib/x86_64-linux-gnu/gio/modules"
cp /usr/lib/x86_64-linux-gnu/gio/modules/libdconfsettings.so "$APPDIR/usr/lib/x86_64-linux-gnu/gio/modules/" || true
cp /usr/lib/x86_64-linux-gnu/gio/modules/libgiognutls.so "$APPDIR/usr/lib/x86_64-linux-gnu/gio/modules/" || true

# Compile schemas
glib-compile-schemas "$APPDIR/usr/share/glib-2.0/schemas"

# 5. Packaging
wget -q https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage -O linuxdeploy
wget -q https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/master/linuxdeploy-plugin-gtk.sh -O linuxdeploy-plugin-gtk.sh
chmod +x linuxdeploy linuxdeploy-plugin-gtk.sh

# Find desktop and icon
DESKTOP_FILE=$(find "$APPDIR" -name "org.gnome.Sudoku.desktop")
ICON_FILE=$(find "$APPDIR" -name "org.gnome.Sudoku.svg" | grep -v "symbolic" | head -n 1)

export VERSION
./linuxdeploy --appdir "$APPDIR" \
    -e "$APPDIR/usr/bin/gnome-sudoku" \
    ${DESKTOP_FILE:+ -d "$DESKTOP_FILE"} \
    ${ICON_FILE:+ -i "$ICON_FILE"} \
    --plugin gtk \
    --output appimage

echo "Done!"
