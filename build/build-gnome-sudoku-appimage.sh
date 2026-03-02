#!/bin/bash
set -e

# Configuration
VERSION="47.1.1"
REPO_ROOT="$(pwd)"
PROJECT_DIR="$REPO_ROOT/sudoku-source-$VERSION"
DEPS_PREFIX="$REPO_ROOT/deps-dist"
APPDIR="$REPO_ROOT/AppDir"

# Export paths - ensure our custom build is FIRST
export PATH="$DEPS_PREFIX/bin:$REPO_ROOT/venv_build/bin:$PATH"
export PKG_CONFIG_PATH="$DEPS_PREFIX/lib/x86_64-linux-gnu/pkgconfig:$DEPS_PREFIX/lib/pkgconfig:$DEPS_PREFIX/share/pkgconfig:$PKG_CONFIG_PATH"
export LD_LIBRARY_PATH="$DEPS_PREFIX/lib/x86_64-linux-gnu:$DEPS_PREFIX/lib:$LD_LIBRARY_PATH"
export XDG_DATA_DIRS="$DEPS_PREFIX/share:$XDG_DATA_DIRS"

# Ensure valac finds our custom built VAPIs
export VALAFLAGS="--vapidir=$DEPS_PREFIX/share/vala/vapi --pkg=pangocairo"

echo "=== Ensuring GNOME Sudoku $VERSION source is present ==="
if [ ! -d "$PROJECT_DIR" ]; then
    wget -q https://download.gnome.org/sources/gnome-sudoku/47/gnome-sudoku-$VERSION.tar.xz
    tar -xJf gnome-sudoku-$VERSION.tar.xz
    mv gnome-sudoku-$VERSION "$PROJECT_DIR"
    rm gnome-sudoku-$VERSION.tar.xz
fi

echo "=== Building GNOME Sudoku $VERSION ==="
cd "$PROJECT_DIR"

# Use our blueprint-compiler wrapper (optional for version 47.1.1)
# Find which meson.build contains blueprint-compiler
PATCH_FILE=$(grep -l "blueprint-compiler" $(find . -name "meson.build") | head -n 1)
if [ -n "$PATCH_FILE" ]; then
    echo "Patching $PATCH_FILE..."
    sed -i "s#find_program(['\"]blueprint-compiler['\"].*)#find_program('$REPO_ROOT/blueprint-wrapper.sh')#" "$PATCH_FILE"
    if ! grep -q "blueprint-wrapper.sh" "$PATCH_FILE"; then
        echo "Failed to patch $PATCH_FILE. Content near blueprint-compiler:"
        grep -C 5 "blueprint-compiler" "$PATCH_FILE"
        exit 1
    fi
else
    echo "blueprint-compiler not found in any meson.build files. Skipping patch (expected for v47.1.1)."
fi

rm -rf build
meson setup build --prefix=/usr --buildtype=release
meson compile -C build
DESTDIR="$APPDIR" meson install -C build

echo "=== Creating AppImage ==="
cd "$REPO_ROOT"

# Create basic AppDir structure
mkdir -p "$APPDIR/usr/bin"
mkdir -p "$APPDIR/usr/lib"

# Copy our custom built dependencies into AppDir - this is critical for MX Linux compatibility
echo "=== Bundling dependencies into AppDir ==="
mkdir -p "$APPDIR/usr/lib"
mkdir -p "$APPDIR/usr/share"

# Copy all .so files from DEPS_PREFIX
find "$DEPS_PREFIX/lib" -name "*.so*" -not -path "*/pkgconfig/*" -exec cp -P {} "$APPDIR/usr/lib/" \; 2>/dev/null || true

# Copy share directory (icons, schemas, etc.)
cp -r "$DEPS_PREFIX/share/"* "$APPDIR/usr/share/" 2>/dev/null || true

# Copy GdkPixbuf loaders and GIO modules if they exist
for mod_dir in "$DEPS_PREFIX/lib/x86_64-linux-gnu/gdk-pixbuf-2.0" "$DEPS_PREFIX/lib/gdk-pixbuf-2.0"; do
    if [ -d "$mod_dir" ] && [ -n "$(ls -A "$mod_dir" 2>/dev/null)" ]; then
        mkdir -p "$APPDIR/usr/lib/gdk-pixbuf-2.0"
        cp -r "$mod_dir/"* "$APPDIR/usr/lib/gdk-pixbuf-2.0/"
        break
    fi
done

for mod_dir in "$DEPS_PREFIX/lib/x86_64-linux-gnu/gio/modules" "$DEPS_PREFIX/lib/gio/modules"; do
    if [ -d "$mod_dir" ] && [ -n "$(ls -A "$mod_dir" 2>/dev/null)" ]; then
        mkdir -p "$APPDIR/usr/lib/gio/modules"
        cp -r "$mod_dir/"* "$APPDIR/usr/lib/gio/modules/"
        break
    fi
done

# Generate GdkPixbuf loaders cache
echo "Generating GdkPixbuf loaders cache..."
# First, try to find and copy the system SVG loader if it exists
SYSTEM_SVG_LOADER=$(find /usr/lib -name "libpixbufloader-svg.so" | head -n 1)
if [ -z "$SYSTEM_SVG_LOADER" ]; then
    SYSTEM_SVG_LOADER=$(find /usr/lib/x86_64-linux-gnu -name "libpixbufloader-svg.so" | head -n 1)
fi

if [ -n "$SYSTEM_SVG_LOADER" ]; then
    LOADERS_DEST=$(find "$APPDIR/usr/lib" -name "loaders" -type d | head -n 1)
    if [ -n "$LOADERS_DEST" ]; then
        echo "Copying system SVG loader from $SYSTEM_SVG_LOADER to $LOADERS_DEST"
        cp "$SYSTEM_SVG_LOADER" "$LOADERS_DEST/"
        # Also bundle the main librsvg library
        LIBRSVG_LIB=$(ldd "$SYSTEM_SVG_LOADER" | grep "librsvg" | awk '{print $3}')
        if [ -n "$LIBRSVG_LIB" ] && [ -f "$LIBRSVG_LIB" ]; then
            echo "Bundling main librsvg from $LIBRSVG_LIB"
            cp -L "$LIBRSVG_LIB" "$APPDIR/usr/lib/"
        fi
    fi
fi

PIXBUF_BINARY_DIR=$(find "$APPDIR/usr/lib" -name "gdk-pixbuf-2.0" -type d | head -n 1)
if [ -n "$PIXBUF_BINARY_DIR" ]; then
    # Find the queryloaders tool
    QUERYLOADERS=$(find "$DEPS_PREFIX/bin" -name "gdk-pixbuf-query-loaders" | head -n 1)
    if [ -n "$QUERYLOADERS" ]; then
        LOADERS_DIR=$(find "$PIXBUF_BINARY_DIR" -name "loaders" -type d | head -n 1)
        if [ -n "$LOADERS_DIR" ]; then
            ABI_DIR=$(dirname "$LOADERS_DIR")
            mkdir -p "$ABI_DIR"
            env LD_LIBRARY_PATH="$DEPS_PREFIX/lib:$DEPS_PREFIX/lib/x86_64-linux-gnu" "$QUERYLOADERS" "$LOADERS_DIR/"*.so > "$ABI_DIR/loaders.cache"
            # Use a placeholder for runtime patching
            sed -i "s#$APPDIR#@APPDIR@#g" "$ABI_DIR/loaders.cache"
        fi
    fi
fi

# Compile GSettings schemas in the AppDir
if [ -d "$APPDIR/usr/share/glib-2.0/schemas" ]; then
    echo "Compiling GSettings schemas..."
    glib-compile-schemas "$APPDIR/usr/share/glib-2.0/schemas"
fi

# Download linuxdeploy and AppImage plugin
if [ ! -f linuxdeploy ]; then
    wget -q https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage -O linuxdeploy
    chmod +x linuxdeploy
fi
if [ ! -f linuxdeploy-plugin-appimage.AppImage ]; then
    wget -q https://github.com/linuxdeploy/linuxdeploy-plugin-appimage/releases/download/continuous/linuxdeploy-plugin-appimage-x86_64.AppImage -O linuxdeploy-plugin-appimage.AppImage
    chmod +x linuxdeploy-plugin-appimage.AppImage
fi
if [ ! -f linuxdeploy-plugin-gtk.sh ]; then
    wget -q https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/master/linuxdeploy-plugin-gtk.sh -O linuxdeploy-plugin-gtk.sh
    chmod +x linuxdeploy-plugin-gtk.sh
fi

# Extract tools to avoid FUSE dependency
rm -rf linuxdeploy-root plugin-appimage-root squashfs-root
./linuxdeploy --appimage-extract
mv squashfs-root linuxdeploy-root
./linuxdeploy-plugin-appimage.AppImage --appimage-extract
mv squashfs-root plugin-appimage-root

export APPIMAGE_EXTRACT_AND_RUN=1
export NO_STRIP=1
export STRIP="/usr/bin/strip"
export PATH="$(pwd)/plugin-appimage-root/usr/bin:$PATH"

# Bundle everything
./linuxdeploy-root/AppRun --appdir "$APPDIR" \
    --executable "$APPDIR/usr/bin/gnome-sudoku" \
    --desktop-file "$APPDIR/usr/share/applications/org.gnome.Sudoku.desktop" \
    --icon-file "$APPDIR/usr/share/icons/hicolor/scalable/apps/org.gnome.Sudoku.svg" \
    --plugin gtk

# Ensure icon is in root
cp "$APPDIR/usr/share/icons/hicolor/scalable/apps/org.gnome.Sudoku.svg" "$APPDIR/org.gnome.Sudoku.svg" 2>/dev/null || true
ln -s org.gnome.Sudoku.svg "$APPDIR/.DirIcon" 2>/dev/null || true
cp "$APPDIR/usr/share/applications/org.gnome.Sudoku.desktop" "$APPDIR/" 2>/dev/null || true

# Overwrite the AppRun created by linuxdeploy with our own improved version
cat > "$APPDIR/AppRun" <<'EOF'
#!/bin/bash
HERE="$(dirname "$(readlink -f "${0}")")"

# Create a temporary directory for patched config files
CONF_TMP=$(mktemp -d)
trap "rm -rf $CONF_TMP" EXIT

# Patch loaders.cache at runtime
LOADERS_CACHE_TPL=$(find "$HERE/usr/lib" -name "loaders.cache" | head -n 1)
if [ -n "$LOADERS_CACHE_TPL" ]; then
    sed "s#@APPDIR@#$HERE#g" "$LOADERS_CACHE_TPL" > "$CONF_TMP/loaders.cache"
    export GDK_PIXBUF_MODULE_FILE="$CONF_TMP/loaders.cache"
fi

export GSETTINGS_SCHEMA_DIR="$HERE/usr/share/glib-2.0/schemas"
export XDG_DATA_DIRS="$HERE/usr/share:$XDG_DATA_DIRS"
export LD_LIBRARY_PATH="$HERE/usr/lib:$HERE/usr/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH"
export GIO_MODULE_DIR="$HERE/usr/lib/gio/modules"
export ADW_DEBUG_COLOR_SCHEME=prefer-dark
export GTK_THEME=Adwaita:dark

exec "$HERE/usr/bin/gnome-sudoku" "$@"
EOF
chmod +x "$APPDIR/AppRun"

if [ ! -f appimagetool ]; then
    wget -q https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage -O appimagetool
    chmod +x appimagetool
fi
./appimagetool --appimage-extract
mv squashfs-root appimagetool-root

rm -f *.AppImage
./appimagetool-root/AppRun "$APPDIR" GNOME_Sudoku-x86_64.AppImage

echo "AppImage created: GNOME_Sudoku-x86_64.AppImage"
