#!/bin/bash
set -e
export APPIMAGE_EXTRACT_AND_RUN=1
VERSION="49.4"
APPDIR="AppDir"
LOCAL_PREFIX="$PWD/local_prefix"

cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"
rm -rf "$APPDIR" "$PROJECT_DIR" blueprint-dest "$LOCAL_PREFIX"
mkdir -p "$APPDIR" "$LOCAL_PREFIX"

# Helper function to download and extract tarballs
download_extract() {
    local url=$1
    local name=$2
    echo "=== Downloading $name ==-"
    wget -q "$url" -O "$name.tar.xz"
    mkdir -p "$name"
    tar -xf "$name.tar.xz" -C "$name" --strip-components=1
}

# 1. Install blueprint-compiler (via pip from author's repo)
echo "=== Installing blueprint-compiler ==-"
# Use author's repo directly if GitLab is down
pip3 install git+https://github.com/jwestman/blueprint-compiler.git || \
pip3 install blueprint-compiler || echo "Failed to install blueprint-compiler"

# 2. Build GLib 2.82
download_extract "https://download.gnome.org/sources/glib/2.82/glib-2.82.5.tar.xz" "glib"
cd glib
meson setup build --prefix="$LOCAL_PREFIX" -Dtests=false -Dnls=disabled
meson install -C build
cd "$REPO_ROOT"

# 3. Build Cairo 1.18
download_extract "https://gitlab.freedesktop.org/cairo/cairo/-/archive/1.18.2/cairo-1.18.2.tar.xz" "cairo"
cd cairo
meson setup build --prefix="$LOCAL_PREFIX" -Dtests=disabled -Dglib=enabled
meson install -C build
cd "$REPO_ROOT"

# 4. Build Graphene 1.10
download_extract "https://github.com/ebassi/graphene/archive/refs/tags/1.10.8.tar.gz" "graphene"
cd graphene
meson setup build --prefix="$LOCAL_PREFIX" -Dtests=false -Dintrospection=disabled
meson install -C build
cd "$REPO_ROOT"

# 5. Build GTK 4.16
download_extract "https://download.gnome.org/sources/gtk/4.16/gtk-4.16.12.tar.xz" "gtk"
cd gtk
export PKG_CONFIG_PATH="$LOCAL_PREFIX/lib/x86_64-linux-gnu/pkgconfig:$LOCAL_PREFIX/lib/pkgconfig:$PKG_CONFIG_PATH"
export LD_LIBRARY_PATH="$LOCAL_PREFIX/lib/x86_64-linux-gnu:$LOCAL_PREFIX/lib:$LD_LIBRARY_PATH"
meson setup build --prefix="$LOCAL_PREFIX" \
    -Dmedia-gstreamer=disabled \
    -Dvulkan=disabled \
    -Dbuild-demos=false \
    -Dbuild-tests=false \
    -Dbuild-examples=false \
    -Dintrospection=disabled
meson install -C build
cd "$REPO_ROOT"

# 6. Build Libadwaita 1.6
download_extract "https://download.gnome.org/sources/libadwaita/1.6/libadwaita-1.6.3.tar.xz" "libadwaita"
cd libadwaita
meson setup build --prefix="$LOCAL_PREFIX" \
    -Dtests=false \
    -Dexamples=false \
    -Dvapi=false \
    -Dintrospection=disabled
meson install -C build
cd "$REPO_ROOT"

# 7. Build Sudoku 49.4
echo "=== Fetching Sudoku source ==-"
git clone --depth 1 --branch "$VERSION" https://github.com/GNOME/gnome-sudoku.git "gnome-sudoku-$VERSION"
cd "gnome-sudoku-$VERSION"
sed -i "s/glib_version = '[0-9.]*'/glib_version = '2.72.0'/g" meson.build
meson setup build --prefix=/usr -Dbuildtype=release
meson compile -C build -v
DESTDIR="$REPO_ROOT/$APPDIR" meson install -C build
cd "$REPO_ROOT"

# 8. Packaging
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
    --plugin gtk \
    --library "$LOCAL_PREFIX/lib/x86_64-linux-gnu/libgtk-4.so.1" \
    --library "$LOCAL_PREFIX/lib/x86_64-linux-gnu/libadwaita-1.so.0" \
    --library "$LOCAL_PREFIX/lib/x86_64-linux-gnu/libglib-2.0.so.0" \
    --library "$LOCAL_PREFIX/lib/x86_64-linux-gnu/libgio-2.0.so.0" \
    --library "$LOCAL_PREFIX/lib/x86_64-linux-gnu/libgobject-2.0.so.0" \
    --library "$LOCAL_PREFIX/lib/x86_64-linux-gnu/libcairo.so.2" \
    --library "$LOCAL_PREFIX/lib/x86_64-linux-gnu/libgraphene-1.0.so.0"

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
