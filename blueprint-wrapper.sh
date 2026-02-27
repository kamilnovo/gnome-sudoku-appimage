#!/bin/bash
# Use dynamic paths based on the current script's location
SCRIPT_DIR=$(dirname "$(realpath "$0")")
DEPS_PREFIX="$SCRIPT_DIR/deps-dist"

export PYTHONPATH="$DEPS_PREFIX/lib/python3/dist-packages:$DEPS_PREFIX/lib/x86_64-linux-gnu/gobject-introspection:$PYTHONPATH"
export GI_TYPELIB_PATH="$DEPS_PREFIX/lib/x86_64-linux-gnu/girepository-1.0:$DEPS_PREFIX/lib/girepository-1.0:/usr/lib/x86_64-linux-gnu/girepository-1.0:/usr/lib/girepository-1.0"
export LD_LIBRARY_PATH="$DEPS_PREFIX/lib/x86_64-linux-gnu:$DEPS_PREFIX/lib:$LD_LIBRARY_PATH"

# Execute blueprint-compiler, ensuring it's found in the DEPS_PREFIX
exec "$DEPS_PREFIX/bin/blueprint-compiler" "$@"
