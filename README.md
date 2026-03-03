# GNOME Sudoku for Linux (AppImage)

This project provides an easy-to-use version of GNOME Sudoku that runs on almost any Linux distribution (Ubuntu, Fedora, Debian, MX Linux, etc.) without needing to install any extra software.

[**Download the latest version here**](https://github.com/kamilnovo/gnome-sudoku-appimage/releases/latest)

## How to use it

1.  **Download:** Get the `.AppImage` file from the link above.
2.  **Make it executable:** Right-click the file, go to **Properties** > **Permissions**, and check the box that says **"Allow executing file as program"**.
    - *Or use the terminal:* `chmod +x GNOME_Sudoku-x86_64.AppImage`
3.  **Run:** Double-click the file to start the game!

## Why use this version?

This version is specifically built to work on both brand-new and older Linux systems (like MX Linux 23). It includes all the "behind-the-scenes" components it needs to run, so you don't have to worry about missing libraries or version conflicts.

---

### For Developers
If you wish to build this AppImage yourself, please refer to the build scripts (`build_deps.sh` and `build/build-gnome-sudoku-appimage.sh`) and the CI configuration in `.github/workflows/build.yml`.
