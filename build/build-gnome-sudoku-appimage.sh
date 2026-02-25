#!/bin/bash
set -e
export APPIMAGE_EXTRACT_AND_RUN=1
VERSION="49.4"
REPO_URL="https://gitlab.gnome.org/GNOME/gnome-sudoku.git"
PROJECT_DIR="gnome-sudoku-$VERSION"
APPDIR="AppDir"

cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"

# Install missing system dependencies
if [ "$EUID" -eq 0 ]; then
    apt-get update && apt-get install -y file
else
    sudo apt-get update && sudo apt-get install -y file
fi

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

# 3. Patch Sudoku
echo "=== Patching Sudoku ==-"
# Meson fixes
sed -i "s/glib_version = '[0-9.]*'/glib_version = '2.74.0'/g" "$PROJECT_DIR/meson.build" || true
sed -i "s/gtk4', version: '>= [0-9.]*'/gtk4', version: '>= 4.8.0'/g" "$PROJECT_DIR/meson.build" || true
sed -i "s/libadwaita-1', version: '>= [0-9.]*'/libadwaita-1', version: '>= 1.2.0'/g" "$PROJECT_DIR/meson.build" || true
sed -i "s/gnome_sudoku_vala_args = \[/gnome_sudoku_vala_args = ['--pkg=pango', '--pkg=pangocairo', /" "$PROJECT_DIR/src/meson.build"
sed -i "s/libsudoku = static_library('sudoku', libsudoku_sources,/libsudoku = static_library('sudoku', libsudoku_sources, vala_args: ['--pkg=pango', '--pkg=pangocairo'],/" "$PROJECT_DIR/lib/meson.build"

# CSS fixes
for css in "$PROJECT_DIR"/data/*.css; do
    sed -i 's/oklch([^)]*)/#3584e4/g' "$css"
    sed -i 's/oklab([^)]*)/#3584e4/g' "$css"
    sed -i '/okl[ch]ab?(from/d' "$css"
    sed -i 's/:root/*/g' "$css"
done

# Vala fixes (Global replacements)
find "$PROJECT_DIR" -name "*.vala" -exec sed -i 's/Adw.AlertDialog/Adw.MessageDialog/g' {} +
find "$PROJECT_DIR" -name "*.vala" -exec sed -i 's/unowned Adw.WindowTitle/unowned Gtk.Label/g' {} +
find "$PROJECT_DIR" -name "*.vala" -exec sed -i 's/unowned Adw.SpinRow/unowned Gtk.SpinButton/g' {} +
find "$PROJECT_DIR" -name "*.vala" -exec sed -i 's/unowned Adw.SwitchRow/unowned Gtk.Switch/g' {} +
find "$PROJECT_DIR" -name "*.vala" -exec sed -i 's/unowned Adw.ToolbarView/unowned Gtk.Box/g' {} +
find "$PROJECT_DIR" -name "*.vala" -exec sed -i 's/unowned Adw.StatusPage/unowned Gtk.Box/g' {} +
find "$PROJECT_DIR" -name "*.vala" -exec sed -i 's/Adw.PreferencesDialog/Adw.PreferencesWindow/g' {} +
find "$PROJECT_DIR" -name "*.vala" -exec sed -i 's/Adw.Dialog/Adw.Window/g' {} +
find "$PROJECT_DIR" -name "*.vala" -exec sed -i 's/windowtitle.subtitle = .*;/ \/* stub *\/ /g' {} +
find "$PROJECT_DIR" -name "*.vala" -exec sed -i 's/windowtitle.title = /windowtitle.label = /g' {} +
find "$PROJECT_DIR" -name "*.vala" -exec sed -i 's/accent_provider.load_from_string(s)/accent_provider.load_from_data(s.data)/g' {} +
find "$PROJECT_DIR" -name "*.vala" -exec sed -i 's/dispose_template(this.get_type());/ \/* stub *\/ /g' {} +

# Blueprint fixes
# 1. Global type replacements
find "$PROJECT_DIR"/src/blueprints -name "*.blp" -exec sed -i 's/\bAdw.ToolbarView\b/Gtk.Box/g' {} +
find "$PROJECT_DIR"/src/blueprints -name "*.blp" -exec sed -i 's/\bAdw.WindowTitle\b/Gtk.Label/g' {} +
find "$PROJECT_DIR"/src/blueprints -name "*.blp" -exec sed -i 's/\bAdw.Dialog\b/Adw.Window/g' {} +
find "$PROJECT_DIR"/src/blueprints -name "*.blp" -exec sed -i 's/\bAdw.PreferencesDialog\b/Adw.PreferencesWindow/g' {} +
# 2. Strip modern attributes
find "$PROJECT_DIR"/src/blueprints -name "*.blp" -exec sed -i 's/\b(content|child): //g' {} +
find "$PROJECT_DIR"/src/blueprints -name "*.blp" -exec sed -i 's/\[(top|bottom|start|end)\]//g' {} +
find "$PROJECT_DIR"/src/blueprints -name "*.blp" -exec sed -i 's/\b(top-bar-style|centering-policy|enable-transitions|content-width|content-height|default-widget|focus-widget): [^;]*;//g' {} +
# 3. Label properties
find "$PROJECT_DIR"/src/blueprints -name "*.blp" -exec sed -i 's/\btitle: /label: /g' {} +
find "$PROJECT_DIR"/src/blueprints -name "*.blp" -exec sed -i 's/\bsubtitle: [^;]*;//g' {} +

# Vala: Stub out problematic functions using a simpler Perl script
cat << 'EOF' > stub_vala.pl
undef $/;
my $content = <STDIN>;
my @funcs = qw(play_hide_animation skip_animation visible_dialog_cb set_accent_color);
foreach my $f (@funcs) {
    $content =~ s/\b(public\s+|private\s+)?void\s+$f\s*\([^\)]*\)\s*\{[^\}]*\}/void $f () { }/g;
}
# MessageDialog constructor fix
$content =~ s/new\s+Adw\.MessageDialog\s*\(([^,]+)\)/new Adw.MessageDialog(null, $1, null)/g;
$content =~ s/new\s+Adw\.MessageDialog\s*\(([^,]+),\s*([^,]+)\)/new Adw.MessageDialog(null, $1, $2)/g;
print $content;
EOF
find "$PROJECT_DIR" -name "*.vala" | while read f; do perl stub_vala.pl < "$f" > "$f.tmp" && mv "$f.tmp" "$f"; done

# C++ fixes
sed -i '1i #include <ctime>\n#include <cstdlib>' "$PROJECT_DIR/lib/qqwing-wrapper.cpp"
sed -i 's/srand\s*(.*)/srand(time(NULL))/g' "$PROJECT_DIR/lib/qqwing-wrapper.cpp"

# 4. Build Sudoku
echo "=== Building Sudoku ==-"
cd "$PROJECT_DIR"
meson setup build --prefix=/usr -Dbuildtype=release
meson compile -C build -v
DESTDIR="$REPO_ROOT/$APPDIR" meson install -C build
cd "$REPO_ROOT"

# 5. Packaging
echo "=== Packaging AppImage ==-"
wget -q https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage -O linuxdeploy
wget -q https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/master/linuxdeploy-plugin-gtk.sh -O linuxdeploy-plugin-gtk.sh
wget -q https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage -O appimagetool
chmod +x linuxdeploy linuxdeploy-plugin-gtk.sh appimagetool

export PATH="$PWD:$PATH"
export VERSION

# Find core libs to force bundling
export EXTRA_PLATFORM_LIBRARIES="libadwaita-1,libgtk-4,libgee-0.8,libjson-glib-1.0,libqqwing,libpango-1.0,libcairo,libgdk_pixbuf-2.0"

# Find desktop and icon
DESKTOP_FILE=$(find "$APPDIR" -name "org.gnome.Sudoku.desktop")
ICON_FILE=$(find "$APPDIR" -name "org.gnome.Sudoku.svg" | grep -v "symbolic" | head -n 1)

# Deploy
export DEPLOY_GTK_VERSION=4
./linuxdeploy --appdir "$APPDIR" \
    -e "$APPDIR/usr/bin/gnome-sudoku" \
    ${DESKTOP_FILE:+ -d "$DESKTOP_FILE"} \
    ${ICON_FILE:+ -i "$ICON_FILE"} \
    --plugin gtk

# Compile schemas
glib-compile-schemas "$APPDIR/usr/share/glib-2.0/schemas"

# Create AppRun
cat << 'EOF' > "$APPDIR/AppRun"
#!/bin/sh
HERE="$(dirname "$(readlink -f "${0}")")"
export GSETTINGS_SCHEMA_DIR="$HERE/usr/share/glib-2.0/schemas"
export XDG_DATA_DIRS="$HERE/usr/share:$XDG_DATA_DIRS"
export LD_LIBRARY_PATH="$HERE/usr/lib:$LD_LIBRARY_PATH"
export GI_TYPELIB_PATH="$HERE/usr/lib/girepository-1.0:$GI_TYPELIB_PATH"
export GTK_THEME=Adwaita
exec "$HERE/usr/bin/gnome-sudoku" "$@"
EOF
chmod +x "$APPDIR/AppRun"

# Generate AppImage
./appimagetool "$APPDIR" Sudoku-49.4-x86_64.AppImage
echo "Done!"
