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

# 1. Build blueprint-compiler (v0.16.0)
echo "=== Building blueprint-compiler ==-"
git clone --depth 1 --branch v0.16.0 https://gitlab.gnome.org/jwestman/blueprint-compiler.git
cd blueprint-compiler
meson setup build --prefix=/usr
DESTDIR="$REPO_ROOT/blueprint-dest" meson install -C build
export PATH="$REPO_ROOT/blueprint-dest/usr/bin:$PATH"
export PYTHONPATH="$REPO_ROOT/blueprint-dest/usr/lib/python3/dist-packages:$PYTHONPATH"
cd "$REPO_ROOT"

# 2. Fetch Sudoku source
echo "=== Fetching gnome-sudoku $VERSION ==-"
git clone --depth 1 --branch "$VERSION" "$REPO_URL" "$PROJECT_DIR"

# 3. Add Subprojects for modern dependencies
echo "=== Setting up Subprojects with Wrap files ==-"
cd "$PROJECT_DIR"
mkdir -p subprojects

# We only build the absolute minimum needed: GTK4 and Libadwaita.
# We will use the system GLib/Pango to avoid dependency hell.
# We relax the requirements in Sudoku to allow the system GLib.

sed -i "s/glib-2.0', version: '>= [0-9.]*'/glib-2.0', version: '>= 2.72.0'/g" meson.build
sed -i "s/gio-2.0', version: '>= [0-9.]*'/gio-2.0', version: '>= 2.72.0'/g" meson.build

cat << EOF > subprojects/gtk4.wrap
[wrap-git]
url = https://gitlab.gnome.org/GNOME/gtk.git
revision = 4.16.12
depth = 1

[provide]
dependency_names = gtk4
EOF

cat << EOF > subprojects/libadwaita-1.wrap
[wrap-git]
url = https://gitlab.gnome.org/GNOME/libadwaita.git
revision = 1.6.3
depth = 1

[provide]
dependency_names = libadwaita-1
EOF

# 4. Build Sudoku
echo "=== Building Sudoku + Modern UI Stack ==-"
# We only force fallback for the UI libs.
meson setup build --prefix=/usr -Dbuildtype=release \
    --force-fallback-for=gtk4,libadwaita-1 \
    -Dgtk:media-gstreamer=disabled \
    -Dgtk:vulkan=disabled \
    -Dgtk:build-demos=false \
    -Dgtk:build-tests=false \
    -Dgtk:build-examples=false \
    -Dlibadwaita:tests=false \
    -Dlibadwaita:examples=false \
    -Dlibadwaita:vapi=false
    
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

./linuxdeploy --appdir "$APPDIR" \
    -e "$APPDIR/usr/bin/gnome-sudoku" \
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
