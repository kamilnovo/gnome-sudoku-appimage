#!/bin/bash
set -e
export APPIMAGE_EXTRACT_AND_RUN=1
VERSION="49.4"
REPO_URL="https://gitlab.gnome.org/GNOME/gnome-sudoku.git"
PROJECT_DIR="gnome-sudoku-$VERSION"
APPDIR="AppDir"
LOCAL_PREFIX="$PWD/local_prefix"

cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"
rm -rf "$APPDIR" "$PROJECT_DIR" blueprint-dest "$LOCAL_PREFIX"
mkdir -p "$APPDIR" "$LOCAL_PREFIX"

# 1. Build blueprint-compiler (v0.16.0)
echo "=== Building blueprint-compiler ==-"
git clone --depth 1 --branch v0.16.0 https://gitlab.gnome.org/jwestman/blueprint-compiler.git
cd blueprint-compiler
meson setup build --prefix=/usr
DESTDIR="$REPO_ROOT/blueprint-dest" meson install -C build
export PATH="$REPO_ROOT/blueprint-dest/usr/bin:$PATH"
export PYTHONPATH="$REPO_ROOT/blueprint-dest/usr/lib/python3/dist-packages:$PYTHONPATH"
cd "$REPO_ROOT"

# 2. Build modern GLib (Required by GTK 4.16)
echo "=== Building GLib 2.82 ==-"
git clone --depth 1 --branch 2.82.5 https://gitlab.gnome.org/GNOME/glib.git
cd glib
meson setup build --prefix="$LOCAL_PREFIX" -Dtests=false -Dnls=disabled
meson install -C build
cd "$REPO_ROOT"

# 3. Build Graphene
echo "=== Building Graphene ==-"
git clone --depth 1 --branch 1.10.8 https://github.com/ebassi/graphene.git
cd graphene
meson setup build --prefix="$LOCAL_PREFIX" -Dtests=false -Dintrospection=disabled
meson install -C build
cd "$REPO_ROOT"

# 4. Build GTK 4.16 (Surgical Build)
echo "=== Building GTK 4.16 ==-"
export PKG_CONFIG_PATH="$LOCAL_PREFIX/lib/x86_64-linux-gnu/pkgconfig:$LOCAL_PREFIX/lib/pkgconfig:$PKG_CONFIG_PATH"
export LD_LIBRARY_PATH="$LOCAL_PREFIX/lib/x86_64-linux-gnu:$LOCAL_PREFIX/lib:$LD_LIBRARY_PATH"
git clone --depth 1 --branch 4.16.12 https://gitlab.gnome.org/GNOME/gtk.git
cd gtk
# We EXPLICITLY disable everything that causes dependency loops (harfbuzz, freetype, etc. fallbacks)
meson setup build --prefix="$LOCAL_PREFIX" \
    --wrap-mode=nodownload \
    -Dmedia-gstreamer=disabled \
    -Dvulkan=disabled \
    -Dbuild-demos=false \
    -Dbuild-tests=false \
    -Dbuild-examples=false \
    -Dintrospection=disabled \
    -Dcolord=disabled \
    -Dcups=disabled \
    -Dcloudproviders=disabled
meson install -C build
cd "$REPO_ROOT"

# 5. Build Libadwaita 1.6
echo "=== Building Libadwaita 1.6 ==-"
git clone --depth 1 --branch 1.6.3 https://gitlab.gnome.org/GNOME/libadwaita.git
cd libadwaita
meson setup build --prefix="$LOCAL_PREFIX" \
    -Dtests=false \
    -Dexamples=false \
    -Dvapi=false \
    -Dintrospection=disabled
meson install -C build
cd "$REPO_ROOT"

# 6. Build Sudoku 49.4 (Linked against local stack)
echo "=== Building Sudoku $VERSION ==-"
git clone --depth 1 --branch "$VERSION" "$REPO_URL" "$PROJECT_DIR"
cd "$PROJECT_DIR"
# We must patch Sudoku to use our local GLib/GTK/Adwaita via PKG_CONFIG_PATH
meson setup build --prefix=/usr -Dbuildtype=release
meson compile -C build -v
DESTDIR="$REPO_ROOT/$APPDIR" meson install -C build
cd "$REPO_ROOT"

# 7. Packaging
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
