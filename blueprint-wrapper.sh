#!/bin/bash
export PYTHONPATH="/home/mbarina/dev/gnome-sudoku-appimage/deps-dist/lib/python3/dist-packages"
# Include system paths for typelibs too
export GI_TYPELIB_PATH="/home/mbarina/dev/gnome-sudoku-appimage/deps-dist/lib/x86_64-linux-gnu/girepository-1.0:/home/mbarina/dev/gnome-sudoku-appimage/deps-dist/lib/girepository-1.0:/usr/lib/x86_64-linux-gnu/girepository-1.0:/usr/lib/girepository-1.0"
export LD_LIBRARY_PATH="/home/mbarina/dev/gnome-sudoku-appimage/deps-dist/lib/x86_64-linux-gnu:/home/mbarina/dev/gnome-sudoku-appimage/deps-dist/lib:$LD_LIBRARY_PATH"
exec /home/mbarina/dev/gnome-sudoku-appimage/deps-dist/bin/blueprint-compiler "$@"
