#!/bin/bash
set -e

# Configuration
VERSION="49.4"
REPO_ROOT="$(pwd)"
PROJECT_DIR="$REPO_ROOT/sudoku-source-$VERSION"
DEPS_PREFIX="$REPO_ROOT/deps-dist"
APPDIR="$REPO_ROOT/AppDir"

# Export paths for build
export PATH="$DEPS_PREFIX/bin:$REPO_ROOT/venv_build/bin:$PATH"
export PKG_CONFIG_PATH="$DEPS_PREFIX/lib/x86_64-linux-gnu/pkgconfig:$DEPS_PREFIX/lib/pkgconfig:$DEPS_PREFIX/share/pkgconfig:$PKG_CONFIG_PATH"
export LD_LIBRARY_PATH="$DEPS_PREFIX/lib/x86_64-linux-gnu:$DEPS_PREFIX/lib:$LD_LIBRARY_PATH"
# Needed for blueprint-compiler during Sudoku build
export PYTHONPATH="$DEPS_PREFIX/lib/python3/dist-packages:$PYTHONPATH"
# Needed for GI modules to find their typelibs
export GI_TYPELIB_PATH="$DEPS_PREFIX/lib/x86_64-linux-gnu/girepository-1.0:$DEPS_PREFIX/lib/girepository-1.0"

echo "=== Building GNOME Sudoku $VERSION ==="

cd "$PROJECT_DIR"

# Restore files first to have a clean state for patches
git checkout meson.build data/meson.build src/meson.build || true

# Patch: remove blueprint-compiler version check AND use our wrapper directly
sed -i "s|blueprintc = find_program('blueprint-compiler', version: '>= 0.16')|blueprintc = find_program('$REPO_ROOT/blueprint-wrapper.sh')|" meson.build || true

# Manual data/meson.build fix
cat <<EOF > data/meson.build
desktop_conf = configuration_data()
desktop_conf.set('icon', app_id)
desktop_file_intermediate = configure_file(
  input: '@0@.desktop.in.in'.format(base_id),
  output: '@0@.desktop.intermediate'.format(base_id),
  configuration: desktop_conf
)
desktop_file = configure_file(
  input: desktop_file_intermediate,
  output: '@0@.desktop'.format(app_id),
  copy: true,
  install: true,
  install_dir: join_paths(datadir, 'applications')
)

metainfo_conf = configuration_data()
metainfo_conf.set('app-id', app_id)
metainfo_file_intermediate = configure_file(
  input: '@0@.metainfo.xml.in.in'.format(base_id),
  output: '@0@.metainfo.xml.intermediate'.format(base_id),
  configuration: metainfo_conf
)
metainfo_file = configure_file(
  input: metainfo_file_intermediate,
  output: '@0@.metainfo.xml'.format(app_id),
  copy: true,
  install: true,
  install_dir: join_paths(datadir, 'metainfo')
)

resource_conf = configuration_data()
resource_conf.set('app-id', app_id)
resource_conf.set('base-id-slashed', '/' + base_id.replace('.', '/'))
resource_files = configure_file(
  input: 'gnome-sudoku.gresource.xml.in',
  output: '@BASENAME@',
  configuration: resource_conf
)

schema_file = '@0@.gschema.xml'.format(base_id)
install_data(
  schema_file,
  install_dir: join_paths(datadir, 'glib-2.0', 'schemas')
)

install_man('@0@.6'.format(meson.project_name()))

icondir = join_paths(datadir, 'icons', 'hicolor')
install_data(
  'icons/hicolor/scalable/@0@.svg'.format(app_id),
  install_dir: join_paths(icondir, 'scalable', 'apps')
)

install_data(
  'icons/hicolor/symbolic/@0@-symbolic.svg'.format(base_id),
  install_dir: join_paths(icondir, 'symbolic', 'apps'),
  rename: '@0@-symbolic.svg'.format(app_id)
)

service_conf = configuration_data()
service_conf.set('bindir', join_paths(prefix, bindir))
service_conf.set('app-id', app_id)

configure_file(
  input: '@0@.service.in'.format(base_id),
  output: '@0@.service'.format(app_id),
  install: true,
  install_dir: join_paths(prefix, datadir, 'dbus-1', 'services'),
  configuration: service_conf
)
EOF

# Manual src/meson.build fix (re-applying)
cat <<EOF > src/meson.build
blueprints = custom_target(
  'blueprints',
  input: files(
    'blueprints/game-view.blp',
    'blueprints/menu-button.blp',
    'blueprints/preferences-dialog.blp',
    'blueprints/print-dialog.blp',
    'blueprints/shortcuts-window.blp',
    'blueprints/start-view.blp',
    'blueprints/window.blp',
  ),
  output: '.',
  install_dir: '@CURRENT_SOURCE_DIR@',
  command: [blueprintc, 'batch-compile', '@OUTPUT@', '@CURRENT_SOURCE_DIR@', '@INPUT@'],
)

resources = gnome.compile_resources(
  'gnome-sudoku',
  resource_files,
  dependencies: blueprints,
  source_dir: [
    join_paths(meson.project_build_root(), 'data'),
    join_paths(meson.project_source_root(), 'data'),
    join_paths(meson.current_build_dir(), 'blueprints')
  ]
)

gnome_sudoku_vala_args = ['--pkg=posix']

gnome_sudoku_sources = [
  'config.vapi',
  'cell.vala',
  'earmark.vala',
  'game-view.vala',
  'gnome-sudoku.vala',
  'grid.vala',
  'grid-layout.vala',
  'menu-button.vala',
  'number-picker.vala',
  'preferences-dialog.vala',
  'print-dialog.vala',
  'printer.vala',
  'start-view.vala',
  'window.vala',
  resources
]

gnome_sudoku_dependencies = [gtk, libsudoku_dep, adw]
gnome_sudoku = executable(
  meson.project_name(),
  gnome_sudoku_sources,
  dependencies: gnome_sudoku_dependencies,
  vala_args: gnome_sudoku_vala_args,
  install: true,
)
EOF

rm -rf build
# Use our built dependencies
meson setup build --prefix=/usr --buildtype=release
meson compile -C build
DESTDIR="$APPDIR" meson install -C build

echo "=== Creating AppImage ==="
cd "$REPO_ROOT"

# Create basic AppDir structure
mkdir -p "$APPDIR/usr/bin"
mkdir -p "$APPDIR/usr/lib"

# Copy our custom built dependencies into AppDir
cp -P "$DEPS_PREFIX"/lib/x86_64-linux-gnu/*.so* "$APPDIR/usr/lib/" || true
cp -P "$DEPS_PREFIX"/lib/*.so* "$APPDIR/usr/lib/" || true

# Copy blueprint modules too
mkdir -p "$APPDIR/usr/lib/python3/dist-packages"
cp -r "$DEPS_PREFIX/lib/python3/dist-packages/"* "$APPDIR/usr/lib/python3/dist-packages/" || true

# Download linuxdeploy if not present
if [ ! -f linuxdeploy ]; then
    wget -q https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage -O linuxdeploy
    chmod +x linuxdeploy
fi

# Use linuxdeploy to bundle everything
export OUTPUT="Sudoku-${VERSION}-x86_64.AppImage"
./linuxdeploy --appdir "$APPDIR" \
    --executable "$APPDIR/usr/bin/gnome-sudoku" \
    --desktop-file "$PROJECT_DIR/data/org.gnome.Sudoku.desktop" \
    --icon-file "$PROJECT_DIR/data/icons/hicolor/scalable/apps/org.gnome.Sudoku.svg" \
    --library "$APPDIR/usr/lib/libadwaita-1.so.0" \
    --library "$APPDIR/usr/lib/libgtk-4.so.1" \
    --library "$APPDIR/usr/lib/libglib-2.0.so.0" \
    --library "$APPDIR/usr/lib/libgio-2.0.so.0" \
    --library "$APPDIR/usr/lib/libgobject-2.0.so.0" \
    --library "$APPDIR/usr/lib/libpango-1.0.so.0" \
    --appimage

echo "AppImage created: $OUTPUT"
