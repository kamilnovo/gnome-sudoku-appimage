#!/bin/bash
set -e
export APPIMAGE_EXTRACT_AND_RUN=1
VERSION="49.4"
REPO_URL="https://gitlab.gnome.org/GNOME/gnome-sudoku.git"
PROJECT_DIR="gnome-sudoku-$VERSION"
APPDIR="AppDir"

cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"
rm -rf "$APPDIR" "$PROJECT_DIR" blueprint-dest
mkdir -p "$APPDIR"

# 1. Build blueprint-compiler (v0.16.0)
echo "=== Building blueprint-compiler ==-"
git clone --depth 1 --branch v0.16.0 https://gitlab.gnome.org/jwestman/blueprint-compiler.git
cd blueprint-compiler
meson setup build --prefix=/usr
DESTDIR="$REPO_ROOT/blueprint-dest" meson install -C build
export PATH="$REPO_ROOT/blueprint-dest/usr/bin:$PATH"
export PYTHONPATH="$REPO_ROOT/blueprint-dest/usr/lib/python3/dist-packages:$PYTHONPATH"
cd "$REPO_ROOT"

# 2. Fetch Sudoku source
echo "=== Fetching gnome-sudoku $VERSION ==-"
git clone --depth 1 --branch "$VERSION" "$REPO_URL" "$PROJECT_DIR"

# 3. Add Subprojects for modern dependencies
echo "=== Setting up Subprojects with Wrap files ==-"
cd "$PROJECT_DIR"
mkdir -p subprojects

# GLib
cat << EOF > subprojects/glib.wrap
[wrap-git]
url = https://gitlab.gnome.org/GNOME/glib.git
revision = 2.82.5
depth = 1

[provide]
dependency_names = glib-2.0, gobject-2.0, gio-2.0, gmodule-2.0, gio-unix-2.0
EOF

# GTK4
cat << EOF > subprojects/gtk4.wrap
[wrap-git]
url = https://gitlab.gnome.org/GNOME/gtk.git
revision = 4.16.12
depth = 1

[provide]
dependency_names = gtk4
EOF

# Libadwaita
cat << EOF > subprojects/libadwaita-1.wrap
[wrap-git]
url = https://gitlab.gnome.org/GNOME/libadwaita.git
revision = 1.6.3
depth = 1

[provide]
dependency_names = libadwaita-1
EOF

# Graphene
cat << EOF > subprojects/graphene-1.0.wrap
[wrap-git]
url = https://github.com/ebassi/graphene.git
revision = 1.10.8
depth = 1

[provide]
dependency_names = graphene-1.0, graphene-gobject-1.0
EOF

# Json-glib
cat << EOF > subprojects/json-glib-1.0.wrap
[wrap-git]
url = https://gitlab.gnome.org/GNOME/json-glib.git
revision = master
depth = 1

[provide]
dependency_names = json-glib-1.0
EOF

# Pango
cat << EOF > subprojects/pango.wrap
[wrap-git]
url = https://gitlab.gnome.org/GNOME/pango.git
revision = 1.54.0
depth = 1

[provide]
dependency_names = pango, pangocairo, pangoft2, pangowin32
EOF

# Harfbuzz
cat << EOF > subprojects/harfbuzz.wrap
[wrap-git]
url = https://github.com/harfbuzz/harfbuzz.git
revision = master
depth = 1

[provide]
dependency_names = harfbuzz, harfbuzz-gobject, harfbuzz-subset
EOF

# Fribidi
cat << EOF > subprojects/fribidi.wrap
[wrap-git]
url = https://github.com/fribidi/fribidi.git
revision = v1.0.12
depth = 1

[provide]
dependency_names = fribidi
EOF

# 4. Build Sudoku with Subprojects
echo "=== Building Sudoku + Modern Stack (This takes 20-30 mins) ==-"
# We use --wrap-mode=forcefallback to ensure all dependencies use the subprojects.
meson setup build --prefix=/usr -Dbuildtype=release \
    --wrap-mode=forcefallback \
    -Dgtk:media-gstreamer=disabled \
    -Dgtk:vulkan=disabled \
    -Dgtk:build-demos=false \
    -Dgtk:build-tests=false \
    -Dgtk:build-examples=false \
    -Dlibadwaita:tests=false \
    -Dlibadwaita:examples=false \
    -Dlibadwaita:vapi=false \
    -Dglib:tests=false \
    -Djson-glib:tests=false \
    -Djson-glib:docs=false
    
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

./appimagetool "$APPDIR" Sudoku-49.4-x86_64.AppImage
echo "Done!"
