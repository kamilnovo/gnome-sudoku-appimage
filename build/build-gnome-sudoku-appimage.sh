#!/bin/bash
set -e
export APPIMAGE_EXTRACT_AND_RUN=1
VERSION="49.4"
APPDIR="AppDir"
LOCAL_PREFIX="$PWD/local_prefix"

cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"
rm -rf "$APPDIR" "$PROJECT_DIR" "$LOCAL_PREFIX"
mkdir -p "$APPDIR" "$LOCAL_PREFIX"

# 1. Download and extract binary packages from Ubuntu 24.04 (Noble)
echo "=== Fetching modern binary dependencies (Noble) ==-"
# We need GLib 2.80+, GTK 4.14+, Libadwaita 1.5+
mkdir -p packages
cd packages
# Use Noble (24.04) which has GLib 2.80 and GTK 4.14
# Or Oracular (24.10) for even newer ones
BASE_URL="http://archive.ubuntu.com/ubuntu/pool/main"
UNIVERSE_URL="http://archive.ubuntu.com/ubuntu/pool/universe"

wget -q "$BASE_URL/g/glib2.0/libglib2.0-0t64_2.80.0-6ubuntu3.1_amd64.deb"
wget -q "$BASE_URL/g/glib2.0/libglib2.0-dev_2.80.0-6ubuntu3.1_amd64.deb"
wget -q "$BASE_URL/g/gtk+4.0/libgtk-4-1_4.14.2+ds-1ubuntu1_amd64.deb"
wget -q "$BASE_URL/g/gtk+4.0/libgtk-4-dev_4.14.2+ds-1ubuntu1_amd64.deb"
wget -q "$BASE_URL/liba/libadwaita-1/libadwaita-1-0_1.5.0-1_amd64.deb"
wget -q "$BASE_URL/liba/libadwaita-1/libadwaita-1-dev_1.5.0-1_amd64.deb"
wget -q "$UNIVERSE_URL/b/blueprint-compiler/blueprint-compiler_0.12.0-1_all.deb"

for deb in *.deb; do
    dpkg-deb -x "$deb" "$LOCAL_PREFIX"
done
cd "$REPO_ROOT"

# 2. Build Sudoku 49.4 against extracted binaries
echo "=== Building Sudoku $VERSION ==-"
export PKG_CONFIG_PATH="$LOCAL_PREFIX/usr/lib/x86_64-linux-gnu/pkgconfig:$LOCAL_PREFIX/usr/share/pkgconfig:$PKG_CONFIG_PATH"
export LD_LIBRARY_PATH="$LOCAL_PREFIX/usr/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH"
export PATH="$LOCAL_PREFIX/usr/bin:$PATH"
export PYTHONPATH="$LOCAL_PREFIX/usr/lib/python3/dist-packages:$PYTHONPATH"

git clone --depth 1 --branch "$VERSION" https://github.com/GNOME/gnome-sudoku.git "gnome-sudoku-$VERSION"
cd "gnome-sudoku-$VERSION"
# Fix Sudoku to accept the versions we downloaded
sed -i "s/glib_version = '[0-9.]*'/glib_version = '2.80.0'/g" meson.build
meson setup build --prefix=/usr -Dbuildtype=release
meson compile -C build -v
DESTDIR="$REPO_ROOT/$APPDIR" meson install -C build
cd "$REPO_ROOT"

# 3. Packaging
echo "=== Packaging AppImage ==-"
wget -q https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage -O linuxdeploy
wget -q https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/master/linuxdeploy-plugin-gtk.sh -O linuxdeploy-plugin-gtk.sh
wget -q https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage -O appimagetool
chmod +x linuxdeploy linuxdeploy-plugin-gtk.sh appimagetool

export PATH="$PWD:$PATH"
export VERSION
export DEPLOY_GTK_VERSION=4

# Bundle the extracted libraries
./linuxdeploy --appdir "$APPDIR" \
    -e "$APPDIR/usr/bin/gnome-sudoku" \
    --plugin gtk \
    --library "$LOCAL_PREFIX/usr/lib/x86_64-linux-gnu/libgtk-4.so.1" \
    --library "$LOCAL_PREFIX/usr/lib/x86_64-linux-gnu/libadwaita-1.so.0" \
    --library "$LOCAL_PREFIX/usr/lib/x86_64-linux-gnu/libglib-2.0.so.0" \
    --library "$LOCAL_PREFIX/usr/lib/x86_64-linux-gnu/libgio-2.0.so.0"

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
