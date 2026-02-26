#!/bin/bash
set -e
export APPIMAGE_EXTRACT_AND_RUN=1
VERSION="46.0"
REPO_URL="https://github.com/GNOME/gnome-sudoku.git"
PROJECT_DIR="gnome-sudoku-$VERSION"
APPDIR="AppDir"

cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"
rm -rf "$APPDIR" "$PROJECT_DIR" blueprint-dest
mkdir -p "$APPDIR"

# 1. Build blueprint-compiler (v0.16.0)
echo "=== Building blueprint-compiler ==-"
git clone --depth 1 --branch v0.16.0 https://github.com/JamesWestman/blueprint-compiler.git blueprint-compiler
cd blueprint-compiler
meson setup build --prefix=/usr
DESTDIR="$REPO_ROOT/blueprint-dest" meson install -C build
export PATH="$REPO_ROOT/blueprint-dest/usr/bin:$PATH"
export PYTHONPATH="$REPO_ROOT/blueprint-dest/usr/lib/python3/dist-packages:$PYTHONPATH"
cd "$REPO_ROOT"

# 2. Fetch Sudoku source (v46.0)
echo "=== Fetching gnome-sudoku $VERSION ==-"
git clone --depth 1 --branch "$VERSION" "$REPO_URL" "$PROJECT_DIR"

# 3. Patching for Debian 12 (v46.0 is MUCH closer)
cd "$PROJECT_DIR"
sed -i "s/glib-2.0', version: '>= [0-9.]*'/glib-2.0', version: '>= 2.74.0'/g" meson.build
sed -i "s/gtk4', version: '>= [0-9.]*'/gtk4', version: '>= 4.8.0'/g" meson.build
sed -i "s/libadwaita-1', version: '>= [0-9.]*'/libadwaita-1', version: '>= 1.2.0'/g" meson.build

# Fix C++ for older compilers
sed -i '1i #include <ctime>\n#include <cstdlib>' lib/qqwing-wrapper.cpp
sed -i 's/srand\s*(.*)/srand(time(NULL))/g' lib/qqwing-wrapper.cpp

# 4. Build Sudoku
echo "=== Building Sudoku ==-"
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

./appimagetool "$APPDIR" Sudoku-46.0-x86_64.AppImage
echo "Done!"
