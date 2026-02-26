#!/bin/bash
set -e
export APPIMAGE_EXTRACT_AND_RUN=1
VERSION="49.4"
REPO_URL="https://gitlab.gnome.org/GNOME/gnome-sudoku.git"
PROJECT_DIR="gnome-sudoku-$VERSION"
APPDIR="AppDir"

cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"
rm -rf "$APPDIR" "$PROJECT_DIR"
mkdir -p "$APPDIR"

# Fetch Sudoku source
echo "=== Fetching gnome-sudoku $VERSION ==-"
git clone --depth 1 --branch "$VERSION" "$REPO_URL" "$PROJECT_DIR"

# Patch dependencies to match Fedora 41
echo "=== Patching dependencies in meson.build ==-"
sed -i "s/gtk4', version: '>= [0-9.]*'/gtk4', version: '>= 4.16.0'/g" "$PROJECT_DIR/meson.build"
sed -i "s/libadwaita-1', version: '>= [0-9.]*'/libadwaita-1', version: '>= 1.6.0'/g" "$PROJECT_DIR/meson.build"
sed -i "s/glib-2.0', version: '>= [0-9.]*'/glib-2.0', version: '>= 2.82.0'/g" "$PROJECT_DIR/meson.build"

# Patch Blueprints for Libadwaita 1.6 compatibility
echo "=== Patching Blueprints ==-"
find "$PROJECT_DIR" -name "*.blp" -exec sed -i '/enable-transitions:/d' {} +

# Minimal fixes (Only C++ and non-UI code)
echo "=== Applying Minimal Code Fixes ==-"
sed -i '1i #include <ctime>\n#include <cstdlib>' "$PROJECT_DIR/lib/qqwing-wrapper.cpp"
sed -i 's/srand\s*(.*)/srand(time(NULL))/g' "$PROJECT_DIR/lib/qqwing-wrapper.cpp"

# Build Sudoku (On Fedora 41, this will work with GTK 4.18)
echo "=== Building Sudoku ==-"
cd "$PROJECT_DIR"
meson setup build --prefix=/usr -Dbuildtype=release
meson compile -C build -v
DESTDIR="$REPO_ROOT/$APPDIR" meson install -C build
cd "$REPO_ROOT"

# Packaging
echo "=== Packaging AppImage ==-"
wget -q https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage -O linuxdeploy
wget -q https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/master/linuxdeploy-plugin-gtk.sh -O linuxdeploy-plugin-gtk.sh
wget -q https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage -O appimagetool
chmod +x linuxdeploy linuxdeploy-plugin-gtk.sh appimagetool

export PATH="$PWD:$PATH"
export VERSION
export DEPLOY_GTK_VERSION=4
export NO_STRIP=1

# Bundle EVERYTHING from the modern Fedora host
./linuxdeploy --appdir "$APPDIR" \
    -e "$APPDIR/usr/bin/gnome-sudoku" \
    --plugin gtk \
    --library /usr/lib64/libadwaita-1.so.0 \
    --library /usr/lib64/libgtk-4.so.1 \
    --library /usr/lib64/libgee-0.8.so.2 \
    --library /usr/lib64/libjson-glib-1.0.so.0 \
    --library /usr/lib64/libpango-1.0.so.0 \
    --library /usr/lib64/libpangocairo-1.0.so.0 \
    --library /usr/lib64/libgirepository-1.0.so.1 \
    --library /usr/lib64/libgraphene-1.0.so.0 \
    --library /usr/lib64/libglib-2.0.so.0 \
    --library /usr/lib64/libgobject-2.0.so.0 \
    --library /usr/lib64/libgio-2.0.so.0

glib-compile-schemas "$APPDIR/usr/share/glib-2.0/schemas"

cat << 'EOF' > "$APPDIR/AppRun"
#!/bin/sh
HERE="$(dirname "$(readlink -f "${0}")")"
export GSETTINGS_SCHEMA_DIR="$HERE/usr/share/glib-2.0/schemas"
export XDG_DATA_DIRS="$HERE/usr/share:$XDG_DATA_DIRS"
export LD_LIBRARY_PATH="$HERE/usr/lib:$HERE/usr/lib64:$LD_LIBRARY_PATH"
export GI_TYPELIB_PATH="$HERE/usr/lib/girepository-1.0:$HERE/usr/lib64/girepository-1.0:$GI_TYPELIB_PATH"
export GTK_THEME=Adwaita
exec "$HERE/usr/bin/gnome-sudoku" "$@"
EOF
chmod +x "$APPDIR/AppRun"

./appimagetool "$APPDIR" Sudoku-49.4-x86_64.AppImage
echo "Done!"
