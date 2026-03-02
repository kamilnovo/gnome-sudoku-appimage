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
PIXBUF_BINARY_DIR=$(find "$APPDIR/usr/lib" -name "gdk-pixbuf-2.0" -type d | head -n 1)
if [ -n "$PIXBUF_BINARY_DIR" ]; then
    # Find the queryloaders tool
    QUERYLOADERS=$(find "$DEPS_PREFIX/bin" -name "gdk-pixbuf-query-loaders" | head -n 1)
    if [ -n "$QUERYLOADERS" ]; then
        # We need to run it pointing to the loaders in AppDir
        # and adjust paths to be relative to the AppDir
        LOADERS_DIR=$(find "$PIXBUF_BINARY_DIR" -name "loaders" -type d | head -n 1)
        if [ -n "$LOADERS_DIR" ]; then
            ABI_DIR=$(dirname "$LOADERS_DIR")
            mkdir -p "$ABI_DIR"
            # Run queryloaders and fix paths to be relative to @executable_path/.. or similar
            # For AppImage, they should be relative to the AppRun location or absolute within AppDir
            # linuxdeploy usually handles this, but we are doing it manually to be sure.
            env LD_LIBRARY_PATH="$DEPS_PREFIX/lib:$DEPS_PREFIX/lib/x86_64-linux-gnu" "$QUERYLOADERS" "$LOADERS_DIR/"*.so > "$ABI_DIR/loaders.cache"
            # Make paths relative to the cache file
            sed -i "s#$APPDIR##g" "$ABI_DIR/loaders.cache"
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
# Note: --plugin gtk will handle many GTK specific things
./linuxdeploy-root/AppRun --appdir "$APPDIR" \
    --executable "$APPDIR/usr/bin/gnome-sudoku" \
    --desktop-file "$APPDIR/usr/share/applications/org.gnome.Sudoku.desktop" \
    --icon-file "$APPDIR/usr/share/icons/hicolor/scalable/apps/org.gnome.Sudoku.svg" \
    --plugin gtk \
    --output appimage

# Overwrite the AppRun created by linuxdeploy with our own improved version
cat > "$APPDIR/AppRun" <<'EOF'
#!/bin/bash
HERE="$(dirname "$(readlink -f "${0}")")"

export GSETTINGS_SCHEMA_DIR="$HERE/usr/share/glib-2.0/schemas"
export XDG_DATA_DIRS="$HERE/usr/share:$XDG_DATA_DIRS"
export LD_LIBRARY_PATH="$HERE/usr/lib:$HERE/usr/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH"
export GIO_MODULE_DIR="$HERE/usr/lib/gio/modules"

# Dynamically find the loaders.cache file
LOADERS_CACHE=$(find "$HERE/usr/lib" -name "loaders.cache" | head -n 1)
if [ -n "$LOADERS_CACHE" ]; then
    export GDK_PIXBUF_MODULE_FILE="$LOADERS_CACHE"
fi

# Ensure gdk-pixbuf cache is up to date if we are in a writable env, 
# but usually we just rely on the bundled one.
# If it doesn't exist, try to create it (though AppDir is usually read-only in AppImage)

exec "$HERE/usr/bin/gnome-sudoku" "$@"
EOF
chmod +x "$APPDIR/AppRun"

# Re-run linuxdeploy just to wrap the AppDir into an AppImage again with our new AppRun
# Actually, it's better to just run the AppImage creation part if we can, 
# but linuxdeploy handles it well. 
# We need to tell linuxdeploy NOT to overwrite our AppRun.
# Alternatively, we use the --custom-apprun flag if available, but linuxdeploy version varies.

# Let's just use the manual way to trigger appimagetool if needed, 
# but linuxdeploy's --output appimage is convenient.
# To avoid overwriting AppRun, we can run linuxdeploy first (done above) 
# and then overwrite AppRun and run appimagetool.

if [ ! -f appimagetool ]; then
    wget -q https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage -O appimagetool
    chmod +x appimagetool
fi
./appimagetool --appimage-extract
mv squashfs-root appimagetool-root

./appimagetool-root/AppRun "$APPDIR" gnome-sudoku-x86_64.AppImage

echo "AppImage created."
