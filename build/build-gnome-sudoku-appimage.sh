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

# 3. Patch for Debian 12 libraries (GTK 4.8, Libadwaita 1.2)
echo "=== Patching Sudoku for Debian 12 ==-"
sed -i "s/glib_version = '[0-9.]*'/glib_version = '2.74.0'/g" "$PROJECT_DIR/meson.build" || true
sed -i "s/gtk4', version: '>= [0-9.]*'/gtk4', version: '>= 4.8.0'/g" "$PROJECT_DIR/meson.build" || true
sed -i "s/libadwaita-1', version: '>= [0-9.]*'/libadwaita-1', version: '>= 1.2.0'/g" "$PROJECT_DIR/meson.build" || true

# Inject Pango/PangoCairo
sed -i "s/gnome_sudoku_vala_args = \[/gnome_sudoku_vala_args = ['--pkg=pango', '--pkg=pangocairo', /" "$PROJECT_DIR/src/meson.build"
sed -i "s/libsudoku = static_library('sudoku', libsudoku_sources,/libsudoku = static_library('sudoku', libsudoku_sources, vala_args: ['--pkg=pango', '--pkg=pangocairo'],/" "$PROJECT_DIR/lib/meson.build"

# Robust CSS Patcher
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

for css in "$PROJECT_DIR"/data/*.css; do
    echo "Patching CSS: $css"
    perl patch_css.pl < "$css" > "$css.tmp" && mv "$css.tmp" "$css"
done

# Standalone Blueprint Patcher
cat << 'EOF' > patch_blp.pl
undef $/;
my $content = <STDIN>;
sub find_block {
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
foreach my $type (qw(Spin Switch)) {
    while ($content =~ m/\bAdw\.${type}Row(?:\s+([a-zA-Z0-9_]+))?\s*\{/g) {
        my $match_start = $-[0];
        my $id = $1 // "tmp_id";
        my $brace_start = $+[0] - 1;
        my $block_end = find_block($content, $brace_start + 1);
        my $inner = substr($content, $brace_start + 1, $block_end - $brace_start - 2);
        my $title = ($inner =~ s/\btitle:\s*([^;]+);//) ? "title: $1;" : "title: \" \";";
        my $use_underline = ($inner =~ s/\buse-underline:\s*([^;]+);//) ? "use-underline: $1;" : "";
        $inner =~ s/\bvalign:\s*[^;]+;//g;
        my $new_widget = ($type eq "Spin") ? "Gtk.SpinButton" : "Gtk.Switch";
        my $replacement = "Adw.ActionRow { $title $use_underline [suffix] $new_widget $id { valign: center; $inner } }";
        substr($content, $match_start, $block_end - $match_start) = $replacement;
        pos($content) = $match_start + length($replacement);
    }
}
while ($content =~ m/\bAdw\.StatusPage\s*\{/g) {
    my $match_start = $-[0];
    my $brace_start = $+[0] - 1;
    my $block_end = find_block($content, $brace_start + 1);
    my $inner = substr($content, $brace_start + 1, $block_end - $brace_start - 2);
    my $title = ($inner =~ s/\btitle:\s*(_\("[^"]+"\));//) ? $1 : "\" \"";
    $inner =~ s/\bvalign:\s*[^;]+;//g;
    my $replacement = "Gtk.Box { orientation: vertical; valign: center; Gtk.Label { label: $title; styles [\"title-1\"] } $inner }";
    substr($content, $match_start, $block_end - $match_start) = $replacement;
    pos($content) = $match_start + length($replacement);
}
$content =~ s/\bAdw\.ToolbarView\b/Gtk.Box/g;
$content =~ s/\bAdw\.WindowTitle\b/Gtk.Label/g;
$content =~ s/\bAdw\.Dialog\b/Adw.Window/g;
$content =~ s/\bAdw\.PreferencesDialog\b/Adw.PreferencesWindow/g;
while ($content =~ m/\bGtk\.Label(?:\s+[a-zA-Z0-9_]+)?\s*\{/g) {
    my $brace_start = $+[0] - 1;
    my $block_end = find_block($content, $brace_start + 1);
    my $inner = substr($content, $brace_start + 1, $block_end - $brace_start - 2);
    $inner =~ s/\btitle\s*:\s*/label: /g;
    $inner =~ s/\bsub(?:title|label):\s*[^;]+;//g;
    substr($content, $brace_start + 1, $block_end - $brace_start - 2) = $inner;
    pos($content) = $block_end;
}
$content =~ s/(Gtk\.Box\s*\{)(?![\s\S]*?orientation: vertical;)/$1 orientation: vertical; /gs;
$content =~ s/\b(content|child):\s*//g;
$content =~ s/\[(top|bottom|start|end)\]\s*//g;
$content =~ s/\b(top-bar-style|centering-policy|enable-transitions|content-width|content-height|default-widget|focus-widget):\s*[^;]+;\s*//g;
$content =~ s/\}\s*;/}/g;
my @props = qw(adjustment popover title-widget menu-model model);
foreach my $prop (@props) {
    while ($content =~ m/\b$prop:\s*[a-zA-Z0-9\.\$]+\s*[a-zA-Z0-9_]*\s*\{/g) {
        my $block_end = find_block($content, $+[0]);
        substr($content, $block_end, 0) = ";";
        pos($content) = $block_end + 1;
    }
}
print $content;
EOF

for f in "$PROJECT_DIR"/src/blueprints/*.blp; do
    echo "Patching Blueprint: $f"
    perl patch_blp.pl < "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done

# Standalone Vala Patcher
cat << 'EOF' > patch_vala.pl
undef $/;
my $content = <STDIN>;
my $file = $ARGV[0];
$content =~ s/Adw\.AlertDialog/Adw.MessageDialog/g;
$content =~ s/\bunowned\s+Adw\.WindowTitle/unowned Gtk.Label/g;
$content =~ s/\bunowned\s+Adw\.SpinRow/unowned Gtk.SpinButton/g;
$content =~ s/\bunowned\s+Adw\.SwitchRow/unowned Gtk.Switch/g;
$content =~ s/\bunowned\s+Adw\.ToolbarView/unowned Gtk.Box/g;
$content =~ s/\bunowned\s+Adw\.StatusPage/unowned Gtk.Box/g;
$content =~ s/windowtitle\.subtitle\s*=\s*.*;/\/\/subtitle stub/g;
$content =~ s/windowtitle\.title\s*=\s*/windowtitle.label = /g;
if ($file =~ /earmark.vala/) {
    $content =~ s/public\s+void\s+play_hide_animation\s*\(\)\s*\{((?:[^{}]|(?1))*)\}/public void play_hide_animation () { }/g;
    $content =~ s/public\s+void\s+skip_animation\s*\(\)\s*\{((?:[^{}]|(?1))*)\}/public void skip_animation () { }/g;
}
if ($file =~ /window.vala/) {
    $content =~ s/notify\s*\[\s*"visible-dialog"\s*\]/\/\/notify/g;
    $content =~ s/private\s+void\s+visible_dialog_cb\s*\(\)\s*\{((?:[^{}]|\{(?1)\})*)\}/private void visible_dialog_cb () { }/g;
    $content =~ s/void\s+set_accent_color\s*\(\)\s*\{((?:[^{}]|\{(?1)\})*)\}/void set_accent_color () { }/g;
    $content =~ s/style_manager.notify\s*\[\s*"accent-color"\s*\]/\/\/style_manager.notify/g;
    $content =~ s/accent_provider.load_from_string\s*\(\s*s\s*\)/accent_provider.load_from_data(s.data)/g;
    $content =~ s/dispose_template\s*\(\s*this.get_type\s*\(\)\s*\);/\/\/dispose_template/g;
}
if ($file =~ /gnome-sudoku.vala/ || $file =~ /printer.vala/ || $file =~ /game-view.vala/) {
    $content =~ s/ApplicationFlags.DEFAULT_FLAGS/ApplicationFlags.FLAGS_NONE/g;
    my $parent = ($file =~ /gnome-sudoku.vala/) ? "window" : "null";
    $content =~ s{new\s+Adw\.MessageDialog\s*\((.*)\);}{
        my $args = $1;
        if ($args !~ m/,/) { $args .= ", null"; }
        "new Adw.MessageDialog($parent, $args);"
    }ge;
    $content =~ s/var\s+about_dialog\s*=\s*new\s+Adw.AboutDialog.from_appdata\s*\(([^,]+),\s*VERSION\);/var about_dialog = new Gtk.AboutDialog(); about_dialog.set_program_name("Sudoku"); about_dialog.set_version(VERSION); about_dialog.set_transient_for(window);/g;
    $content =~ s/about_dialog.set_developers/about_dialog.set_authors/g;
    $content =~ s/\.present\s*\(\s*window\s*\)/.present()/g;
}
if ($file =~ /preferences-dialog.vala/) {
    $content =~ s/Adw.PreferencesDialog/Adw.PreferencesWindow/g;
    $content =~ s/dispose_template\s*\(\s*this.get_type\s*\(\)\s*\);/\/\/dispose_template/g;
}
if ($file =~ /print-dialog.vala/) {
    $content =~ s/Adw.Dialog/Adw.Window/g;
}
print $content;
EOF

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

# Deploy dependencies
./linuxdeploy --appdir "$APPDIR" \
    -e "$APPDIR/usr/bin/gnome-sudoku" \
    ${DESKTOP_FILE:+ -d "$DESKTOP_FILE"} \
    ${ICON_FILE:+ -i "$ICON_FILE"}

# Manually compile schemas inside AppDir
echo "=== Compiling GSettings schemas ==-"
glib-compile-schemas "$APPDIR/usr/share/glib-2.0/schemas"

# Create a robust custom AppRun
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
