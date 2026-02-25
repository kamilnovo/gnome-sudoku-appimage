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
# Force versions
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

# High-fidelity block matching logic
cat << 'EOF' > patch_blocks.pl
undef $/;
my $content = <STDIN>;
my $mode = $ARGV[0];

sub find_block_end {
    my ($str, $brace_pos) = @_;
    my $count = 1;
    my $pos = $brace_pos + 1;
    while ($count > 0 && $pos < length($str)) {
        my $c = substr($str, $pos, 1);
        if ($c eq '{') { $count++; }
        elsif ($c eq '}') { $count--; }
        $pos++;
    }
    return $pos;
}

if ($mode eq 'blp') {
    # Transform Adw.SpinRow and Adw.SwitchRow
    foreach my $type (qw(Spin Switch)) {
        while ($content =~ m/\bAdw\.${type}Row(?:\s+([a-zA-Z0-9_]+))?\s*\{/g) {
            my $start = $-[0]; my $id = $1 // "tmp_id"; my $brace = $+[0] - 1;
            my $end = find_block_end($content, $brace);
            my $inner = substr($content, $brace + 1, $end - $brace - 2);
            my $title = ($inner =~ s/\btitle:\s*([^;]+);//) ? "title: $1;" : "title: \" \";";
            my $use_underline = ($inner =~ s/\buse-underline:\s*([^;]+);//) ? "use-underline: $1;" : "";
            $inner =~ s/\bvalign:\s*[^;]+;//g;
            my $new_widget = ($type eq "Spin") ? "Gtk.SpinButton" : "Gtk.Switch";
            my $replacement = "Adw.ActionRow { $title $use_underline [suffix] $new_widget $id { valign: center; $inner } }";
            substr($content, $start, $end - $start) = $replacement;
            pos($content) = 0;
        }
    }
    # Global downgrades
    $content =~ s/\bAdw\.ToolbarView\b/Gtk.Box/g;
    $content =~ s/\bAdw\.WindowTitle\b/Gtk.Label/g;
    $content =~ s/\bAdw\.Dialog\b/Adw.Window/g;
    $content =~ s/\bAdw\.PreferencesDialog\b/Adw.PreferencesWindow/g;
    $content =~ s/\bAdw\.StatusPage\b/Gtk.Box/g;
    # Strip properties
    $content =~ s/^\s*(content|child|top-bar-style|centering-policy|enable-transitions|content-width|content-height|default-widget|focus-widget):\s*[^;]+;\s*$//mg;
    $content =~ s/^\s*(content|child):\s*//mg;
    $content =~ s/\[(top|bottom|start|end)\]\s*//g;
    # Label properties
    while ($content =~ m/\bGtk\.Label(?:\s+[a-zA-Z0-9_]+)?\s*\{/g) {
        my $brace = $+[0] - 1; my $end = find_block_end($content, $brace);
        my $inner = substr($content, $brace + 1, $end - $brace - 2);
        $inner =~ s/\btitle\s*:\s*/label: /g;
        $inner =~ s/\bsubtitle:\s*[^;]+;//g;
        substr($content, $brace + 1, $end - $brace - 2) = $inner;
        pos($content) = $end;
    }
    # Semicolon Normalization
    $content =~ s/\}\s*;/}/g;
    my @props = qw(adjustment popover title-widget menu-model model);
    foreach my $p (@props) {
        while ($content =~ m/\b$p:\s*[^;\{]+\{/g) {
            my $brace = $+[0] - 1; my $end = find_block_end($content, $brace);
            substr($content, $end, 0) = ";";
            pos($content) = $end + 1;
        }
    }
}

if ($mode eq 'vala') {
    # Type mapping
    $content =~ s/Adw\.AlertDialog/Adw.MessageDialog/g;
    $content =~ s/\bunowned\s+Adw\.WindowTitle/unowned Gtk.Label/g;
    $content =~ s/\bunowned\s+Adw\.SpinRow/unowned Gtk.SpinButton/g;
    $content =~ s/\bunowned\s+Adw\.SwitchRow/unowned Gtk.Switch/g;
    $content =~ s/\bunowned\s+Adw\.ToolbarView/unowned Gtk.Box/g;
    $content =~ s/\bunowned\s+Adw\.StatusPage/unowned Gtk.Box/g;
    $content =~ s/\bAdw\.PreferencesDialog\b/Adw.PreferencesWindow/g;
    $content =~ s/\bAdw\.Dialog\b/Adw.Window/g;
    $content =~ s/windowtitle\.subtitle\s*=\s*.*;/\/\/subtitle stub/g;
    $content =~ s/windowtitle\.title\s*=\s*/windowtitle.label = /g;
    $content =~ s/accent_provider\.load_from_string\s*\(\s*s\s*\)/accent_provider.load_from_data(s.data)/g;
    $content =~ s/dispose_template\s*\(\s*this.get_type\s*\(\)\s*\);/\/\/dispose/g;
    # Stub animation methods
    my @funcs = qw(play_hide_animation skip_animation visible_dialog_cb set_accent_color);
    foreach my $f (@funcs) {
        while ($content =~ m/\b(public\s+|private\s+)?void\s+$f\s*\([^\)]*\)\s*\{/g) {
            my $start = $-[0]; my $brace = $+[0] - 1;
            my $end = find_block_end($content, $brace);
            my $replacement = "void $f () { }";
            substr($content, $start, $end - $start) = $replacement;
            pos($content) = $start + length($replacement);
        }
    }
    # MessageDialog injection
    $content =~ s{new\s+Adw\.MessageDialog\s*\((.*)\);}{
        my $args = $1; if ($args !~ m/,/) { $args .= ", null"; }
        "new Adw.MessageDialog(null, $args);"
    }ge;
}
print $content;
EOF

for f in "$PROJECT_DIR"/src/blueprints/*.blp; do perl patch_blocks.pl blp < "$f" > "$f.tmp" && mv "$f.tmp" "$f"; done
find "$PROJECT_DIR" -name "*.vala" | while read f; do perl patch_blocks.pl vala < "$f" > "$f.tmp" && mv "$f.tmp" "$f"; done

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
chmod +x linuxdeploy linuxdeploy-plugin-gtk appimagetool

export PATH="$PWD:$PATH"
export VERSION
export DEPLOY_GTK_VERSION=4
# Force bundling of EVERYTHING to avoid "standard" lib issues
export EXTRA_PLATFORM_LIBRARIES="libadwaita-1,libgtk-4,libgee-0.8,libjson-glib-1.0,libqqwing,libpango-1.0,libcairo,libgdk_pixbuf-2.0,libgraphene-1.0,libgio-2.0,libgobject-2.0,libglib-2.0"

DESKTOP_FILE=$(find "$APPDIR" -name "org.gnome.Sudoku.desktop")
ICON_FILE=$(find "$APPDIR" -name "org.gnome.Sudoku.svg" | grep -v "symbolic" | head -n 1)

./linuxdeploy --appdir "$APPDIR" \
    -e "$APPDIR/usr/bin/gnome-sudoku" \
    ${DESKTOP_FILE:+ -d "$DESKTOP_FILE"} \
    ${ICON_FILE:+ -i "$ICON_FILE"} \
    --plugin gtk

glib-compile-schemas "$APPDIR/usr/share/glib-2.0/schemas"

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

./appimagetool "$APPDIR" Sudoku-49.4-x86_64.AppImage
echo "Done!"
