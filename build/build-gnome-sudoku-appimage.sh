#!/bin/bash
set -e
VERSION="49.4"
REPO_URL="https://gitlab.gnome.org/GNOME/gnome-sudoku.git"
PROJECT_DIR="gnome-sudoku-$VERSION"
APPDIR="AppDir"

cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"
echo "Repo root: $REPO_ROOT"

rm -rf "$APPDIR" "$PROJECT_DIR" blueprint-compiler
mkdir -p "$APPDIR"

# 1. Build blueprint-compiler from source (not on PyPI)
echo "=== Building blueprint-compiler ==-"
git clone --depth 1 https://gitlab.gnome.org/jwestman/blueprint-compiler.git
cd blueprint-compiler
python3 -m venv venv_blueprint
source venv_blueprint/bin/activate
pip install meson ninja
meson setup build --prefix=/usr
meson install -C build DESTDIR="$REPO_ROOT/blueprint-dest"
export PATH="$REPO_ROOT/blueprint-dest/usr/bin:$PATH"
export PYTHONPATH="$REPO_ROOT/blueprint-dest/usr/lib/python3/dist-packages:$REPO_ROOT/blueprint-dest/usr/lib/python3.12/site-packages:$PYTHONPATH"
cd "$REPO_ROOT"

# 2. Build gnome-sudoku
echo "=== Fetching gnome-sudoku $VERSION ==-"
git clone --depth 1 --branch "$VERSION" "$REPO_URL" "$PROJECT_DIR"

echo "=== Patching dependencies for Ubuntu 24.04 ==-"
sed -i "s/glib_version = '2.80.0'/glib_version = '2.79.0'/g" "$PROJECT_DIR/meson.build"
sed -i "s/gtk4', version: '>= 4.18.0'/gtk4', version: '>= 4.14.0'/g" "$PROJECT_DIR/meson.build"
sed -i "s/libadwaita-1', version: '>= 1.7'/libadwaita-1', version: '>= 1.5'/g" "$PROJECT_DIR/meson.build"

cd "$PROJECT_DIR"
echo "=== Building gnome-sudoku ==-"
meson setup build --prefix=/usr -Dbuildtype=release
meson compile -C build
DESTDIR="$REPO_ROOT/$APPDIR" meson install -C build
cd "$REPO_ROOT"

# 3. Robust GIO modules
mkdir -p "$APPDIR/usr/lib/gio/modules"
GIO_MOD_PATHS=("/usr/lib/x86_64-linux-gnu/gio/modules" "/usr/lib64/gio/modules" "/usr/lib/gio/modules")
for p in "${GIO_MOD_PATHS[@]}"; do
    if [ -d "$p" ]; then
        cp -a "$p"/libgiognutls.so "$APPDIR/usr/lib/gio/modules/" 2>/dev/null || true
        cp -a "$p"/libdconfsettings.so "$APPDIR/usr/lib/gio/modules/" 2>/dev/null || true
    fi
done

# 4. Package
wget -q https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage -O linuxdeploy
chmod +x linuxdeploy
export VERSION
./linuxdeploy --appdir "$APPDIR" -e "$APPDIR/usr/bin/gnome-sudoku" --output appimage
