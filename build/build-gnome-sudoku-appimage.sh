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

# 3. Fetch Subprojects (Modern GNOME Stack)
echo "=== Fetching Subprojects from GitLab ==-"
cd "$PROJECT_DIR"
mkdir -p subprojects
git clone --depth 1 https://gitlab.gnome.org/GNOME/libadwaita.git subprojects/libadwaita
git clone --depth 1 https://gitlab.gnome.org/GNOME/gtk.git subprojects/gtk
git clone --depth 1 https://gitlab.gnome.org/GNOME/glib.git subprojects/glib
git clone --depth 1 https://github.com/ebassi/graphene.git subprojects/graphene
git clone --depth 1 https://gitlab.gnome.org/GNOME/pango.git subprojects/pango
git clone --depth 1 https://github.com/harfbuzz/harfbuzz.git subprojects/harfbuzz
git clone --depth 1 https://github.com/fribidi/fribidi.git subprojects/fribidi

# 4. Build Sudoku with Subprojects
echo "=== Building Sudoku + Modern Stack (This takes 20-30 mins) ==-"
# We use --wrap-mode=forcefallback to ensure all dependencies use the subprojects.
# We disable heavy components to speed up the build.
meson setup build --prefix=/usr -Dbuildtype=release \
    --wrap-mode=forcefallback \
    -Dgtk:media-gstreamer=disabled \
    -Dgtk:vulkan=disabled \
    -Dgtk:build-demos=false \
    -Dgtk:build-tests=false \
    -Dgtk:build-examples=false \
    -Dlibadwaita:tests=false \
    -Dlibadwaita:examples=false \
    -Dlibadwaita:vapi=false \
    -Dglib:tests=false
    
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

# Deployment: captured the modern libs we just built
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
