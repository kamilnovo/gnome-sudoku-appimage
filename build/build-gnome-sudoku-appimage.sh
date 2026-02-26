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

# 1. Fetch Sudoku source
echo "=== Fetching gnome-sudoku $VERSION ==-"
git clone --depth 1 --branch "$VERSION" "$REPO_URL" "$PROJECT_DIR"

# 2. Patch dependencies to match Fedora 41 (just in case they are even newer)
echo "=== Patching dependencies in meson.build ==-"
sed -i "s/gtk4', version: '>= [0-9.]*'/gtk4', version: '>= 4.16.0'/g" "$PROJECT_DIR/meson.build"
sed -i "s/libadwaita-1', version: '>= [0-9.]*'/libadwaita-1', version: '>= 1.6.0'/g" "$PROJECT_DIR/meson.build"
sed -i "s/glib-2.0', version: '>= [0-9.]*'/glib-2.0', version: '>= 2.82.0'/g" "$PROJECT_DIR/meson.build"

# 3. Patch Blueprints for Libadwaita 1.6 compatibility
echo "=== Patching Blueprints ==-"
find "$PROJECT_DIR" -name "*.blp" -exec sed -i '/enable-transitions:/d' {} +

# 4. Build Sudoku
echo "=== Building Sudoku ==-"
cd "$PROJECT_DIR"
meson setup build --prefix=/usr -Dbuildtype=release
meson compile -C build -v
DESTDIR="$REPO_ROOT/$APPDIR" meson install -C build
cd "$REPO_ROOT"

# 5. Packaging with Private Glibc
echo "=== Packaging AppImage with Private Glibc ==-"
wget -q https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage -O linuxdeploy
wget -q https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/master/linuxdeploy-plugin-gtk.sh -O linuxdeploy-plugin-gtk.sh
wget -q https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage -O appimagetool
chmod +x linuxdeploy linuxdeploy-plugin-gtk.sh appimagetool

# Install patchelf to fix the interpreter
dnf install -y patchelf

export PATH="$PWD:$PATH"
export VERSION
export DEPLOY_GTK_VERSION=4
export NO_STRIP=1

# Bundle EVERYTHING including the C library
./linuxdeploy --appdir "$APPDIR" \
    -e "$APPDIR/usr/bin/gnome-sudoku" \
    --plugin gtk \
    --library /usr/lib64/libadwaita-1.so.0 \
    --library /usr/lib64/libgtk-4.so.1 \
    --library /usr/lib64/libgee-0.8.so.2 \
    --library /usr/lib64/libjson-glib-1.0.so.0 \
    --library /usr/lib64/libglib-2.0.so.0 \
    --library /usr/lib64/libc.so.6 \
    --library /usr/lib64/libm.so.6 \
    --library /usr/lib64/libstdc++.so.6 \
    --library /usr/lib64/ld-linux-x86-64.so.2

# Fix the interpreter to point to our bundled linker
INTERP=$(find "$APPDIR" -name "ld-linux-x86-64.so.2" | head -n 1)
# Make path relative to AppRun
REL_INTERP=$(realpath --relative-to="$APPDIR/usr/bin" "$INTERP")
patchelf --set-interpreter "/usr/lib/ld-linux-x86-64.so.2" "$APPDIR/usr/bin/gnome-sudoku"

glib-compile-schemas "$APPDIR/usr/share/glib-2.0/schemas"

cat << 'EOF' > "$APPDIR/AppRun"
#!/bin/sh
HERE="$(dirname "$(readlink -f "${0}")")"
# Use our bundled linker to start the app
export LD_LIBRARY_PATH="$HERE/usr/lib:$HERE/usr/lib64:$LD_LIBRARY_PATH"
export GSETTINGS_SCHEMA_DIR="$HERE/usr/share/glib-2.0/schemas"
export XDG_DATA_DIRS="$HERE/usr/share:$XDG_DATA_DIRS"
export GTK_THEME=Adwaita
# Run via the bundled loader to ensure glibc parity
exec "$HERE/usr/lib/ld-linux-x86-64.so.2" "$HERE/usr/bin/gnome-sudoku" "$@"
EOF
chmod +x "$APPDIR/AppRun"

./appimagetool "$APPDIR" Sudoku-49.4-x86_64.AppImage
echo "Done!"
