#!/bin/bash
set -e
VERSION="47.3"
REPO_URL="https://gitlab.gnome.org/GNOME/gnome-sudoku.git"
PROJECT_DIR="gnome-sudoku-$VERSION"
APPDIR="AppDir"

cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"
echo "Repo root: $REPO_ROOT"

rm -rf "$APPDIR" "$PROJECT_DIR"
mkdir -p "$APPDIR"

echo "=== Fetching gnome-sudoku $VERSION ==-"
git clone --depth 1 --branch "$VERSION" "$REPO_URL" "$PROJECT_DIR"

# Setup Meson
python3 -m venv venv_build
source venv_build/bin/activate
pip install meson ninja

cd "$PROJECT_DIR"
echo "=== Building gnome-sudoku ==-"
meson setup build --prefix=/usr -Dbuildtype=release
meson compile -C build
DESTDIR="$REPO_ROOT/$APPDIR" meson install -C build
cd "$REPO_ROOT"

# Robust GIO modules
mkdir -p "$APPDIR/usr/lib/gio/modules"
GIO_MOD_PATHS=("/usr/lib/x86_64-linux-gnu/gio/modules" "/usr/lib64/gio/modules" "/usr/lib/gio/modules")
for p in "${GIO_MOD_PATHS[@]}"; do
    if [ -d "$p" ]; then
        cp -a "$p"/libgiognutls.so "$APPDIR/usr/lib/gio/modules/" 2>/dev/null || true
        cp -a "$p"/libdconfsettings.so "$APPDIR/usr/lib/gio/modules/" 2>/dev/null || true
    fi
done

# Package
wget -q https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage -O linuxdeploy
chmod +x linuxdeploy
export VERSION
./linuxdeploy --appdir "$APPDIR" -e "$APPDIR/usr/bin/gnome-sudoku" --output appimage
