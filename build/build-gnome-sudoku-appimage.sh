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

# Standalone Blueprint Patcher (High-fidelity transformation)
cat << 'EOF' > patch_blp.pl
undef $/;
my $content = <STDIN>;

# 1. Widget Downgrades
$content =~ s/\bAdw\.ToolbarView\b/Gtk.Box/g;
$content =~ s/\bAdw\.WindowTitle\b/Gtk.Label/g;
$content =~ s/\bAdw\.Dialog\b/Adw.Window/g;
$content =~ s/\bAdw\.PreferencesDialog\b/Adw.PreferencesWindow/g;

# 2. Handle Adw.StatusPage -> Gtk.Box with internal Label
$content =~ s/Adw\.StatusPage\s*\{((?:[^{}]|\{(?1)\})*)\}/
    my $inner = $1;
    my $title = ($inner =~ s#\btitle:\s*(_\("[^"]+"\));##) ? $1 : "";
    $inner =~ s#\bvalign:\s*[^;]+;##g;
    "Gtk.Box { orientation: vertical; valign: start; Gtk.Label { label: $title; styles [\"title-1\"] } $inner }"
/gesx;

# 3. Handle Adw.SpinRow and Adw.SwitchRow -> ActionRow + suffix
$content =~ s/Adw\.(Spin|Switch)Row\s+([a-zA-Z0-9_]+)\s*\{((?:[^{}]|\{(?1)\})*)\}/
    my ($type, $id, $inner) = ($1, $2, $3);
    my $title = ($inner =~ s#\btitle:\s*([^;]+);##) ? "title: $1;" : "";
    my $use_underline = ($inner =~ s#\buse-underline:\s*([^;]+);##) ? "use-underline: $1;" : "";
    my $widget = ($type eq "Spin") ? "Gtk.SpinButton" : "Gtk.Switch";
    "Adw.ActionRow { $title $use_underline [suffix] $widget $id { valign: center; $inner } }"
/gesx;

# 4. Strip modern property wrappers and slot markers
$content =~ s/\b(content|child):\s*//g;
$content =~ s/\[(top|bottom|start|end)\]\s*//g;

# 5. Fix Gtk.Box needs orientation
$content =~ s/(Gtk\.Box\s*\{)(?![\s\S]*?orientation: vertical;)/$1 orientation: vertical; /gs;

# 6. Fix Gtk.Label properties
$content =~ s/(Gtk\.Label(?:\s+[a-zA-Z0-9_]+)?\s*\{)((?:[^{}]|\{(?2)\})*)\}/
    my ($head, $body) = ($1, $2);
    $body =~ s#\btitle\s*:#label:#g;
    $body =~ s#\bsub(?:title|label):\s*[^;]+;##g;
    "$head$body}"
/gesx;

# 7. Remove other modern properties
$content =~ s/\b(top-bar-style|centering-policy|enable-transitions|content-width|content-height|default-widget|focus-widget):\s*[^;]+;\s*//g;

# 8. Semicolon Normalization Pass
# Protect valid property block assignments: "prop: Widget { ... };"
# We match up to 3 levels of nesting which is plenty for Sudoku
$content =~ s/(\b[a-z0-9_-]+:\s*[a-zA-Z0-9\.\$]+\s*[a-zA-Z0-9_]*\s*\{((?:[^{}]|\{(?:[^{}]|\{[^{}]*\})*\})*)\})\s*;/$1__KEEP_SEMI__/gs;

# Remove all remaining block semicolons (they are now only on child widgets or removed properties)
$content =~ s/\}\s*;/}/g;

# Restore protected semicolons
$content =~ s/__KEEP_SEMI__/;/g;

print $content;
EOF

# Apply Blueprint patches
for f in "$PROJECT_DIR"/src/blueprints/*.blp; do
    echo "Patching Blueprint: $f"
    perl patch_blp.pl < "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done

# Standalone Vala Patcher
cat << 'EOF' > patch_vala.pl
undef $/;
my $content = <STDIN>;
my $file = $ARGV[0];

if ($file =~ /window.vala/) {
    $content =~ s/notify\s*\[\s*"visible-dialog"\s*\]/\/\/notify/g;
    $content =~ s/private\s+void\s+visible_dialog_cb\s*\(\)\s*\{((?:[^{}]|\{(?1)\})*)\}/private void visible_dialog_cb () { }/g;
    $content =~ s/void\s+set_accent_color\s*\(\)\s*\{((?:[^{}]|\{(?1)\})*)\}/void set_accent_color () { }/g;
    $content =~ s/style_manager.notify\s*\[\s*"accent-color"\s*\]/\/\/style_manager.notify/g;
    $content =~ s/accent_provider.load_from_string\s*\(\s*s\s*\)/accent_provider.load_from_data(s.data)/g;
    $content =~ s/dispose_template\s*\(\s*this.get_type\s*\(\)\s*\);/\/\/dispose_template/g;
}

if ($file =~ /gnome-sudoku.vala/) {
    $content =~ s/ApplicationFlags.DEFAULT_FLAGS/ApplicationFlags.FLAGS_NONE/g;
    $content =~ s/var\s+dialog\s*=\s*new\s+Adw.AlertDialog\s*\(([^,]+),?\s*([^)]*)\);/var dialog = new Adw.MessageDialog(window, $1, $2);/g;
    $content =~ s/var\s+about_dialog\s*=\s*new\s+Adw.AboutDialog.from_appdata\s*\(([^,]+),\s*VERSION\);/var about_dialog = new Gtk.AboutDialog(); about_dialog.set_program_name("Sudoku"); about_dialog.set_version(VERSION); about_dialog.set_transient_for(window);/g;
    $content =~ s/about_dialog.set_developers/about_dialog.set_authors/g;
    $content =~ s/\.present\s*\(\s*window\s*\)/.present()/g;
}

if ($file =~ /preferences-dialog.vala/) {
    $content =~ s/Adw.PreferencesDialog/Adw.PreferencesWindow/g;
    $content =~ s/unowned\s+Adw.SwitchRow/unowned Gtk.Switch/g;
    $content =~ s/dispose_template\s*\(\s*this.get_type\s*\(\)\s*\);/\/\/dispose_template/g;
}

if ($file =~ /print-dialog.vala/) {
    $content =~ s/Adw.Dialog/Adw.Window/g;
    $content =~ s/unowned\s+Adw.SpinRow/unowned Gtk.SpinButton/g;
}

if ($file =~ /printer.vala/) {
    $content =~ s/Pango.cairo_create_layout/Pango.Cairo.create_layout/g;
    $content =~ s/Pango.cairo_show_layout/Pango.Cairo.show_layout/g;
    $content =~ s/var\s+dialog\s*=\s*new\s+Adw.AlertDialog\s*\(([^,]+),?\s*([^)]*)\);/var dialog = new Adw.MessageDialog(window, $1, $2);/g;
    $content =~ s/\.present\s*\(\s*window\s*\)/.present()/g;
}

print $content;
EOF

# Apply Vala patches
find "$PROJECT_DIR"/src "$PROJECT_DIR"/lib -name "*.vala" -print0 | while IFS= read -r -d $'\0' f; do
    echo "Patching Vala: $f"
    perl patch_vala.pl "$f" < "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done

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
