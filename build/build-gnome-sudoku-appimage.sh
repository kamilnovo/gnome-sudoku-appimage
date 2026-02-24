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

# Patch blueprints surgically using a specialized Perl script for correctness
for f in "$PROJECT_DIR"/src/blueprints/*.blp; do
    echo "Patching Blueprint: $f"
    
    # 1. Handle Adw.StatusPage (not in 1.2 with child support)
    # Convert to Box + Label
    perl -0777 -pi -e 's/Adw.StatusPage\s*\{((?:[^{}]|\{(?1)\})*)\}/
        my $c = $1;
        my $title = ($c =~ s#title:\s*(_\("[^"]+"\));##) ? $1 : "";
        $c =~ s#child:##g;
        "Gtk.Box { orientation: vertical; valign: start; Gtk.Label { label: $title; styles [\"title-1\"]; margin-bottom: 24; } $c }"
    /gex' "$f"

    # 2. Handle Adw.SpinRow and Adw.SwitchRow
    # These were added in 1.4. In 1.2 we use ActionRow + suffix.
    perl -0777 -pi -e 's/Adw.SpinRow\s+([a-zA-Z0-9_]+)\s*\{((?:[^{}]|\{(?2)\})*)\}/
        my ($id, $inner) = ($1, $2);
        my $title = ($inner =~ s#title:\s*([^;]+);##) ? $1 : "";
        "Adw.ActionRow { title: $title; suffix: Gtk.SpinButton $id { valign: center; $inner }; }"
    /gex' "$f"

    perl -0777 -pi -e 's/Adw.SwitchRow\s+([a-zA-Z0-9_]+)\s*\{((?:[^{}]|\{(?2)\})*)\}/
        my ($id, $inner) = ($1, $2);
        my $title = ($inner =~ s#title:\s*([^;]+);##) ? $1 : "";
        "Adw.ActionRow { title: $title; suffix: Gtk.Switch $id { valign: center; $inner }; }"
    /gex' "$f"

    # 3. ToolbarView -> Box
    perl -0777 -pi -e 's/Adw.ToolbarView\s*\{/Gtk.Box { orientation: vertical; /g' "$f"
    
    # 4. Remove property labels and slot markers that interfere with Gtk.Box
    perl -pi -e 's/\[(top|bottom|content|child)\]\s*//g' "$f"
    perl -0777 -pi -e 's/\b(content|child|default-widget|focus-widget):\s*//g' "$f"
    
    # 5. WindowTitle -> Label (Map title: to label:, remove subtitle:)
    perl -0777 -pi -e 's/Adw.WindowTitle\s+[a-zA-Z0-9_]*\s*\{((?:[^{}]|\{(?1)\})*)\}/
        my $c = $1;
        $c =~ s#\btitle:#label:#g;
        $c =~ s#\bsubtitle:[^;]+;##g;
        "Gtk.Label {$c}"
    /gex' "$f"
    
    # 6. Dialog types
    sed -i 's/Adw.PreferencesDialog/Adw.PreferencesWindow/g' "$f"
    sed -i 's/Adw.Dialog/Adw.Window/g' "$f"
    
    # 7. Remove modern properties
    sed -i '/top-bar-style:/d' "$f"
    sed -i '/centering-policy:/d' "$f"
    sed -i '/enable-transitions:/d' "$f"
    sed -i '/content-width:/d' "$f"
    sed -i '/content-height:/d' "$f"
done

# Patch Vala Code surgically
echo "=== Patching Vala code ==-"

# 1. window.vala
# - Disable visible-dialog notify (not in 1.2)
sed -i 's/notify\["visible-dialog"\]/\/\/notify\["visible-dialog"\]/g' "$PROJECT_DIR/src/window.vala"
perl -0777 -pi -e 's/private void visible_dialog_cb \(\)\s*\{((?:[^{}]|\{(?1)\})*)\}/private void visible_dialog_cb () { }/g' "$PROJECT_DIR/src/window.vala"
# - Dummy out accent color logic (Added in 1.6)
perl -0777 -pi -e 's/void set_accent_color \(\)\s*\{((?:[^{}]|\{(?1)\})*)\}/void set_accent_color () { }/g' "$PROJECT_DIR/src/window.vala"
sed -i 's/style_manager.notify\["accent-color"\]/\/\/style_manager.notify/g' "$PROJECT_DIR/src/window.vala"
# - Fix load_from_string -> load_from_data (GTK 4.8)
sed -i 's/accent_provider.load_from_string(s);/accent_provider.load_from_data(s.data);/g' "$PROJECT_DIR/src/window.vala"
# - Remove dispose_template (Added in 1.4)
sed -i 's/dispose_template (this.get_type ());/\/\/dispose_template/g' "$PROJECT_DIR/src/window.vala"

# 2. gnome-sudoku.vala
# - ApplicationFlags fix
sed -i 's/ApplicationFlags.DEFAULT_FLAGS/ApplicationFlags.FLAGS_NONE/g' "$PROJECT_DIR/src/gnome-sudoku.vala"
# - Replace Adw.AlertDialog with Adw.MessageDialog (In 1.2)
perl -0777 -pi -e 's/var dialog = new Adw.AlertDialog \(([^,]+), ([^)]+)\);/var dialog = new Adw.MessageDialog (window, $1, $2);/g' "$PROJECT_DIR/src/gnome-sudoku.vala"
perl -0777 -pi -e 's/var dialog = new Adw.AlertDialog \(([^)]+)\);/var dialog = new Adw.MessageDialog (window, $1, "");/g' "$PROJECT_DIR/src/gnome-sudoku.vala"
# - Fix present() calls
sed -i 's/\.present (window)/.present ()/g' "$PROJECT_DIR/src/gnome-sudoku.vala"
# - AboutDialog replacement (Adw.AboutDialog added in 1.5)
perl -0777 -pi -e 's/var about_dialog = new Adw.AboutDialog.from_appdata \("([^"]+)", VERSION\);/var about_dialog = new Gtk.AboutDialog(); about_dialog.set_version(VERSION); about_dialog.set_transient_for(window);/g' "$PROJECT_DIR/src/gnome-sudoku.vala"

# 3. preferences-dialog.vala
sed -i 's/Adw.PreferencesDialog/Adw.PreferencesWindow/g' "$PROJECT_DIR/src/preferences-dialog.vala"
sed -i 's/unowned Adw.SwitchRow/unowned Gtk.Switch/g' "$PROJECT_DIR/src/preferences-dialog.vala"
sed -i 's/dispose_template (this.get_type ());/\/\/dispose_template/g' "$PROJECT_DIR/src/preferences-dialog.vala"

# 4. print-dialog.vala
sed -i 's/Adw.Dialog/Adw.Window/g' "$PROJECT_DIR/src/print-dialog.vala"
sed -i 's/unowned Adw.SpinRow/unowned Gtk.SpinButton/g' "$PROJECT_DIR/src/print-dialog.vala"

# 5. printer.vala
sed -i 's/Pango.cairo_create_layout/Pango.Cairo.create_layout/g' "$PROJECT_DIR/src/printer.vala"
sed -i 's/Pango.cairo_show_layout/Pango.Cairo.show_layout/g' "$PROJECT_DIR/src/printer.vala"
perl -0777 -pi -e 's/var dialog = new Adw.AlertDialog \(([^,]+), ([^)]+)\);/var dialog = new Adw.MessageDialog (window, $1, $2);/g' "$PROJECT_DIR/src/printer.vala"
sed -i 's/dialog.present (window);/dialog.present ();/g' "$PROJECT_DIR/src/printer.vala"

# 6. C++ fixes
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
