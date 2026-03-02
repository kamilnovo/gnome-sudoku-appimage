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

echo "=== Patching source for compatibility with older valac ==="
cd "$PROJECT_DIR"
# 1. Replace dispose_template (GTK 4.8+)
sed -i 's/dispose_template/ \/\/ dispose_template/g' src/window.vala src/preferences-dialog.vala
# 2. Replace NO_MODIFIER_MASK (GDK 4.14+)
sed -i 's/Gdk.ModifierType.NO_MODIFIER_MASK/0/g' src/window.vala
# 3. Replace DEFAULT_FLAGS (GLib 2.74+)
sed -i 's/ApplicationFlags.DEFAULT_FLAGS/ApplicationFlags.FLAGS_NONE/g' src/gnome-sudoku.vala
# 4. Replace MenuButton.active (GTK 4.10+)
sed -i 's/main_menu.active/main_menu.get_popover().visible/g' src/window.vala
sed -i 's/main_menu.notify\["active"\]/main_menu.get_popover().notify["visible"]/g' src/window.vala

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

# Copy fontconfig configuration
mkdir -p "$APPDIR/etc/fonts"
cp -r "$DEPS_PREFIX/etc/fonts/"* "$APPDIR/etc/fonts/" 2>/dev/null || true

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
# This is a hack to avoid building librsvg from source (which is huge/Rust)
SYSTEM_SVG_LOADER=$(find /usr/lib -name "libpixbufloader-svg.so" | head -n 1)
if [ -z "$SYSTEM_SVG_LOADER" ]; then
    SYSTEM_SVG_LOADER=$(find /usr/lib/x86_64-linux-gnu -name "libpixbufloader-svg.so" | head -n 1)
fi

if [ -n "$SYSTEM_SVG_LOADER" ]; then
    LOADERS_DEST=$(find "$APPDIR/usr/lib" -name "loaders" -type d | head -n 1)
    if [ -n "$LOADERS_DEST" ]; then
        echo "Copying system SVG loader from $SYSTEM_SVG_LOADER to $LOADERS_DEST"
        cp "$SYSTEM_SVG_LOADER" "$LOADERS_DEST/"
    else
        echo "Could not find loaders destination directory in $APPDIR/usr/lib"
    fi
else
    echo "WARNING: Could not find system SVG loader (libpixbufloader-svg.so). SVGs will not render!"
fi

# List loaders for debugging
if [ -d "$LOADERS_DEST" ]; then
    echo "Loaders in $LOADERS_DEST:"
    ls "$LOADERS_DEST"
fi

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
            # Use a placeholder for the AppDir path
            sed -i "s#$APPDIR#@APPDIR@#g" "$ABI_DIR/loaders.cache"
        fi
    fi
fi

# Patch bundled fonts.conf to use our bundled fonts and config
if [ -f "$APPDIR/etc/fonts/fonts.conf" ]; then
    echo "Patching fonts.conf..."
    # Remove system paths and use relative ones or environment variables
    # This is a bit complex, but we can at least try to make it look in the AppDir
    sed -i "s#$DEPS_PREFIX#@APPDIR@/usr#g" "$APPDIR/etc/fonts/fonts.conf"
    sed -i 's#<dir>/usr/share/fonts</dir>#<dir>@APPDIR@/usr/share/fonts</dir>#' "$APPDIR/etc/fonts/fonts.conf"
fi

# Also bundle the main librsvg library if we found the loader
if [ -n "$SYSTEM_SVG_LOADER" ]; then
    LIBRSVG_LIB=$(ldd "$SYSTEM_SVG_LOADER" | grep "librsvg" | awk '{print $3}')
    if [ -n "$LIBRSVG_LIB" ] && [ -f "$LIBRSVG_LIB" ]; then
        echo "Bundling main librsvg from $LIBRSVG_LIB"
        cp -L "$LIBRSVG_LIB" "$APPDIR/usr/lib/"
    fi
fi

# Compile GSettings schemas in the AppDir
if [ -d "$APPDIR/usr/share/glib-2.0/schemas" ]; then
    echo "Compiling GSettings schemas..."
    COMPILE_SCHEMAS=$(find "$DEPS_PREFIX/bin" -name "glib-compile-schemas" | head -n 1)
    if [ -z "$COMPILE_SCHEMAS" ]; then COMPILE_SCHEMAS="glib-compile-schemas"; fi
    env LD_LIBRARY_PATH="$DEPS_PREFIX/lib:$DEPS_PREFIX/lib/x86_64-linux-gnu" "$COMPILE_SCHEMAS" "$APPDIR/usr/share/glib-2.0/schemas"
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
# We run linuxdeploy to prepare the AppDir, but we'll wrap it ourselves to control AppRun
./linuxdeploy-root/AppRun --appdir "$APPDIR" \
    --executable "$APPDIR/usr/bin/gnome-sudoku" \
    --desktop-file "$APPDIR/usr/share/applications/org.gnome.Sudoku.desktop" \
    --icon-file "$APPDIR/usr/share/icons/hicolor/scalable/apps/org.gnome.Sudoku.svg" \
    --plugin gtk

# Update icon cache
# Use the bundled tool if available, otherwise system
UPDATE_ICON_CACHE=$(find "$DEPS_PREFIX/bin" -name "gtk4-update-icon-cache" | head -n 1)
if [ -z "$UPDATE_ICON_CACHE" ]; then
    UPDATE_ICON_CACHE="gtk-update-icon-cache"
fi

for icon_dir in "$APPDIR/usr/share/icons/hicolor" "$APPDIR/usr/share/icons/Adwaita"; do
    if [ -d "$icon_dir" ]; then
        echo "Updating icon cache for $icon_dir..."
        env LD_LIBRARY_PATH="$DEPS_PREFIX/lib:$DEPS_PREFIX/lib/x86_64-linux-gnu" "$UPDATE_ICON_CACHE" -f -t "$icon_dir" || true
    fi
done

# Ensure the icon is in the root of AppDir (appimagetool looks for it there)
# GNOME Sudoku uses org.gnome.Sudoku.svg
cp "$APPDIR/usr/share/icons/hicolor/scalable/apps/org.gnome.Sudoku.svg" "$APPDIR/org.gnome.Sudoku.svg" 2>/dev/null || true
ln -s org.gnome.Sudoku.svg "$APPDIR/.DirIcon" 2>/dev/null || true

# Copy desktop file to root
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
    export GDK_PIXBUF_MODULEDIR="$(dirname "$LOADERS_CACHE_TPL")"
fi

# Patch fonts.conf at runtime
if [ -f "$HERE/etc/fonts/fonts.conf" ]; then
    sed "s#@APPDIR@#$HERE#g" "$HERE/etc/fonts/fonts.conf" > "$CONF_TMP/fonts.conf"
    export FONTCONFIG_FILE="$CONF_TMP/fonts.conf"
    export FONTCONFIG_PATH="$HERE/etc/fonts"
fi

export GSETTINGS_SCHEMA_DIR="$HERE/usr/share/glib-2.0/schemas"
export XDG_DATA_DIRS="$HERE/usr/share:$XDG_DATA_DIRS"
export LD_LIBRARY_PATH="$HERE/usr/lib:$HERE/usr/lib/x86_64-linux-gnu:$HERE/lib:$HERE/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH"
export GIO_MODULE_DIR="$HERE/usr/lib/gio/modules"
export XCURSOR_PATH="$HERE/usr/share/icons:$XCURSOR_PATH"
export ADW_DEBUG_COLOR_SCHEME=prefer-dark
export GTK_THEME=Adwaita:dark

# Set GIO_EXTRA_MODULES to point to our bundled modules
export GIO_EXTRA_MODULES="$HERE/usr/lib/gio/modules"

# Ensure icon theme is picked up and hicolor is first
export XDG_DATA_DIRS="$HERE/usr/share:$XDG_DATA_DIRS"

exec "$HERE/usr/bin/gnome-sudoku" "$@"
EOF
chmod +x "$APPDIR/AppRun"

if [ ! -f appimagetool ]; then
    wget -q https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage -O appimagetool
    chmod +x appimagetool
fi
./appimagetool --appimage-extract
mv squashfs-root appimagetool-root

# Remove any existing AppImages in the root to avoid confusion
rm -f *.AppImage

./appimagetool-root/AppRun "$APPDIR" GNOME_Sudoku-x86_64.AppImage

echo "AppImage created: GNOME_Sudoku-x86_64.AppImage"
