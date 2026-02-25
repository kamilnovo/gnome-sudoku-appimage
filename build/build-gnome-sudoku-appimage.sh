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
# Force versions in meson.build
sed -i "s/glib_version = '[0-9.]*'/glib_version = '2.74.0'/g" "$PROJECT_DIR/meson.build" || true
sed -i "s/gtk4', version: '>= [0-9.]*'/gtk4', version: '>= 4.8.0'/g" "$PROJECT_DIR/meson.build" || true
sed -i "s/libadwaita-1', version: '>= [0-9.]*'/libadwaita-1', version: '>= 1.2.0'/g" "$PROJECT_DIR/meson.build" || true

# Inject Pango/PangoCairo into Vala args
sed -i "s/gnome_sudoku_vala_args = \[/gnome_sudoku_vala_args = ['--pkg=pango', '--pkg=pangocairo', /" "$PROJECT_DIR/src/meson.build"
sed -i "s/libsudoku = static_library('sudoku', libsudoku_sources,/libsudoku = static_library('sudoku', libsudoku_sources, vala_args: ['--pkg=pango', '--pkg=pangocairo'],/" "$PROJECT_DIR/lib/meson.build"

# CSS Patcher
cat << 'EOF' > patch_css.pl
undef $/;
my $content = <STDIN>;
$content =~ s/--sudoku-accent-blue:\s*oklch\([^)]*\)/--sudoku-accent-blue: #3584e4/g;
$content =~ s/--sudoku-accent-teal:\s*oklch\([^)]*\)/--sudoku-accent-teal: #33d17a/g;
$content =~ s/--sudoku-accent-green:\s*oklch\([^)]*\)/--sudoku-accent-green: #2ec27e/g;
$content =~ s/--sudoku-accent-yellow:\s*oklch\([^)]*\)/--sudoku-accent-yellow: #f8e45c/g;
$content =~ s/--sudoku-accent-orange:\s*oklch\([^)]*\)/--sudoku-accent-orange: #ffa348/g;
$content =~ s/--sudoku-accent-red:\s*oklch\([^)]*\)/--sudoku-accent-red: #ed333b/g;
$content =~ s/--sudoku-accent-pink:\s*oklch\([^)]*\)/--sudoku-accent-pink: #ff7b9c/g;
$content =~ s/--sudoku-accent-purple:\s*oklch\([^)]*\)/--sudoku-accent-purple: #9141ac/g;
$content =~ s/--sudoku-accent-slate:\s*oklch\([^)]*\)/--sudoku-accent-slate: #6f7172/g;
$content =~ s/oklch\([^)]*\)/#3584e4/g;
$content =~ s/oklab\([^)]*\)/#3584e4/g;
$content =~ s/^[ \t]*(background|color|transition|animation):[^;]*okl[ch]ab?\(from[^;]*;[ \t]*\n?//mg;
$content =~ s/:root/*/g;
print $content;
EOF
for css in "$PROJECT_DIR"/data/*.css; do perl patch_css.pl < "$css" > "$css.tmp" && mv "$css.tmp" "$css"; done

# High-fidelity Brace-counting Patcher for BLP and Vala
cat << 'EOF' > patch_blocks.pl
undef $/;
my $content = <STDIN>;
my $mode = $ARGV[0]; # 'blp' or 'vala'

sub find_block_end {
    my ($str, $start_pos) = @_;
    my $count = 1;
    my $pos = $start_pos;
    while ($count > 0 && $pos < length($str)) {
        my $c = substr($str, $pos, 1);
        if ($c eq '{') { $count++; }
        elsif ($c eq '}') { $count--; }
        $pos++;
    }
    return $pos;
}

if ($mode eq 'blp') {
    # 1. Downgrade modern widgets
    $content =~ s/\bAdw\.ToolbarView\b/Gtk.Box/g;
    $content =~ s/\bAdw\.WindowTitle\b/Gtk.Label/g;
    $content =~ s/\bAdw\.Dialog\b/Adw.Window/g;
    $content =~ s/\bAdw\.PreferencesDialog\b/Adw.PreferencesWindow/g;
    
    # 2. Fix Gtk.Label properties (title -> label)
    while ($content =~ m/\bGtk\.Label(?:\s+[a-zA-Z0-9_]+)?\s*\{/g) {
        my $match_start = $-[0];
        my $brace_start = $+[0] - 1;
        my $block_end = find_block_end($content, $brace_start + 1);
        my $inner = substr($content, $brace_start + 1, $block_end - $brace_start - 2);
        $inner =~ s/\btitle\s*:\s*/label: /g;
        $inner =~ s/\bsub(?:title|label):\s*[^;]+;//g;
        substr($content, $brace_start + 1, $block_end - $brace_start - 2) = $inner;
        pos($content) = $block_end;
    }
    
    # 3. Strip modern attributes
    $content =~ s/\b(content|child):\s*//g;
    $content =~ s/\[(top|bottom|start|end)\]\s*//g;
    $content =~ s/\b(top-bar-style|centering-policy|enable-transitions|content-width|content-height|default-widget|focus-widget):\s*[^;]+;\s*//g;
}

if ($mode eq 'vala') {
    # Global API mapping
    $content =~ s/Adw\.AlertDialog/Adw.MessageDialog/g;
    $content =~ s/\bunowned\s+Adw\.WindowTitle/unowned Gtk.Label/g;
    $content =~ s/\bunowned\s+Adw\.SpinRow/unowned Gtk.SpinButton/g;
    $content =~ s/\bunowned\s+Adw\.SwitchRow/unowned Gtk.Switch/g;
    $content =~ s/\bunowned\s+Adw\.ToolbarView/unowned Gtk.Box/g;
    $content =~ s/\bunowned\s+Adw\.StatusPage/unowned Gtk.Box/g;
    $content =~ s/windowtitle\.subtitle\s*=\s*.*;/\/\/subtitle stub/g;
    $content =~ s/windowtitle\.title\s*=\s*/windowtitle.label = /g;
    
    # Stub out troublesome functions
    my @funcs = qw(play_hide_animation skip_animation visible_dialog_cb set_accent_color);
    foreach my $f (@funcs) {
        while ($content =~ m/\bvoid\s+$f\s*\([^\)]*\)\s*\{/g) {
            my $match_start = $-[0];
            my $brace_start = $+[0] - 1;
            my $block_end = find_block_end($content, $brace_start + 1);
            my $replacement = "void $f () { }";
            substr($content, $match_start, $block_end - $match_start) = $replacement;
            pos($content) = $match_start + length($replacement);
        }
    }
    
    # MessageDialog parent injection
    $content =~ s{new\s+Adw\.MessageDialog\s*\((.*)\);}{
        my $args = $1;
        if ($args !~ m/,/) { $args .= ", null"; }
        "new Adw.MessageDialog(null, $args);"
    }ge;
}

print $content;
EOF

# Apply patches
echo "Patching Blueprints..."
for f in "$PROJECT_DIR"/src/blueprints/*.blp; do
    perl patch_blocks.pl blp < "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done

echo "Patching Vala..."
find "$PROJECT_DIR"/src "$PROJECT_DIR"/lib -name "*.vala" -print0 | while IFS= read -r -d $'\0' f; do
    perl patch_blocks.pl vala < "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done

# Extra Vala fixes via sed (simpler and safer)
find "$PROJECT_DIR" -name "*.vala" -exec sed -i 's/accent_provider.load_from_string(s)/accent_provider.load_from_data(s.data)/g' {} +
find "$PROJECT_DIR" -name "*.vala" -exec sed -i 's/dispose_template(this.get_type());/\/\/dispose/g' {} +

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

# Deploy dependencies
export DEPLOY_GTK_VERSION=4
LIBADWAITA=$(find /usr/lib -name "libadwaita-1.so.0" | head -n 1)
LIBGTK=$(find /usr/lib -name "libgtk-4.so.1" | head -n 1)
LIBGEE=$(find /usr/lib -name "libgee-0.8.so.2" | head -n 1)

./linuxdeploy --appdir "$APPDIR" \
    -e "$APPDIR/usr/bin/gnome-sudoku" \
    ${LIBADWAITA:+ --library "$LIBADWAITA"} \
    ${LIBGTK:+ --library "$LIBGTK"} \
    ${LIBGEE:+ --library "$LIBGEE"} \
    --plugin gtk

# Create robust AppRun
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

# Build AppImage
./appimagetool "$APPDIR" Sudoku-49.4-x86_64.AppImage
echo "Done!"
