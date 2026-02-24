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

# 1. Build blueprint-compiler from source (Ubuntu 24.04 version is too old)
echo "=== Building blueprint-compiler ==-"
git clone --depth 1 --branch v0.16.0 https://gitlab.gnome.org/jwestman/blueprint-compiler.git
cd blueprint-compiler
meson setup build --prefix=/usr
DESTDIR="$REPO_ROOT/blueprint-dest" meson install -C build
export PATH="$REPO_ROOT/blueprint-dest/usr/bin:$PATH"
export PYTHONPATH="$REPO_ROOT/blueprint-dest/usr/lib/python3/dist-packages:$PYTHONPATH"
cd "$REPO_ROOT"

# 2. Fetch source
echo "=== Fetching gnome-sudoku $VERSION ==-"
git clone --depth 1 --branch "$VERSION" "$REPO_URL" "$PROJECT_DIR"

# 2. Patch for Ubuntu 24.04 libraries (GLib 2.80, GTK 4.14, Adwaita 1.5)
# Fix C++ compatibility in qqwing-wrapper.cpp
sed -i '1i #include <ctime>\n#include <cstdlib>' "$PROJECT_DIR/lib/qqwing-wrapper.cpp"
sed -i 's/srand(time(nullptr))/std::srand(std::time(nullptr))/g' "$PROJECT_DIR/lib/qqwing-wrapper.cpp"
echo "=== Patched qqwing-wrapper.cpp ==="
head -n 30 "$PROJECT_DIR/lib/qqwing-wrapper.cpp"

# Sudoku 49.x might want GLib 2.82 or GTK 4.18, let's lower it.
sed -i "s/glib_version = '2.82.0'/glib_version = '2.80.0'/g" "$PROJECT_DIR/meson.build" || true
sed -i "s/gtk4', version: '>= 4.18.0'/gtk4', version: '>= 4.14.0'/g" "$PROJECT_DIR/meson.build" || true
sed -i "s/libadwaita-1', version: '>= 1.7'/libadwaita-1', version: '>= 1.5'/g" "$PROJECT_DIR/meson.build" || true

# Patch blueprint files for properties introduced in newer Libadwaita
sed -i '/enable-transitions: true;/d' "$PROJECT_DIR/src/blueprints/window.blp" || true

# Downgrade Adw.PreferencesDialog to Adw.PreferencesWindow (introduced in 1.5 vs 1.0)
# Downgrade Adw.Dialog to Adw.Window (introduced in 1.5 vs 1.0)
# Note: Ubuntu 24.04 has 1.5.0, but Sudoku 49.4 seems to use 1.6/1.7 features
sed -i 's/Adw.PreferencesDialog/Adw.PreferencesWindow/g' "$PROJECT_DIR/src/blueprints/preferences-dialog.blp" || true
sed -i 's/Adw.Dialog/Adw.Window/g' "$PROJECT_DIR/src/blueprints/print-dialog.blp" || true

# Remove properties that don't exist in Adw.Window but exist in Adw.Dialog
sed -i '/content-width:/d' "$PROJECT_DIR/src/blueprints/print-dialog.blp" || true
sed -i '/content-height:/d' "$PROJECT_DIR/src/blueprints/print-dialog.blp" || true
sed -i '/default-widget:/d' "$PROJECT_DIR/src/blueprints/print-dialog.blp" || true
sed -i '/focus-widget:/d' "$PROJECT_DIR/src/blueprints/print-dialog.blp" || true

# 3. Build
cd "$PROJECT_DIR"
meson setup build --prefix=/usr -Dbuildtype=release
meson compile -C build -v
DESTDIR="$REPO_ROOT/$APPDIR" meson install -C build
cd "$REPO_ROOT"

# 4. Handle GIO and GSettings
mkdir -p "$APPDIR/usr/lib/x86_64-linux-gnu/gio/modules"
cp /usr/lib/x86_64-linux-gnu/gio/modules/libdconfsettings.so "$APPDIR/usr/lib/x86_64-linux-gnu/gio/modules/" || true
cp /usr/lib/x86_64-linux-gnu/gio/modules/libgiognutls.so "$APPDIR/usr/lib/x86_64-linux-gnu/gio/modules/" || true

# Copy system schemas that Sudoku might depend on
mkdir -p "$APPDIR/usr/share/glib-2.0/schemas"
cp /usr/share/glib-2.0/schemas/org.gnome.settings-daemon.enums.xml "$APPDIR/usr/share/glib-2.0/schemas/" 2>/dev/null || true
cp /usr/share/glib-2.0/schemas/org.gnome.desktop.interface.gschema.xml "$APPDIR/usr/share/glib-2.0/schemas/" 2>/dev/null || true

# Compile schemas
glib-compile-schemas "$APPDIR/usr/share/glib-2.0/schemas"

# 5. Packaging
set -x
wget -q https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage -O linuxdeploy
wget -q https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage -O appimagetool
wget -q https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/master/linuxdeploy-plugin-gtk.sh -O linuxdeploy-plugin-gtk.sh
chmod +x linuxdeploy appimagetool linuxdeploy-plugin-gtk.sh

# Add appimagetool to PATH so linuxdeploy can find it
export PATH="$PWD:$PATH"

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

echo "=== Current Directory Content ==="
ls -lh

# Move AppImage to root for GitHub Actions artifact upload
echo "Moving AppImage to $REPO_ROOT"
find . -maxdepth 1 -name "*.AppImage" -exec mv {} "$REPO_ROOT/" \;

echo "=== Root Directory Content ==="
ls -lh "$REPO_ROOT"/*.AppImage || echo "No AppImage in root"

echo "Done!"
