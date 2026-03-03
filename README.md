# GNOME Sudoku AppImage

This repository provides a standalone AppImage for GNOME Sudoku 47.1.1, built with compatibility for older systems (like MX Linux 23).

## Features

- **Standalone AppImage:** Includes all necessary GNOME/GTK dependencies.
- **Improved Compatibility:** Patched to run on systems with older libraries (Vala, GTK 4, GLib).
- **Visual Fixes:** Custom CSS for better selection visibility and earmark layout.
- **Portability:** Runs without requiring system-wide installation of GNOME 47.

## Known Issues

- **Full-screen Crash:** The application may crash when entering or exiting full-screen mode. We recommend using it in windowed mode for stability.

## Building

To build the AppImage locally:

1. Install dependencies listed in `.github/workflows/build.yml`.
2. Run `./build_deps.sh` to build custom dependencies.
3. Run `bash build/build-gnome-sudoku-appimage.sh` to create the AppImage.

The resulting AppImage will be named `GNOME_Sudoku-x86_64.AppImage`.

## License

This build project is licensed under the same terms as GNOME Sudoku (GPL-3.0-or-later).
