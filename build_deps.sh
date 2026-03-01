#!/bin/bash
set -e

# Setup paths
export REPO_ROOT="$PWD"
export DEPS_PREFIX="$REPO_ROOT/deps-dist"
export PATH="$DEPS_PREFIX/bin:$REPO_ROOT/venv_build/bin:$PATH"
export PKG_CONFIG_PATH="$DEPS_PREFIX/lib/x86_64-linux-gnu/pkgconfig:$DEPS_PREFIX/lib/pkgconfig:$DEPS_PREFIX/share/pkgconfig:/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig"
export LD_LIBRARY_PATH="$DEPS_PREFIX/lib/x86_64-linux-gnu:$DEPS_PREFIX/lib:$LD_LIBRARY_PATH"
export PYTHONPATH="$DEPS_PREFIX/lib/python3/dist-packages:$PYTHONPATH"

mkdir -p "$DEPS_PREFIX/bin"
MESON="$REPO_ROOT/venv_build/bin/meson"

safe_extract() {
    local tarball=$1
    local dir=$2
    echo "Extracting $tarball to $dir..."
    mkdir -p "$dir"
    tar -xf "$tarball" -C "$dir" --strip-components=1 || tar -xf "$tarball" -C "$dir"
}

build_component() {
    local name=$1
    local src_dir=$2
    local extra_args=$3
    echo "=== Building $name ==="
    local actual_src="$REPO_ROOT/$src_dir"
    cd "$actual_src"
    rm -rf build
    env PKG_CONFIG_PATH="$PKG_CONFIG_PATH" "$MESON" setup build . --prefix="$DEPS_PREFIX" -Dbuildtype=release --wrap-mode nofallback $extra_args
    "$MESON" compile -C build
    "$MESON" install -C build
    cd "$REPO_ROOT"
}

build_autotools_component() {
    local name=$1
    local src_dir=$2
    local extra_args=$3
    echo "=== Building $name (Autotools) ==="
    local actual_src="$REPO_ROOT/$src_dir"
    cd "$actual_src"
    ./configure --prefix="$DEPS_PREFIX" $extra_args
    make -j$(nproc)
    make install
    cd "$REPO_ROOT"
}

# 1. GLib
if [ ! -f "$DEPS_PREFIX/lib/x86_64-linux-gnu/pkgconfig/glib-2.0.pc" ]; then
    wget -q https://download.gnome.org/sources/glib/2.82/glib-2.82.5.tar.xz -O glib.tar.xz
    safe_extract glib.tar.xz glib-src
    build_component "GLib" "glib-src" "-Dtests=false"
fi

# 2. Pixman (for Cairo)
if [ ! -f "$DEPS_PREFIX/lib/pkgconfig/pixman-1.pc" ]; then
    wget -q https://www.cairographics.org/releases/pixman-0.42.2.tar.gz -O pixman.tar.gz
    safe_extract pixman.tar.gz pixman-src
    build_component "Pixman" "pixman-src" "-Dtests=disabled"
fi

# 2.5 Graphene (needed by GTK4)
if [ ! -f "$DEPS_PREFIX/lib/x86_64-linux-gnu/pkgconfig/graphene-gobject-1.0.pc" ]; then
    wget -q https://github.com/ebassi/graphene/archive/refs/tags/1.10.8.tar.gz -O graphene.tar.gz
    safe_extract graphene.tar.gz graphene-src
    build_component "Graphene" "graphene-src" "-Dtests=false -Dintrospection=disabled"
fi

# 2.6 FreeType
if [ ! -f "$DEPS_PREFIX/lib/pkgconfig/freetype2.pc" ]; then
    wget -q https://download.savannah.nongnu.org/releases/freetype/freetype-2.13.3.tar.xz -O freetype.tar.xz
    safe_extract freetype.tar.xz freetype-src
    build_component "FreeType" "freetype-src" "-Dzlib=enabled -Dbzip2=disabled -Dpng=disabled -Dharfbuzz=disabled"
fi

# 2.7 HarfBuzz
if [ ! -f "$DEPS_PREFIX/lib/pkgconfig/harfbuzz.pc" ]; then
    wget -q https://github.com/harfbuzz/harfbuzz/releases/download/10.1.0/harfbuzz-10.1.0.tar.xz -O harfbuzz.tar.xz
    safe_extract harfbuzz.tar.xz harfbuzz-src
    build_component "HarfBuzz" "harfbuzz-src" "-Dtests=disabled -Ddocs=disabled -Dintrospection=disabled"
fi

# 2.8 Rebuild FreeType with HarfBuzz support
echo "=== Rebuilding FreeType with HarfBuzz support ==="
cd "$REPO_ROOT/freetype-src"
rm -rf build
env PKG_CONFIG_PATH="$PKG_CONFIG_PATH" "$MESON" setup build . --prefix="$DEPS_PREFIX" -Dbuildtype=release --wrap-mode nofallback -Dharfbuzz=enabled
"$MESON" compile -C build
"$MESON" install -C build
cd "$REPO_ROOT"

# 2.9 Fontconfig
if [ ! -f "$DEPS_PREFIX/lib/pkgconfig/fontconfig.pc" ]; then
    wget -q https://www.freedesktop.org/software/fontconfig/release/fontconfig-2.15.0.tar.xz -O fontconfig.tar.xz
    safe_extract fontconfig.tar.xz fontconfig-src
    build_component "Fontconfig" "fontconfig-src" "-Ddoc=disabled -Dtests=disabled"
fi

# 3. Cairo
if [ ! -f "$DEPS_PREFIX/lib/pkgconfig/cairo.pc" ]; then
    wget -q https://www.cairographics.org/releases/cairo-1.18.2.tar.xz -O cairo.tar.xz
    safe_extract cairo.tar.xz cairo-src
    build_component "Cairo" "cairo-src" "-Dtests=disabled -Dfontconfig=enabled -Dfreetype=enabled"
fi

# 3.2 Gdk-Pixbuf
if [ ! -f "$DEPS_PREFIX/lib/x86_64-linux-gnu/pkgconfig/gdk-pixbuf-2.0.pc" ]; then
    wget -q https://download.gnome.org/sources/gdk-pixbuf/2.42/gdk-pixbuf-2.42.12.tar.xz -O gdk-pixbuf.tar.xz
    safe_extract gdk-pixbuf.tar.xz gdk-pixbuf-src
    build_component "Gdk-Pixbuf" "gdk-pixbuf-src" "-Dintrospection=disabled -Dtests=false -Dman=false"
fi

# 3.5 Pango
if [ ! -f "$DEPS_PREFIX/lib/x86_64-linux-gnu/pkgconfig/pango.pc" ]; then
    wget -q https://download.gnome.org/sources/pango/1.56/pango-1.56.1.tar.xz -O pango.tar.xz
    safe_extract pango.tar.xz pango-src
    build_component "Pango" "pango-src" "-Dintrospection=disabled"
fi

# 3.6 Wayland Protocols
if [ ! -f "$DEPS_PREFIX/share/pkgconfig/wayland-protocols.pc" ]; then
    wget -q https://gitlab.freedesktop.org/wayland/wayland-protocols/-/archive/1.40/wayland-protocols-1.40.tar.gz -O wayland-protocols.tar.gz
    safe_extract wayland-protocols.tar.gz wayland-protocols-src
    build_component "WaylandProtocols" "wayland-protocols-src" "-Dtests=false"
fi

# 4. GTK 4
if [ ! -f "$DEPS_PREFIX/lib/x86_64-linux-gnu/pkgconfig/gtk4.pc" ]; then
    wget -q https://download.gnome.org/sources/gtk/4.16/gtk-4.16.12.tar.xz -O gtk.tar.xz
    safe_extract gtk.tar.xz gtk-src
    build_component "GTK4" "gtk-src" "-Dbuild-examples=false -Dbuild-tests=false -Dintrospection=disabled -Dmedia-gstreamer=disabled -Dvulkan=disabled"
fi


# 5. Libadwaita
if [ ! -f "$DEPS_PREFIX/lib/x86_64-linux-gnu/pkgconfig/libadwaita-1.pc" ]; then
    wget -q https://download.gnome.org/sources/libadwaita/1.6/libadwaita-1.6.0.tar.xz -O adwaita.tar.xz
    safe_extract adwaita.tar.xz adwaita-src
    rm -f adwaita-src/subprojects/gtk.wrap
    build_component "Libadwaita" "adwaita-src" "-Dintrospection=enabled -Dtests=false -Dexamples=false -Dvapi=true -Dgtk_doc=false"
fi

# 5.5 Libgee
if [ ! -f "$DEPS_PREFIX/lib/pkgconfig/gee-0.8.pc" ]; then
    wget -q https://download.gnome.org/sources/libgee/0.20/libgee-0.20.8.tar.xz -O libgee.tar.xz
    safe_extract libgee.tar.xz libgee-src
    build_autotools_component "Libgee" "libgee-src" "--disable-introspection"
fi

# 5.6 Json-Glib
if [ ! -f "$DEPS_PREFIX/lib/x86_64-linux-gnu/pkgconfig/json-glib-1.0.pc" ]; then
    wget -q https://download.gnome.org/sources/json-glib/1.10/json-glib-1.10.0.tar.xz -O json-glib.tar.xz
    safe_extract json-glib.tar.xz json-glib-src
    build_component "Json-Glib" "json-glib-src" "-Dintrospection=disabled -Dtests=false -Dgtk_doc=false"
fi

# 6. Blueprint
if [ ! -f "$DEPS_PREFIX/bin/blueprint-compiler" ]; then
    wget -q https://gitlab.gnome.org/jwestman/blueprint-compiler/-/archive/v0.16.0/blueprint-compiler-v0.16.0.tar.gz -O blueprint.tar.gz
    safe_extract blueprint.tar.gz blueprint-src
    build_component "Blueprint" "blueprint-src" ""
fi

# 7. gsettings-desktop-schemas
if [ ! -f "$DEPS_PREFIX/share/pkgconfig/gsettings-desktop-schemas.pc" ]; then
    wget -q https://download.gnome.org/sources/gsettings-desktop-schemas/47/gsettings-desktop-schemas-47.0.tar.xz -O gsettings.tar.xz
    safe_extract gsettings.tar.xz gsettings-src
    build_component "GSettingsSchemas" "gsettings-src" "-Dintrospection=disabled"
fi

# 8. adwaita-icon-theme
if [ ! -d "$DEPS_PREFIX/share/icons/Adwaita" ]; then
    wget -q https://download.gnome.org/sources/adwaita-icon-theme/47/adwaita-icon-theme-47.0.tar.xz -O adwaita-icons.tar.xz
    safe_extract adwaita-icons.tar.xz adwaita-icons-src
    build_component "AdwaitaIcons" "adwaita-icons-src" ""
fi

# 9. qqwing
if [ ! -f "$DEPS_PREFIX/lib/pkgconfig/qqwing.pc" ]; then
    wget -q https://qqwing.com/qqwing-1.3.4.tar.gz -O qqwing.tar.gz
    safe_extract qqwing.tar.gz qqwing-src
    cd qqwing-src
    ./configure --prefix="$DEPS_PREFIX"
    make -j$(nproc) install
    cd "$REPO_ROOT"
fi

echo "All dependencies prepared in $DEPS_PREFIX"
