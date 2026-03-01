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

# 1. GLib
if [ ! -f "$DEPS_PREFIX/lib/x86_64-linux-gnu/pkgconfig/glib-2.0.pc" ]; then
    wget -q https://download.gnome.org/sources/glib/2.78/glib-2.78.0.tar.xz -O glib.tar.xz
    safe_extract glib.tar.xz glib-src
    build_component "GLib" "glib-src" "-Dtests=false"
fi

# 2. Pixman (for Cairo)
if [ ! -f "$DEPS_PREFIX/lib/pkgconfig/pixman-1.pc" ]; then
    wget -q https://www.cairographics.org/releases/pixman-0.42.2.tar.gz -O pixman.tar.gz
    safe_extract pixman.tar.gz pixman-src
    build_component "Pixman" "pixman-src" "-Dtests=disabled"
fi

# 3. Cairo
if [ ! -f "$DEPS_PREFIX/lib/pkgconfig/cairo.pc" ]; then
    wget -q https://www.cairographics.org/releases/cairo-1.18.2.tar.xz -O cairo.tar.xz
    safe_extract cairo.tar.xz cairo-src
    build_component "Cairo" "cairo-src" "-Dtests=disabled -Dfontconfig=enabled -Dfreetype=enabled"
fi

# 3.5 Pango
if [ ! -f "$DEPS_PREFIX/lib/x86_64-linux-gnu/pkgconfig/pango.pc" ]; then
    wget -q https://download.gnome.org/sources/pango/1.54/pango-1.54.0.tar.xz -O pango.tar.xz
    safe_extract pango.tar.xz pango-src
    build_component "Pango" "pango-src" "-Dintrospection=disabled"
fi

# 3.6 Wayland Protocols
if [ ! -f "$DEPS_PREFIX/share/pkgconfig/wayland-protocols.pc" ]; then
    wget -q https://gitlab.freedesktop.org/wayland/wayland-protocols/-/archive/1.38/wayland-protocols-1.38.tar.gz -O wayland-protocols.tar.gz
    safe_extract wayland-protocols.tar.gz wayland-protocols-src
    build_component "WaylandProtocols" "wayland-protocols-src" ""
fi

# 4. GTK 4
if [ ! -f "$DEPS_PREFIX/lib/x86_64-linux-gnu/pkgconfig/gtk4.pc" ]; then
    wget -q https://download.gnome.org/sources/gtk/4.16/gtk-4.16.12.tar.xz -O gtk.tar.xz
    safe_extract gtk.tar.xz gtk-src
    build_component "GTK4" "gtk-src" "-Dbuild-examples=false -Dbuild-tests=false -Dintrospection=disabled -Dmedia-gstreamer=disabled"
fi

# 5. Libadwaita
if [ ! -f "$DEPS_PREFIX/lib/x86_64-linux-gnu/pkgconfig/libadwaita-1.pc" ]; then
    wget -q https://download.gnome.org/sources/libadwaita/1.6/libadwaita-1.6.0.tar.xz -O adwaita.tar.xz
    safe_extract adwaita.tar.xz adwaita-src
    rm -f adwaita-src/subprojects/gtk.wrap
    build_component "Libadwaita" "adwaita-src" "-Dintrospection=enabled -Dtests=false -Dexamples=false -Dvapi=true -Dgtk_doc=false"
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
