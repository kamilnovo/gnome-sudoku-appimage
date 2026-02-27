#!/bin/bash
set -e

# Setup paths
export REPO_ROOT="$PWD"
export DEPS_PREFIX="$REPO_ROOT/deps-dist"
# Force our prefix to be FIRST in all paths
export PATH="$DEPS_PREFIX/bin:$REPO_ROOT/venv_build/bin:$PATH"
export PKG_CONFIG_PATH="$DEPS_PREFIX/lib/x86_64-linux-gnu/pkgconfig:$DEPS_PREFIX/lib/pkgconfig:$DEPS_PREFIX/share/pkgconfig:$PKG_CONFIG_PATH"
export LD_LIBRARY_PATH="$DEPS_PREFIX/lib/x86_64-linux-gnu:$DEPS_PREFIX/lib:$LD_LIBRARY_PATH"
# blueprint-compiler needs its modules in PYTHONPATH
export PYTHONPATH="$DEPS_PREFIX/lib/python3/dist-packages:$DEPS_PREFIX/lib/x86_64-linux-gnu/gobject-introspection:$PYTHONPATH"
# Ensure valac is found
export VALAC="/usr/bin/valac"
export VAPIGEN="/usr/bin/vapigen"

mkdir -p "$DEPS_PREFIX/bin"

# Use absolute paths for Meson
MESON="$REPO_ROOT/venv_build/bin/meson"

# Create a mock msgfmt if missing
if ! which msgfmt > /dev/null; then
    echo "#!/bin/bash" > "$DEPS_PREFIX/bin/msgfmt"
    echo "exit 0" >> "$DEPS_PREFIX/bin/msgfmt"
    chmod +x "$DEPS_PREFIX/bin/msgfmt"
fi

safe_extract() {
    local tarball=$1
    local dir=$2
    if [ ! -d "$dir" ]; then
        echo "Extracting $tarball to $dir..."
        mkdir -p "$dir"
        tar -xf "$tarball" -C "$dir" --strip-components=1 || tar -xf "$tarball" -C "$dir"
        return 0 # New extraction
    fi
    return 0 # Already extracted
}

build_component() {
    local name=$1
    local src_dir=$2
    local extra_args=$3
    local check_file=$4
    local min_version=$5
    
    # Check if we should rebuild
    local rebuild=false
    if [[ "$extra_args" == *"-Dvapi=true"* ]] || [[ "$extra_args" == *"-Dvapi=enabled"* ]]; then
        local vapi_name=$(echo $name | tr '[:upper:]' '[:lower:]')
        # Check specific vapi files
        if [[ "$name" == "GTK4" ]] && [ ! -f "$DEPS_PREFIX/share/vala/vapi/gtk4.vapi" ]; then rebuild=true; fi
        if [[ "$name" == "Libadwaita" ]] && [ ! -f "$DEPS_PREFIX/share/vala/vapi/libadwaita-1.vapi" ]; then rebuild=true; fi
        if [[ "$name" == "AppStream" ]] && [ ! -f "$DEPS_PREFIX/share/vala/vapi/appstream.vapi" ]; then rebuild=true; fi
    fi

    if [ "$rebuild" = "false" ] && [ -n "$check_file" ] && [ -f "$DEPS_PREFIX/$check_file" ]; then
        if [ -z "$min_version" ]; then
            echo "=== $name already built, skipping ==="
            return 0
        fi
        local pkg_name=$(basename ${check_file%.pc})
        local current_version=$(PKG_CONFIG_PATH="$DEPS_PREFIX/lib/x86_64-linux-gnu/pkgconfig:$DEPS_PREFIX/lib/pkgconfig" pkg-config --modversion $pkg_name 2>/dev/null || echo "0")
        if [ "$(printf '%s\n' "$min_version" "$current_version" | sort -V | head -n1)" = "$min_version" ]; then
             echo "=== $name version $current_version >= $min_version, skipping ==="
             return 0
        fi
    fi

    echo "=== Building $name ==="
    
    local actual_src=""
    if [ -f "$REPO_ROOT/$src_dir/meson.build" ]; then
        actual_src="$REPO_ROOT/$src_dir"
    else
        # Robustly find project root meson.build
        actual_src=$(find "$REPO_ROOT/$src_dir" -maxdepth 2 -name meson.build -exec grep -l "project(" {} + | head -n 1 | xargs dirname || true)
    fi

    if [ -z "$actual_src" ] || [ ! -f "$actual_src/meson.build" ]; then
        echo "Error: Could not find root meson.build in $src_dir"
        exit 1
    fi
    
    actual_src=$(realpath "$actual_src")
    local build_dir="$actual_src/build"
    
    rm -rf "$build_dir"
    "$MESON" setup "$build_dir" "$actual_src" --prefix="$DEPS_PREFIX" -Dbuildtype=release $extra_args
    
    "$MESON" compile -C "$build_dir"
    "$MESON" install -C "$build_dir"
}

# 0.0 Gettext
if [ ! -f "$DEPS_PREFIX/bin/msgfmt" ] || [ ! -f "$DEPS_PREFIX/bin/msgmerge" ]; then
    if [ ! -d "gettext-src" ]; then
        wget -q https://ftp.gnu.org/pub/gnu/gettext/gettext-0.22.5.tar.gz -O gettext.tar.gz
        safe_extract gettext.tar.gz gettext-src
    fi
    cd "$REPO_ROOT/gettext-src"
    ./configure --prefix="$DEPS_PREFIX" --disable-static
    make -j$(nproc)
    make install
    cd "$REPO_ROOT"
fi

# 0.1 Flex & Bison
if [ ! -f "$DEPS_PREFIX/bin/flex" ]; then
    if [ ! -d "flex-src" ]; then
        wget -q https://github.com/westes/flex/releases/download/v2.6.4/flex-2.6.4.tar.gz -O flex.tar.gz
        safe_extract flex.tar.gz flex-src
    fi
    cd "$REPO_ROOT/flex-src"
    [ -f configure ] || ./autogen.sh
    ./configure --prefix="$DEPS_PREFIX"
    make -j$(nproc)
    make install
    cd "$REPO_ROOT"
fi

if [ ! -f "$DEPS_PREFIX/bin/bison" ]; then
    if [ ! -d "bison-src" ]; then
        wget -q https://ftp.gnu.org/pub/gnu/bison/bison-3.8.2.tar.xz -O bison.tar.xz
        safe_extract bison.tar.xz bison-src
    fi
    cd "$REPO_ROOT/bison-src"
    ./configure --prefix="$DEPS_PREFIX"
    make -j$(nproc)
    make install
    cd "$REPO_ROOT"
fi

# 0.2 GObject-Introspection 1.80.1
if [ ! -d "gi-src" ]; then
    wget -q https://download.gnome.org/sources/gobject-introspection/1.80/gobject-introspection-1.80.1.tar.xz -O gi.tar.xz
    safe_extract gi.tar.xz gi-src
fi
build_component "GObject-Introspection" "gi-src" "-Dbuild_introspection_data=false" "lib/x86_64-linux-gnu/pkgconfig/gobject-introspection-1.0.pc" "1.80.1"

# 1. GLib 2.84.0
if [ ! -d "glib-2.84-src" ]; then
    wget -q https://download.gnome.org/sources/glib/2.84/glib-2.84.0.tar.xz -O glib-2.84.tar.xz
    safe_extract glib-2.84.tar.xz glib-2.84-src
fi
build_component "GLib" "glib-2.84-src" "-Dtests=false -Dintrospection=enabled" "lib/x86_64-linux-gnu/pkgconfig/glib-2.0.pc" "2.84.0"

# 1.1 PyGObject 3.50.0
if [ ! -d "pygobject-src" ]; then
    wget -q https://download.gnome.org/sources/pygobject/3.50/pygobject-3.50.0.tar.xz -O pygobject.tar.xz
    safe_extract pygobject.tar.xz pygobject-src
fi
build_component "PyGObject" "pygobject-src" "-Dtests=false" "lib/x86_64-linux-gnu/pkgconfig/pygobject-3.0.pc" "3.50.0"

# 2. Libdrm
if [ ! -d "libdrm-src" ]; then
    wget -q https://dri.freedesktop.org/libdrm/libdrm-2.4.124.tar.xz -O libdrm.tar.xz
fi
safe_extract libdrm.tar.xz libdrm-src
build_component "Libdrm" "libdrm-src" "-Dtests=false" "lib/x86_64-linux-gnu/pkgconfig/libdrm.pc"

# 3. Wayland
if [ ! -d "wayland-src" ]; then
    wget -q https://gitlab.freedesktop.org/wayland/wayland/-/archive/1.23.0/wayland-1.23.0.tar.gz -O wayland.tar.gz
fi
safe_extract wayland.tar.gz wayland-src
build_component "Wayland" "wayland-src" "-Dtests=false -Ddocumentation=false" "lib/x86_64-linux-gnu/pkgconfig/wayland-client.pc"

# 4. Wayland-Protocols
if [ ! -d "wayland-protocols-src" ]; then
    wget -q https://gitlab.freedesktop.org/wayland/wayland-protocols/-/archive/1.41/wayland-protocols-1.41.tar.gz -O wayland-protocols.tar.gz
fi
safe_extract wayland-protocols.tar.gz wayland-protocols-src
build_component "Wayland-Protocols" "wayland-protocols-src" "" "share/pkgconfig/wayland-protocols.pc"

# 5. Cairo
if [ ! -d "cairo-src" ]; then
    wget -q https://www.cairographics.org/releases/cairo-1.18.2.tar.xz -O cairo.tar.xz
fi
safe_extract cairo.tar.xz cairo-src
build_component "Cairo" "cairo-src" "-Dtests=disabled" "lib/x86_64-linux-gnu/pkgconfig/cairo.pc" "1.18.2"

# 6. Graphene
if [ ! -d "graphene-src" ]; then
    wget -q https://download.gnome.org/sources/graphene/1.10/graphene-1.10.8.tar.xz -O graphene.tar.xz
fi
safe_extract graphene.tar.xz graphene-src
build_component "Graphene" "graphene-src" "-Dintrospection=disabled -Dtests=false" "lib/x86_64-linux-gnu/pkgconfig/graphene-gobject-1.0.pc"

# 7. Pango 1.56.1
if [ ! -d "pango-1.56-src" ]; then
    wget -q https://download.gnome.org/sources/pango/1.56/pango-1.56.1.tar.xz -O pango-1.56.tar.xz
    safe_extract pango-1.56.tar.xz pango-1.56-src
fi
build_component "Pango" "pango-1.56-src" "-Dintrospection=enabled -Dfontconfig=enabled" "lib/x86_64-linux-gnu/pkgconfig/pango.pc" "1.56.1"

# 8. Blueprint Compiler
if [ ! -d "blueprint-src" ]; then
    wget -q "https://gitlab.gnome.org/jwestman/blueprint-compiler/-/archive/v0.16.0/blueprint-compiler-v0.16.0.tar.gz" -O blueprint.tar.gz
fi
safe_extract blueprint.tar.gz blueprint-src
build_component "Blueprint" "blueprint-src" "" "bin/blueprint-compiler"

# 9. Gperf
if [ ! -d "gperf-src" ]; then
    wget -q https://ftp.gnu.org/pub/gnu/gperf/gperf-3.1.tar.gz -O gperf.tar.gz
fi
safe_extract gperf.tar.gz gperf-src
if [ ! -f "$DEPS_PREFIX/bin/gperf" ]; then
    cd "$REPO_ROOT/gperf-src"
    ./configure --prefix="$DEPS_PREFIX"
    make -j$(nproc)
    make install
    cd "$REPO_ROOT"
fi

# 10. Libxmlb
if [ ! -d "xmlb-src" ]; then
    wget -q https://github.com/hughsie/libxmlb/releases/download/0.3.25/libxmlb-0.3.25.tar.xz -O xmlb.tar.xz
fi
safe_extract xmlb.tar.xz xmlb-src
build_component "Libxmlb" "xmlb-src" "-Dtests=false -Dintrospection=false -Dgtkdoc=false" "lib/x86_64-linux-gnu/pkgconfig/xmlb.pc"

# 11. Libyaml
if [ ! -d "yaml-src" ]; then
    wget -q https://github.com/yaml/libyaml/releases/download/0.2.5/yaml-0.2.5.tar.gz -O yaml.tar.gz
fi
safe_extract yaml.tar.gz yaml-src
if [ ! -f "$DEPS_PREFIX/lib/libyaml.so" ]; then
    cd "$REPO_ROOT/yaml-src"
    [ -f configure ] || autoreconf -fiv || true
    ./configure --prefix="$DEPS_PREFIX" --disable-static
    make -j$(nproc)
    make install
    cd "$REPO_ROOT"
fi

# 12. AppStream
if [ ! -d "appstream-src" ]; then
    wget -q https://www.freedesktop.org/software/appstream/releases/AppStream-1.0.4.tar.xz -O appstream.tar.xz
fi
safe_extract appstream.tar.xz appstream-src
if [ ! -f "$DEPS_PREFIX/share/vala/vapi/appstream.vapi" ]; then
    actual_src=$(find "$REPO_ROOT/appstream-src" -maxdepth 2 -name meson.build -exec grep -l "project(" {} + | head -n 1 | xargs dirname)
    sed -i "s/dependency('libcurl'/dependency('libcurl', required: false/" "$actual_src/meson.build" || true
    sed -i "s/dependency('libsystemd')/dependency('libsystemd', required: false)/" "$actual_src/meson.build" || true
    echo "subdir_done()" > "$actual_src/po/meson.build"
    echo "subdir_done()" > "$actual_src/docs/meson.build"
    echo "i18n_result = []" > "$actual_src/data/meson.build"
    find "$actual_src" -name meson.build -exec sed -i "s/i18n_result/[] # /g" {} +
    cat <<EOF > "$actual_src/src/as-curl.c"
#include <glib.h>
typedef struct _AsCurl AsCurl;
void as_curl_init (void);
void as_curl_init (void) {}
AsCurl* as_curl_new (GError **error);
AsCurl* as_curl_new (GError **error) { return NULL; }
gboolean as_curl_is_url (const gchar *url);
gboolean as_curl_is_url (const gchar *url) { return FALSE; }
gboolean as_curl_check_url_exists (AsCurl *acurl, const gchar *url, GError **error);
gboolean as_curl_check_url_exists (AsCurl *acurl, const gchar *url, GError **error) { return FALSE; }
GBytes* as_curl_download_bytes (AsCurl *acurl, const gchar *url, GError **error);
GBytes* as_curl_download_bytes (AsCurl *acurl, const gchar *url, GError **error) { return NULL; }
EOF
fi
build_component "AppStream" "appstream-src" "-Dqt=false -Dvapi=true -Dgir=true -Dinstall-docs=false -Dstemming=false -Dsystemd=false -Ddocs=false" "lib/x86_64-linux-gnu/pkgconfig/appstream.pc"

# 13. GTK4
if [ ! -d "gtk-src" ]; then
    wget -q https://download.gnome.org/sources/gtk/4.18/gtk-4.18.1.tar.xz -O gtk.tar.xz
fi
safe_extract gtk.tar.xz gtk-src
build_component "GTK4" "gtk-src" "-Dmedia-gstreamer=disabled -Dprint-cups=disabled -Dintrospection=enabled -Dbuild-demos=false -Dbuild-tests=false -Dbuild-examples=false -Ddocumentation=false -Dvulkan=disabled -Dx11-backend=true -Dwayland-backend=true -Dvapi=true" "lib/x86_64-linux-gnu/pkgconfig/gtk4.pc" "4.18.1"

# 14. Libadwaita
if [ ! -d "adwaita-src" ]; then
    wget -q https://download.gnome.org/sources/libadwaita/1.7/libadwaita-1.7.0.tar.xz -O adwaita.tar.xz
fi
safe_extract adwaita.tar.xz adwaita-src
if [ ! -f "$DEPS_PREFIX/share/vala/vapi/libadwaita-1.vapi" ]; then
    actual_src=$(find "$REPO_ROOT/adwaita-src" -maxdepth 2 -name meson.build -exec grep -l "project(" {} + | head -n 1 | xargs dirname)
    # Patch adwaita
    perl -0777 -pi -e "s/appstream_dep = dependency\('appstream',.*?\) /appstream_dep = dependency('appstream', required: false) # /gs" "$actual_src/src/meson.build"
    sed -i "s/gtk_dep = dependency('gtk4', version: gtk_min_version)/gtk_dep = dependency('gtk4', required: true)/" "$actual_src/src/meson.build"
    sed -i "s/'--doc-format=gi-docgen',//g" "$actual_src/src/meson.build"
    # Stub PO
    sed -i "s/subdir('po')/# subdir('po')/" "$actual_src/meson.build"
    rm -f "$actual_src/subprojects/gtk.wrap"
    rm -f "$actual_src/subprojects/appstream.wrap"
fi
build_component "Libadwaita" "adwaita-src" "-Dintrospection=enabled -Dtests=false -Dexamples=false -Dvapi=true" "lib/x86_64-linux-gnu/pkgconfig/libadwaita-1.pc"

echo "All dependencies built in $DEPS_PREFIX"
