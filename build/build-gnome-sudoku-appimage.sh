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

# Vala fixes (Reliable sed)
find "$PROJECT_DIR" -name "*.vala" -exec sed -i 's/Adw.AlertDialog/Adw.MessageDialog/g' {} +
find "$PROJECT_DIR" -name "*.vala" -exec sed -i 's/\bAdw.WindowTitle\b/Gtk.Label/g' {} +
find "$PROJECT_DIR" -name "*.vala" -exec sed -i 's/\bAdw.SpinRow\b/Gtk.SpinButton/g' {} +
find "$PROJECT_DIR" -name "*.vala" -exec sed -i 's/\bAdw.SwitchRow\b/Gtk.Switch/g' {} +
find "$PROJECT_DIR" -name "*.vala" -exec sed -i 's/\bAdw.ToolbarView\b/Gtk.Box/g' {} +
find "$PROJECT_DIR" -name "*.vala" -exec sed -i 's/\bAdw.StatusPage\b/Gtk.Box/g' {} +
find "$PROJECT_DIR" -name "*.vala" -exec sed -i 's/\bAdw.PreferencesDialog\b/Adw.PreferencesWindow/g' {} +
find "$PROJECT_DIR" -name "*.vala" -exec sed -i 's/\bAdw.Dialog\b/Adw.Window/g' {} +
find "$PROJECT_DIR" -name "*.vala" -exec sed -i 's/windowtitle.title = /windowtitle.label = /g' {} +
find "$PROJECT_DIR" -name "*.vala" -exec sed -i 's/accent_provider.load_from_string(s)/accent_provider.load_from_data(s.data)/g' {} +

# Vala Method Stubbing (Safe brace matching)
cat << 'EOF' > stub_vala.pl
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
my @funcs = qw(play_hide_animation skip_animation visible_dialog_cb set_accent_color);
foreach my $f (@funcs) {
    while ($content =~ m/\bvoid\s+$f\s*\([^\)]*\)\s*\{/g) {
        my $start = $-[0]; my $brace = $+[0] - 1;
        my $end = find_block_end($content, $brace + 1);
        substr($content, $start, $end - $start) = "void stub_$f() { }" . (" " x ($end - $start - 18));
    }
}
$content =~ s/new\s+Adw\.MessageDialog\s*\(([^,]+)\)/new Adw.MessageDialog(null, $1, null)/g;
$content =~ s/new\s+Adw\.MessageDialog\s*\(([^,]+),\s*([^,]+)\)/new Adw.MessageDialog(null, $1, $2)/g;
$content =~ s/\.present\s*\([^)]+\)/.present()/g;
print $content;
EOF
find "$PROJECT_DIR" -name "*.vala" | while read f; do perl stub_vala.pl < "$f" > "$f.tmp" && mv "$f.tmp" "$f"; done

# Blueprint Fixes (Sophisticated Downgrader)
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

# 1. Downgrade SwitchRow to ActionRow + Gtk.Switch
while ($content =~ m/\bAdw\.SwitchRow\s+([a-zA-Z0-9_]+)\s*\{/g) {
    my $id = $1; my $start = $-[0]; my $brace = $+[0] - 1;
    my $end = find_block_end($content, $brace + 1);
    my $inner = substr($content, $brace + 1, $end - $brace - 2);
    my $replacement = "Adw.ActionRow {\n$inner\n  [suffix] Gtk.Switch $id { valign: center; } \n}";
    substr($content, $start, $end - $start) = $replacement;
    pos($content) = $start + length($replacement);
}

# 2. Downgrade SpinRow to ActionRow + Gtk.SpinButton
while ($content =~ m/\bAdw\.SpinRow\s+([a-zA-Z0-9_]+)\s*\{/g) {
    my $id = $1; my $start = $-[0]; my $brace = $+[0] - 1;
    my $end = find_block_end($content, $brace + 1);
    my $inner = substr($content, $brace + 1, $end - $brace - 2);
    my $adj = ""; if ($inner =~ s/\badjustment:\s*([^;]+;)/ /gs) { $adj = "adjustment: $1"; }
    my $replacement = "Adw.ActionRow {\n$inner\n  [suffix] Gtk.SpinButton $id { valign: center; $adj } \n}";
    substr($content, $start, $end - $start) = $replacement;
    pos($content) = $start + length($replacement);
}

# 3. Downgrade StatusPage
while ($content =~ m/\bAdw\.StatusPage(?:\s+[a-zA-Z0-9_]+)?\s*\{/g) {
    my $start = $-[0]; my $brace = $+[0] - 1;
    my $end = find_block_end($content, $brace + 1);
    my $inner = substr($content, $brace + 1, $end - $brace - 2);
    my $title = ""; if ($inner =~ s/\btitle:\s*([^;]+;)/ /gs) { $title = "Gtk.Label { label: $1 styles [ \"title-1\" ] }"; }
    my $desc = ""; if ($inner =~ s/\bdescription:\s*([^;]+;)/ /gs) { $desc = "Gtk.Label { label: $1 }"; }
    my $replacement = "Gtk.Box { orientation: vertical; $title $desc $inner }";
    substr($content, $start, $end - $start) = $replacement;
    pos($content) = $start + length($replacement);
}

# 4. Simple replacements
$content =~ s/\bAdw\.ToolbarView\b/Gtk.Box { orientation: vertical; /g;
$content =~ s/\bAdw\.WindowTitle\b/Gtk.Label/g;
$content =~ s/\bAdw\.Dialog\b/Adw.Window/g;
$content =~ s/\bAdw\.PreferencesDialog\b/Adw.PreferencesWindow/g;

# 5. Property and Slot cleanup
$content =~ s/\[(top|bottom|start|end)\]//g;
$content =~ s/\b(top-bar-style|centering-policy|enable-transitions|content-width|content-height|default-widget|focus-widget):\s*[^;]+;//g;
$content =~ s/\b(content|child):\s*//g;

# 6. Title to Label for Gtk.Label
while ($content =~ m/\bGtk\.Label(?:\s+[a-zA-Z0-9_]+)?\s*\{/g) {
    my $brace = $+[0] - 1; my $end = find_block_end($content, $brace + 1);
    my $inner = substr($content, $brace, $end - $brace);
    $inner =~ s/\btitle:\s*/label: /g; $inner =~ s/\bsubtitle:\s*[^;]+;//g;
    substr($content, $brace, $end - $brace) = $inner;
    pos($content) = $end;
}

# 7. Semicolon Normalization (Picky compiler)
# First remove all trailing semicolons after blocks
$content =~ s/\}\s*;/}/g;
# Ensure properties have semicolons, but NOT child widgets
# This is tricky. We'll look for key: value without a trailing semicolon.
$content =~ s/([a-z0-9-]+\s*:\s*[^;\{\}\n]+)(?<!;)(?=\n)/$1;/g;

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
chmod +x linuxdeploy linuxdeploy-plugin-gtk.sh appimagetool

export PATH="$PWD:$PATH"
export VERSION
export DEPLOY_GTK_VERSION=4

# Explicitly list libraries to bundle to ensure we hit 30MB+ size
./linuxdeploy --appdir "$APPDIR" \
    -e "$APPDIR/usr/bin/gnome-sudoku" \
    --library /usr/lib/x86_64-linux-gnu/libadwaita-1.so.0 \
    --library /usr/lib/x86_64-linux-gnu/libgtk-4.so.1 \
    --library /usr/lib/x86_64-linux-gnu/libgee-0.8.so.2 \
    --library /usr/lib/x86_64-linux-gnu/libjson-glib-1.0.so.0 \
    --library /usr/lib/x86_64-linux-gnu/libpango-1.0.so.0 \
    --library /usr/lib/x86_64-linux-gnu/libpangocairo-1.0.so.0 \
    --library /usr/lib/x86_64-linux-gnu/libgirepository-1.0.so.1 \
    --plugin gtk

glib-compile-schemas "$APPDIR/usr/share/glib-2.0/schemas"

cat << 'EOF' > "$APPDIR/AppRun"
#!/bin/sh
HERE="$(dirname "$(readlink -f "${0}")")"
export GSETTINGS_SCHEMA_DIR="$HERE/usr/share/glib-2.0/schemas"
export XDG_DATA_DIRS="$HERE/usr/share:$XDG_DATA_DIRS"
export LD_LIBRARY_PATH="$HERE/usr/lib:$HERE/usr/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH"
export GI_TYPELIB_PATH="$HERE/usr/lib/girepository-1.0:$HERE/usr/lib/x86_64-linux-gnu/girepository-1.0:$GI_TYPELIB_PATH"
export GTK_THEME=Adwaita
exec "$HERE/usr/bin/gnome-sudoku" "$@"
EOF
chmod +x "$APPDIR/AppRun"

./appimagetool "$APPDIR" Sudoku-49.4-x86_64.AppImage
echo "Done!"
