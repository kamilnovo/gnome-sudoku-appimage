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
for f in "$PROJECT_DIR"/src/blueprints/*.blp; do
    echo "Patching $f..."
    
    # Downgrade widgets
    sed -i 's/Adw.ToolbarView/Box/g' "$f"
    sed -i 's/Adw.WindowTitle/Label/g' "$f"
    sed -i 's/Adw.Dialog/Adw.Window/g' "$f"
    sed -i 's/Adw.PreferencesDialog/Adw.PreferencesWindow/g' "$f"
    sed -i 's/Adw.SwitchRow/Adw.ActionRow/g' "$f"
    sed -i 's/Adw.SpinRow/SpinButton/g' "$f" # Downgrade SpinRow directly to SpinButton for simpler Vala matching

    # Surgical removal of content/child property wrappers
    perl -0777 -pi -e 's/(content|child):\s*([a-zA-Z0-9\.\$]+(?:\s+[a-zA-Z0-9_]+)?)\s*\{((?:[^{}]|\{(?3)\})*)\};?/\2 {\3}/g' "$f"
    perl -0777 -pi -e 's/(content|child):\s*([a-zA-Z0-9\.\$_\-]+);/\2;/g' "$f"

    # Map title: to label: for downgraded Labels
    perl -0777 -pi -e 's/Label(?:\s+[a-zA-Z0-9_]+)?\s*\{((?:[^{}]|\{(?1)\})*)\}/$c=$1; $c=~s#\btitle:#label:#g; $c=~s#\bsub(?:title|label):[^;]+;##g; "Label {$c}"/ge' "$f"

    # Remove incompatible blocks (Adjustment is fine for SpinButton)
    
    # Remove incompatible properties
    sed -i '/top-bar-style:/d' "$f"
    sed -i '/centering-policy:/d' "$f"
    sed -i '/enable-transitions:/d' "$f"
    sed -i '/content-width:/d' "$f"
    sed -i '/content-height:/d' "$f"
    sed -i '/default-widget:/d' "$f"
    sed -i '/focus-widget:/d' "$f"
    
    # Remove slot markers
    sed -i 's/\[top\]//g' "$f"
    sed -i 's/\[bottom\]//g' "$f"
done

# Patch Vala code
echo "=== Patching Vala code ==-"

# window.vala fixes
sed -i 's/notify\["visible-dialog"\]/\/\/notify\["visible-dialog"\]/g' "$PROJECT_DIR/src/window.vala"
perl -0777 -pi -e 's/private void visible_dialog_cb \(\)\s*\{((?:[^{}]|\{(?1)\})*)\}/private void visible_dialog_cb () { }/g' "$PROJECT_DIR/src/window.vala"
sed -i 's/style_manager.get_accent_color ()/Adw.ColorScheme.PREFER_LIGHT/g' "$PROJECT_DIR/src/window.vala" # Dummy value
sed -i 's/load_from_string/load_from_data/g' "$PROJECT_DIR/src/window.vala"
sed -i 's/dispose_template (this.get_type ());/\/\/dispose_template/g' "$PROJECT_DIR/src/window.vala"

# preferences-dialog.vala fixes
sed -i 's/dispose_template (this.get_type ());/\/\/dispose_template/g' "$PROJECT_DIR/src/preferences-dialog.vala"
sed -i 's/Adw.PreferencesDialog/Adw.PreferencesWindow/g' "$PROJECT_DIR/src/preferences-dialog.vala"
sed -i 's/Adw.SwitchRow/Adw.ActionRow/g' "$PROJECT_DIR/src/preferences-dialog.vala"

# print-dialog.vala fixes
sed -i 's/Adw.Dialog/Adw.Window/g' "$PROJECT_DIR/src/print-dialog.vala"
sed -i 's/Adw.SpinRow/Gtk.SpinButton/g' "$PROJECT_DIR/src/print-dialog.vala"

# printer.vala fixes
sed -i 's/Pango.cairo_create_layout/Pango.Cairo.create_layout/g' "$PROJECT_DIR/src/printer.vala"
sed -i 's/Pango.cairo_show_layout/Pango.Cairo.show_layout/g' "$PROJECT_DIR/src/printer.vala"
perl -0777 -pi -e 's/var dialog = new Adw.AlertDialog \(([^,]+), ([^)]+)\);/var dialog = new Gtk.MessageDialog (window, Gtk.DialogFlags.MODAL, Gtk.MessageType.ERROR, Gtk.ButtonsType.CLOSE, "%s", $1);/g' "$PROJECT_DIR/src/printer.vala"
sed -i 's/dialog.add_response/\/\/dialog.add_response/g' "$PROJECT_DIR/src/printer.vala"

# gnome-sudoku.vala fixes
sed -i 's/ApplicationFlags.DEFAULT_FLAGS/ApplicationFlags.FLAGS_NONE/g' "$PROJECT_DIR/src/gnome-sudoku.vala"
sed -i 's/\.present (window)/.present ()/g' "$PROJECT_DIR/src/gnome-sudoku.vala"
# Replace Adw.AboutDialog with Gtk.AboutDialog
sed -i 's/new Adw.AboutDialog.from_appdata/new Gtk.AboutDialog/g' "$PROJECT_DIR/src/gnome-sudoku.vala"
# Replace Adw.AlertDialog with Gtk.MessageDialog (simplified)
perl -0777 -pi -e 's/var dialog = new Adw.AlertDialog \(([^,]+), ([^)]+)\);/var dialog = new Gtk.MessageDialog (window, Gtk.DialogFlags.MODAL, Gtk.MessageType.INFO, Gtk.ButtonsType.OK, "%s", $1);/g' "$PROJECT_DIR/src/gnome-sudoku.vala"
sed -i 's/dialog.add_response/\/\/dialog.add_response/g' "$PROJECT_DIR/src/gnome-sudoku.vala"
sed -i 's/dialog.set_response_appearance/\/\/dialog.set_response_appearance/g' "$PROJECT_DIR/src/gnome-sudoku.vala"
sed -i 's/dialog.response.connect/\/\/dialog.response.connect/g' "$PROJECT_DIR/src/gnome-sudoku.vala"

# C++ fixes
sed -i '1i #include <ctime>\n#include <cstdlib>' "$PROJECT_DIR/lib/qqwing-wrapper.cpp"
sed -i 's/srand\s*(.*)/srand(time(NULL))/g' "$PROJECT_DIR/lib/qqwing-wrapper.cpp"

# 4. Build Sudoku
cd "$PROJECT_DIR"
# Add pangocairo explicitly to meson if needed, but usually it comes with gtk4
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
