#!/bin/bash
set -e

############################################
# Configuration
############################################
VERSION="47.3"
REPO_URL="https://gitlab.gnome.org/GNOME/gnome-sudoku.git"
PROJECT_DIR="gnome-sudoku-$VERSION"
APPDIR="AppDir"

# Always run from script directory parent (gnome-sudoku)
cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"
echo "Repo root: $REPO_ROOT"

# Clean up
rm -rf "$APPDIR" "$PROJECT_DIR"
mkdir -p "$APPDIR"

############################################
# 1. Download Source
############################################
if [ ! -d "$PROJECT_DIR" ]; then
    echo "=== Fetching gnome-sudoku $VERSION ==-"
    git clone --depth 1 --branch "$VERSION" "$REPO_URL" "$PROJECT_DIR"
fi

############################################
# 2. Setup Build Tools
############################################
if ! command -v meson &> /dev/null; then
    echo "=== Setting up Build Tools (Meson/Ninja) ==-"
    python3 -m venv venv_build
    source venv_build/bin/activate
    pip install meson ninja
else
    echo "Meson found in system."
fi

############################################
# 3. Build & Install to AppDir
############################################
cd "$PROJECT_DIR"
echo "=== Building gnome-sudoku ==-"
# For GTK4 apps, we often need to bundle more gsettings schemas
meson setup build --prefix=/usr -Dbuildtype=release
meson compile -C build
DESTDIR="$REPO_ROOT/$APPDIR" meson install -C build
cd "$REPO_ROOT"

############################################
# 4. Packaging with linuxdeploy
############################################
echo "=== Packaging AppImage ==-"

TOOLS=(
    "linuxdeploy-x86_64.AppImage"
    "appimagetool-x86_64.AppImage"
)

for tool in "${TOOLS[@]}"; do
    if [ ! -f "$tool" ]; then
        echo "Downloading $tool..."
        case $tool in
            linuxdeploy-x86_64.AppImage)
                wget -q https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage -O "$tool"
                ;;
            appimagetool-x86_64.AppImage)
                wget -q https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage -O "$tool"
                ;;
        esac
        chmod +x "$tool"
    fi
done

# Note: GTK4 linuxdeploy plugin is still experimental, 
# we might need to manually bundle some libraries if it fails.
export VERSION
./linuxdeploy-x86_64.AppImage --appdir "$APPDIR" \
    -e "$APPDIR/usr/bin/gnome-sudoku" \
    -d "$APPDIR/usr/share/applications/org.gnome.Sudoku.desktop" \
    -i "$APPDIR/usr/share/icons/hicolor/scalable/apps/org.gnome.Sudoku.svg" \
    --output appimage

echo "Done! gnome-sudoku AppImage built."
