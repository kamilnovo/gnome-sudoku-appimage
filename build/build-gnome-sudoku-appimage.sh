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

# 1. Build blueprint-compiler
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
echo "=== Patching Sudoku for Debian 12 ==-"
sed -i "s/glib_version = '[0-9.]*'/glib_version = '2.74.0'/g" "$PROJECT_DIR/meson.build" || true
sed -i "s/gtk4', version: '>= [0-9.]*'/gtk4', version: '>= 4.8.0'/g" "$PROJECT_DIR/meson.build" || true
sed -i "s/libadwaita-1', version: '>= [0-9.]*'/libadwaita-1', version: '>= 1.2.0'/g" "$PROJECT_DIR/meson.build" || true

# Patch blueprints for older Libadwaita
# Massive simplification: replace complex Adw widgets with Gtk equivalents
# and remove ALL property/slot labels that might cause issues.
for f in "$PROJECT_DIR"/src/blueprints/*.blp; do
    echo "Patching $f..."
    sed -i 's/Adw.ToolbarView/Box/g' "$f"
    sed -i 's/Adw.Bin/Box/g' "$f"
    sed -i 's/Adw.WindowTitle/Label/g' "$f"
    sed -i 's/Adw.PreferencesDialog/Adw.PreferencesWindow/g' "$f"
    sed -i 's/Adw.Dialog/Adw.Window/g' "$f"
    
    # Remove slot labels
    sed -i 's/\[top\]//g' "$f"
    sed -i 's/\[bottom\]//g' "$f"
    sed -i 's/\[start\]//g' "$f"
    sed -i 's/\[end\]//g' "$f"
    
    # Remove property labels and their trailing semicolons
    sed -i 's/content: //g' "$f"
    sed -i 's/child: //g' "$f"
    # Even more aggressive semicolon removal
    sed -i 's/};/}/g' "$f"
    sed -i 's/);/)/g' "$f"
    # Remove any line that is just a semicolon or whitespace + semicolon
    sed -i '/^[[:space:]]*;[[:space:]]*$/d' "$f"
    
    # Map title: to label: for downgraded Labels
    # This is a bit rough but should work for Sudoku's simple blueprints
    sed -i 's/title: _/label: _/g' "$f"
    
    # Remove new properties
    sed -i '/top-bar-style:/d' "$f"
    sed -i '/centering-policy:/d' "$f"
    sed -i '/enable-transitions:/d' "$f"
    sed -i '/content-width:/d' "$f"
    sed -i '/content-height:/d' "$f"
    sed -i '/default-widget:/d' "$f"
    sed -i '/focus-widget:/d' "$f"
done

# Patch Vala code
# Disable call to set_accent_color
sed -i 's/set_accent_color ();/\/\/set_accent_color ();/g' "$PROJECT_DIR/src/window.vala" || true
# Dummy the function body
sed -i '/void set_accent_color ()/,/}/ s/{/{\n        return;/' "$PROJECT_DIR/src/window.vala" || true

# Fix inheritance in Vala to match downgraded blueprints
sed -i 's/Adw.Dialog/Adw.Window/g' "$PROJECT_DIR/src/print-dialog.vala" || true
sed -i 's/Adw.PreferencesDialog/Adw.PreferencesWindow/g' "$PROJECT_DIR/src/preferences-dialog.vala" || true

# C++ fixes
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
