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

# Patch blueprints surgically
for f in "$PROJECT_DIR"/src/blueprints/*.blp; do
    echo "Patching Blueprint: $f"
    
    # 1. Widget Downgrades
    sed -i 's/Adw.ToolbarView/Gtk.Box/g' "$f"
    sed -i 's/Adw.WindowTitle/Gtk.Label/g' "$f"
    sed -i 's/Adw.Dialog/Adw.Window/g' "$f"
    sed -i 's/Adw.PreferencesDialog/Adw.PreferencesWindow/g' "$f"
    
    # 2. Property labels and slot markers (Surgically remove 'content:', 'child:', '[top]', etc.)
    # Handle 'property: Widget {' and 'property: Widget;'
    perl -0777 -pi -e 's/\b(content|child|default-widget|focus-widget):\s*//g' "$f"
    perl -pi -e 's/\[(top|bottom|content|child)\]\s*//g' "$f"

    # 3. Handle Adw.SpinRow and Adw.SwitchRow (Added in 1.4)
    # Convert to ActionRow + suffix
    perl -0777 -pi -e 's/Adw.SpinRow\s+([a-zA-Z0-9_]+)\s*\{((?:[^{}]|\{(?2)\})*)\}/Adw.ActionRow { $2 suffix: Gtk.SpinButton $1 { valign: center; }; }/g' "$f"
    perl -0777 -pi -e 's/Adw.SwitchRow\s+([a-zA-Z0-9_]+)\s*\{((?:[^{}]|\{(?2)\})*)\}/Adw.ActionRow { $2 suffix: Gtk.Switch $1 { valign: center; }; }/g' "$f"

    # 4. Correct Gtk.Label properties (title -> label, remove subtitle)
    perl -0777 -pi -e 's/Gtk.Label\s*\{((?:[^{}]|\{(?1)\})*)\}/
        my $c = $1;
        $c =~ s#\btitle:#label:#g;
        $c =~ s#\bsubtitle:[^;]+;##g;
        "Gtk.Label {$c}"
    /gex' "$f"

    # 5. Semicolon Purge: Semicolons after widget blocks are forbidden in Blueprint.
    # Convert '};' to '}' globally.
    sed -i 's/};/}/g' "$f"
    
    # 6. Remove modern Adw/Gtk properties
    sed -i '/top-bar-style:/d' "$f"
    sed -i '/centering-policy:/d' "$f"
    sed -i '/enable-transitions:/d' "$f"
    sed -i '/content-width:/d' "$f"
    sed -i '/content-height:/d' "$f"
done

# Patch Vala Code surgically
echo "=== Patching Vala code ==-"

# window.vala
perl -0777 -pi -e 's/notify\s*\[\s*"visible-dialog"\s*\]/\/\/notify/g' "$PROJECT_DIR/src/window.vala"
perl -0777 -pi -e 's/private\s+void\s+visible_dialog_cb\s*\(\)\s*\{((?:[^{}]|\{(?1)\})*)\}/private void visible_dialog_cb () { }/g' "$PROJECT_DIR/src/window.vala"
perl -0777 -pi -e 's/void\s+set_accent_color\s*\(\)\s*\{((?:[^{}]|\{(?1)\})*)\}/void set_accent_color () { }/g' "$PROJECT_DIR/src/window.vala"
perl -0777 -pi -e 's/style_manager.notify\s*\[\s*"accent-color"\s*\]/\/\/style_manager.notify/g' "$PROJECT_DIR/src/window.vala"
perl -pi -e 's/load_from_string\s*\(\s*s\s*\)/load_from_data(s.data)/g' "$PROJECT_DIR/src/window.vala"
perl -pi -e 's/dispose_template\s*\(\s*this.get_type\s*\(\)\s*\);/\/\/dispose_template/g' "$PROJECT_DIR/src/window.vala"

# gnome-sudoku.vala
perl -pi -e 's/ApplicationFlags.DEFAULT_FLAGS/ApplicationFlags.FLAGS_NONE/g' "$PROJECT_DIR/src/gnome-sudoku.vala"
perl -pi -e 's/\.present\s*\(\s*window\s*\)/.present()/g' "$PROJECT_DIR/src/gnome-sudoku.vala"
perl -0777 -pi -e 's/var\s+dialog\s*=\s*new\s+Adw.AlertDialog\s*\(([^,]+),?\s*([^)]*)\);/var dialog = new Adw.MessageDialog(window, $1, $2);/g' "$PROJECT_DIR/src/gnome-sudoku.vala"
perl -0777 -pi -e 's/var\s+about_dialog\s*=\s*new\s+Adw.AboutDialog.from_appdata\s*\(([^,]+),\s*VERSION\);/var about_dialog = new Gtk.AboutDialog(); about_dialog.set_version(VERSION); about_dialog.set_transient_for(window);/g' "$PROJECT_DIR/src/gnome-sudoku.vala"

# preferences-dialog.vala
sed -i 's/Adw.PreferencesDialog/Adw.PreferencesWindow/g' "$PROJECT_DIR/src/preferences-dialog.vala"
perl -pi -e 's/unowned\s+Adw.SwitchRow/unowned Gtk.Switch/g' "$PROJECT_DIR/src/preferences-dialog.vala"
perl -pi -e 's/dispose_template\s*\(\s*this.get_type\s*\(\)\s*\);/\/\/dispose_template/g' "$PROJECT_DIR/src/preferences-dialog.vala"

# print-dialog.vala
sed -i 's/Adw.Dialog/Adw.Window/g' "$PROJECT_DIR/src/print-dialog.vala"
perl -pi -e 's/unowned\s+Adw.SpinRow/unowned Gtk.SpinButton/g' "$PROJECT_DIR/src/print-dialog.vala"

# printer.vala
perl -pi -e 's/Pango.cairo_create_layout/Pango.Cairo.create_layout/g' "$PROJECT_DIR/src/printer.vala"
perl -pi -e 's/Pango.cairo_show_layout/Pango.Cairo.show_layout/g' "$PROJECT_DIR/src/printer.vala"
perl -0777 -pi -e 's/var\s+dialog\s*=\s*new\s+Adw.AlertDialog\s*\(([^,]+),?\s*([^)]*)\);/var dialog = new Adw.MessageDialog(window, $1, $2);/g' "$PROJECT_DIR/src/printer.vala"

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
