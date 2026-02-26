#!/bin/bash
set -e
export APPIMAGE_EXTRACT_AND_RUN=1
VERSION="49.4"
APPDIR="AppDir"

cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"
rm -rf "$APPDIR"
mkdir -p "$APPDIR"

# 1. Install Flatpak
echo "=== Installing Flatpak tools ==-"
apt-get update
apt-get install -y flatpak

# 2. Add Flathub and fetch Sudoku + Runtime
echo "=== Fetching Sudoku from Flathub ==-"
flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install --user -y flathub org.gnome.Sudoku//stable

# 3. Extract Flatpak to AppDir
echo "=== Extracting Flatpak to AppDir ==-"
FLATPAK_DIR="$HOME/.local/share/flatpak/app/org.gnome.Sudoku/x86_64/stable/active/files"
RUNTIME_DIR="$HOME/.local/share/flatpak/runtime/org.gnome.Platform/x86_64/47/active/files"

# Copy App files
cp -r "$FLATPAK_DIR/"* "$APPDIR/"

# Copy Runtime libraries (This is the heavy part, but ensures compatibility)
mkdir -p "$APPDIR/usr/lib"
cp -r "$RUNTIME_DIR/lib/x86_64-linux-gnu/"* "$APPDIR/usr/lib/" || true
cp -r "$RUNTIME_DIR/lib/"* "$APPDIR/usr/lib/" || true

# Copy Schemas and Data
mkdir -p "$APPDIR/usr/share"
cp -r "$RUNTIME_DIR/share/"* "$APPDIR/usr/share/" || true

# 4. Packaging
echo "=== Packaging AppImage ==-"
wget -q https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage -O appimagetool
chmod +x appimagetool

# Create AppRun
cat << 'EOF' > "$APPDIR/AppRun"
#!/bin/sh
HERE="$(dirname "$(readlink -f "${0}")")"
export LD_LIBRARY_PATH="$HERE/usr/lib:$HERE/usr/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH"
export XDG_DATA_DIRS="$HERE/usr/share:$XDG_DATA_DIRS"
export GSETTINGS_SCHEMA_DIR="$HERE/usr/share/glib-2.0/schemas"
export GTK_THEME=Adwaita
exec "$HERE/bin/gnome-sudoku" "$@"
EOF
chmod +x "$APPDIR/AppRun"

./appimagetool "$APPDIR" Sudoku-49.4-x86_64.AppImage
echo "Done!"
