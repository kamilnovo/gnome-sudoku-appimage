#!/bin/bash
set -e
export APPIMAGE_EXTRACT_AND_RUN=1
VERSION="49.4"
REPO_URL="https://gitlab.gnome.org/GNOME/gnome-sudoku.git"
PROJECT_DIR="gnome-sudoku-$VERSION"
APPDIR="AppDir"

cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"

# Install file utility
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

# Vala: Precision stubs and type replacements
cat << 'EOF' > patch_vala.pl
undef $/;
my $content = <STDIN>;
sub find_block_end {
    my ($str, $pos) = @_;
    my $count = 1;
    while ($count > 0 && $pos < length($str)) {
        my $c = substr($str, $pos, 1);
        if ($c eq '{') { $count++; } elsif ($c eq '}') { $count--; }
        $pos++;
    }
    return $pos;
}
$content =~ s/Adw\.AlertDialog/Adw.MessageDialog/g;
$content =~ s/\bunowned\s+Adw\.WindowTitle/unowned Gtk.Label/g;
$content =~ s/\bunowned\s+Adw\.SpinRow/unowned Gtk.SpinButton/g;
$content =~ s/\bunowned\s+Adw\.SwitchRow/unowned Gtk.Switch/g;
$content =~ s/\bunowned\s+Adw\.ToolbarView/unowned Gtk.Box/g;
$content =~ s/\bunowned\s+Adw\.StatusPage/unowned Gtk.Box/g;
$content =~ s/\bAdw\.PreferencesDialog\b/Adw.PreferencesWindow/g;
$content =~ s/\bAdw\.Dialog\b/Adw.Window/g;
$content =~ s/accent_provider\.load_from_string\s*\(\s*s\s*\)/accent_provider.load_from_data(s.data)/g;
my @funcs = qw(play_hide_animation skip_animation visible_dialog_cb set_accent_color);
foreach my $f (@funcs) {
    while ($content =~ m/\bvoid\s+$f\s*\([^\)]*\)\s*\{/g) {
        my $start = $-[0]; my $brace_end = $+[0];
        my $end = find_block_end($content, $brace_end);
        substr($content, $start, $end - $start) = "void stub_$f() { }" . (" " x ($end - $start - 18));
    }
}
$content =~ s{new\s+Adw\.MessageDialog\s*\((.*)\);}{
    my $args = $1; if ($args !~ m/,/) { $args .= ", null"; }
    "new Adw.MessageDialog(null, $args);"
}ge;
print $content;
EOF
find "$PROJECT_DIR" -name "*.vala" | while read f; do perl patch_vala.pl < "$f" > "$f.tmp" && mv "$f.tmp" "$f"; done

# Blueprint precision patcher (Safe version)
cat << 'EOF' > patch_blp.pl
undef $/;
my $content = <STDIN>;
sub find_block_end {
    my ($str, $pos) = @_;
    my $count = 1;
    while ($count > 0 && $pos < length($str)) {
        my $c = substr($str, $pos, 1);
        if ($c eq '{') { $count++; } elsif ($c eq '}') { $count--; }
        $pos++;
    }
    return $pos;
}
# Type swaps
$content =~ s/\bAdw\.ToolbarView\b/Gtk.Box/g;
$content =~ s/\bAdw\.WindowTitle\b/Gtk.Label/g;
$content =~ s/\bAdw\.Dialog\b/Adw.Window/g;
$content =~ s/\bAdw\.PreferencesDialog\b/Adw.PreferencesWindow/g;
$content =~ s/\bAdw\.StatusPage\b/Gtk.Box/g;
$content =~ s/\bAdw\.SpinRow\b/Adw.ActionRow/g;
$content =~ s/\bAdw\.SwitchRow\b/Adw.ActionRow/g;
# Strip modern props
$content =~ s/^\s*(top-bar-style|centering-policy|enable-transitions|content-width|content-height|default-widget|focus-widget):\s*[^;]+;\s*$//mg;
$content =~ s/\[(top|bottom|start|end)\]//g;

# 1. Identify property blocks and their transformations
my @removals;
my @inserts;
while ($content =~ m/\b(content|child|title-widget|menu-model|model|adjustment|popover):\s*([a-zA-Z0-9\.\$]+\s*)?(?:[a-zA-Z0-9_]+\s*)?\{/g) {
    my $start = $-[0]; my $brace_end = $+[0];
    my $prop_name = $1;
    my $end = find_block_end($content, $brace_end);
    if ($prop_name eq 'content' || $prop_name eq 'child') {
        push @removals, [$start, $brace_end - $start, qr/(content|child):\s*/];
        if (substr($content, $end, 1) eq ';') { push @removals, [$end, 1, qr/;/]; }
    } else {
        if (substr($content, $end, 1) ne ';') { push @inserts, [$end, ";"]; }
    }
}
# Apply changes in reverse to preserve offsets
foreach my $change (sort { $b->[0] <=> $a->[0] } (@removals, @inserts)) {
    if (scalar(@$change) == 3) { # Removal
        substr($content, $change->[0], $change->[1]) =~ s/$change->[2]//;
    } else { # Insert
        substr($content, $change->[0], 0) = $change->[1];
    }
}

# 2. Fix Label properties (ONLY in Gtk.Label blocks)
while ($content =~ m/\bGtk\.Label(?:\s+[a-zA-Z0-9_]+)?\s*\{/g) {
    my $brace_end = $+[0]; my $end = find_block_end($content, $brace_end);
    my $inner = substr($content, $brace_end, $end - $brace_end - 1);
    $inner =~ s/\btitle:\s*/label: /g;
    $inner =~ s/\bsubtitle:\s*[^;]+;//g;
    substr($content, $brace_end, $end - $brace_end - 1) = $inner;
}
# 3. Final global semicolon cleanup
$content =~ s/\}\s*;\s*\}/\}\}/g;
print $content;
EOF
for f in "$PROJECT_DIR"/src/blueprints/*.blp; do perl patch_blp.pl < "$f" > "$f.tmp" && mv "$f.tmp" "$f"; done

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
# Force bundling of core libs
LIBADWAITA=$(find /usr/lib -name "libadwaita-1.so.0" | head -n 1)
LIBGTK=$(find /usr/lib -name "libgtk-4.so.1" | head -n 1)
LIBGEE=$(find /usr/lib -name "libgee-0.8.so.2" | head -n 1)

./linuxdeploy --appdir "$APPDIR" \
    -e "$APPDIR/usr/bin/gnome-sudoku" \
    ${LIBADWAITA:+ --library "$LIBADWAITA"} \
    ${LIBGTK:+ --library "$LIBGTK"} \
    ${LIBGEE:+ --library "$LIBGEE"} \
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
