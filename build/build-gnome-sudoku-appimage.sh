#!/bin/bash
set -e
VERSION="47.3"
REPO_URL="https://gitlab.gnome.org/GNOME/gnome-sudoku.git"
PROJECT_DIR="gnome-sudoku-$VERSION"
APPDIR="AppDir"
cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"
rm -rf "$APPDIR" "$PROJECT_DIR"
mkdir -p "$APPDIR"
git clone --depth 1 --branch "$VERSION" "$REPO_URL" "$PROJECT_DIR"
python3 -m venv venv_build
source venv_build/bin/activate
pip install meson ninja
cd "$PROJECT_DIR"
meson setup build --prefix=/usr -Dbuildtype=release
meson compile -C build
DESTDIR="$REPO_ROOT/$APPDIR" meson install -C build
cd "$REPO_ROOT"
wget -q https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage -O linuxdeploy
chmod +x linuxdeploy
export VERSION
./linuxdeploy --appdir "$APPDIR" -e "$APPDIR/usr/bin/gnome-sudoku" --output appimage
