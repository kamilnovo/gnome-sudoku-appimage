#!/bin/bash
set -e
export APPIMAGE_EXTRACT_AND_RUN=1
VERSION="49.4"
REPO_URL="https://gitlab.gnome.org/GNOME/gnome-sudoku.git"
PROJECT_DIR="gnome-sudoku-$VERSION"
APPDIR="AppDir"

cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"

rm -rf "$APPDIR" "$PROJECT_DIR" blueprint-dest
mkdir -p "$APPDIR"

# 1. Build blueprint-compiler (Debian 12 doesn't have it)
echo "=== Building blueprint-compiler ==-"
git clone --depth 1 --branch v0.16.0 https://gitlab.gnome.org/jwestman/blueprint-compiler.git
cd blueprint-compiler
meson setup build --prefix=/usr
DESTDIR="$REPO_ROOT/blueprint-dest" meson install -C build
export PATH="$REPO_ROOT/blueprint-dest/usr/bin:$PATH"
export PYTHONPATH="$REPO_ROOT/blueprint-dest/usr/lib/python3/dist-packages:$REPO_ROOT/blueprint-dest/usr/local/lib/python3/dist-packages:$PYTHONPATH"
cd "$REPO_ROOT"

# 2. Fetch Sudoku source
echo "=== Fetching gnome-sudoku $VERSION ==-"
git clone --depth 1 --branch "$VERSION" "$REPO_URL" "$PROJECT_DIR"

# 3. Patch for Debian 12 libraries (GTK 4.8, Libadwaita 1.2)
# This is a massive downgrade, but it's the only way to avoid building the whole world
echo "=== Patching Sudoku for Debian 12 ==-"
sed -i "s/glib_version = '[0-9.]*'/glib_version = '2.74.0'/g" "$PROJECT_DIR/meson.build" || true
sed -i "s/gtk4', version: '>= [0-9.]*'/gtk4', version: '>= 4.8.0'/g" "$PROJECT_DIR/meson.build" || true
sed -i "s/libadwaita-1', version: '>= [0-9.]*'/libadwaita-1', version: '>= 1.2.0'/g" "$PROJECT_DIR/meson.build" || true

echo "=== Verified patched meson.build ==-"
grep -E "glib_version|gtk4|libadwaita-1" "$PROJECT_DIR/meson.build"

# Patch blueprints for older Libadwaita
sed -i 's/Adw.PreferencesDialog/Adw.PreferencesWindow/g' "$PROJECT_DIR/src/blueprints/preferences-dialog.blp" || true
sed -i 's/Adw.Dialog/Adw.Window/g' "$PROJECT_DIR/src/blueprints/print-dialog.blp" || true
sed -i '/top-bar-style: raised;/d' "$PROJECT_DIR/src/blueprints/game-view.blp" || true
sed -i '/top-bar-style: raised;/d' "$PROJECT_DIR/src/blueprints/start-view.blp" || true
sed -i '/top-bar-style: raised;/d' "$PROJECT_DIR/src/blueprints/print-dialog.blp" || true
sed -i '/enable-transitions: true;/d' "$PROJECT_DIR/src/blueprints/window.blp" || true
sed -i '/content-width:/d' "$PROJECT_DIR/src/blueprints/print-dialog.blp" || true
sed -i '/default-widget:/d' "$PROJECT_DIR/src/blueprints/print-dialog.blp" || true

# Patch Vala code
# 1. Disable set_accent_color logic (needs Libadwaita 1.6+)
# We replace the body content with just a return statement
sed -i '/void set_accent_color ()/,/}/ s/var color = style_manager.get_accent_color ();/return;/' "$PROJECT_DIR/src/window.vala" || true
# Comment out lines that might still cause semantic errors even after return
sed -i 's/accent_provider.load_from_string(s);/\/\/patched/' "$PROJECT_DIR/src/window.vala" || true

# 2. Fix Adw.Dialog vs Adw.Window in window.vala (the .blp template change needs Vala change)
sed -i 's/Adw.Dialog/Adw.Window/g' "$PROJECT_DIR/src/print-dialog.vala" || true
sed -i 's/Adw.PreferencesDialog/Adw.PreferencesWindow/g' "$PROJECT_DIR/src/preferences-dialog.vala" || true

# 3. C++ fixes
sed -i '1i #include <ctime>\n#include <cstdlib>' "$PROJECT_DIR/lib/qqwing-wrapper.cpp"
sed -i 's/srand\s*(.*)/srand(time(NULL))/g' "$PROJECT_DIR/lib/qqwing-wrapper.cpp"

# 4. Build Sudoku
cd "$PROJECT_DIR"
meson setup build --prefix=/usr -Dbuildtype=release
meson compile -C build -v
DESTDIR="$REPO_ROOT/$APPDIR" meson install -C build
cd "$REPO_ROOT"

# 5. Packaging
wget -q https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage -O linuxdeploy
wget -q https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage -O appimagetool
chmod +x linuxdeploy appimagetool

export PATH="$PWD:$PATH"
export VERSION

# Find desktop and icon
DESKTOP_FILE=$(find "$APPDIR" -name "org.gnome.Sudoku.desktop")
ICON_FILE=$(find "$APPDIR" -name "org.gnome.Sudoku.svg" | grep -v "symbolic" | head -n 1)

./linuxdeploy --appdir "$APPDIR" \
    -e "$APPDIR/usr/bin/gnome-sudoku" \
    ${DESKTOP_FILE:+ -d "$DESKTOP_FILE"} \
    ${ICON_FILE:+ -i "$ICON_FILE"} \
    --output appimage

mv *.AppImage "$REPO_ROOT/" 2>/dev/null || true
echo "Done!"
