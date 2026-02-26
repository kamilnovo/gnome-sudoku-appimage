#!/bin/bash
set -e
export APPIMAGE_EXTRACT_AND_RUN=1
VERSION="49.4"
REPO_URL="https://gitlab.gnome.org/GNOME/gnome-sudoku.git"
PROJECT_DIR="gnome-sudoku-$VERSION"
APPDIR="AppDir"

cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"
rm -rf "$APPDIR" "$PROJECT_DIR" blueprint-dest
mkdir -p "$APPDIR"

# 1. Build blueprint-compiler (v0.16.0)
echo "=== Building blueprint-compiler ==-"
git clone --depth 1 --branch v0.16.0 https://gitlab.gnome.org/jwestman/blueprint-compiler.git
cd blueprint-compiler
meson setup build --prefix=/usr
DESTDIR="$REPO_ROOT/blueprint-dest" meson install -C build
export PATH="$REPO_ROOT/blueprint-dest/usr/bin:$PATH"
export PYTHONPATH="$REPO_ROOT/blueprint-dest/usr/lib/python3/dist-packages:$PYTHONPATH"
cd "$REPO_ROOT"

# 2. Fetch Sudoku source
echo "=== Fetching gnome-sudoku $VERSION ==-"
git clone --depth 1 --branch "$VERSION" "$REPO_URL" "$PROJECT_DIR"

# 3. Surgical Patching for Debian 12 (Libadwaita 1.2 / GTK 4.8)
echo "=== Surgical Patching for Libadwaita 1.2 ==-"

cd "$PROJECT_DIR"

# A. Force-relax versions in meson.build
sed -i "s/glib_version = '[0-9.]*'/glib_version = '2.74.0'/g" meson.build
sed -i "s/gtk4', version: '>= [0-9.]*'/gtk4', version: '>= 4.8.0'/g" meson.build
sed -i "s/libadwaita-1', version: '>= [0-9.]*'/libadwaita-1', version: '>= 1.2.0'/g" meson.build

# B. Rewrite ALL Blueprints manually with STRICT 1.2 syntax
cat << EOF > src/blueprints/window.blp
using Gtk 4.0;
using Adw 1;
template \$SudokuWindow : Adw.ApplicationWindow {
  content: Box {
    orientation: vertical;
    Adw.ViewStack stack {
      Adw.ViewStackPage {
        name: "start-view";
        child: \$SudokuStartView start_view {};
      }
      Adw.ViewStackPage {
        name: "game-view";
        child: \$SudokuGameView game_view {};
      }
    }
  };
}
EOF

cat << EOF > src/blueprints/game-view.blp
using Gtk 4.0;
using Adw 1;
template \$SudokuGameView : Adw.Bin {
  child: Box {
    orientation: vertical;
    Adw.HeaderBar {
      title-widget: Gtk.Label { label: _("Sudoku"); };
      [start]
      Button {
        icon-name: "go-previous-symbolic";
        action-name: "app.back";
      }
      [end]
      \$SudokuMenuButton menu_button {}
    }
    \$SudokuGrid grid {
      vexpand: true;
      hexpand: true;
    }
  };
}
EOF

cat << EOF > src/blueprints/preferences-dialog.blp
using Gtk 4.0;
using Adw 1;
template \$SudokuPreferencesDialog : Adw.PreferencesWindow {
  Adw.PreferencesPage {
    Adw.PreferencesGroup {
      title: _("General");
      Adw.ActionRow {
        title: _("Show Timer");
        [suffix]
        Switch show_timer {
          valign: center;
        }
      }
    }
  }
}
EOF

cat << EOF > src/blueprints/start-view.blp
using Gtk 4.0;
using Adw 1;
template \$SudokuStartView : Adw.Bin {
  child: Box {
    orientation: vertical;
    valign: center;
    halign: center;
    spacing: 12;
    Adw.HeaderBar {
      title-widget: Gtk.Label { label: _("Sudoku"); };
      [end]
      \$SudokuMenuButton menu_button {}
    }
    Gtk.Label {
      label: _("Select Difficulty");
      styles ["title-1"]
    }
    Button { label: _("Easy"); clicked => \$start_easy_cb(); }
    Button { label: _("Medium"); clicked => \$start_medium_cb(); }
    Button { label: _("Hard"); clicked => \$start_hard_cb(); }
    Button { label: _("Very Hard"); clicked => \$start_very_hard_cb(); }
  };
}
EOF

cat << EOF > src/blueprints/print-dialog.blp
using Gtk 4.0;
using Adw 1;
template \$SudokuPrintDialog : Adw.Window {
  modal: true;
  title: _("Print Sudokus");
  content: Box {
    orientation: vertical;
    Adw.HeaderBar {}
    Adw.PreferencesPage {
      Adw.PreferencesGroup {
        Adw.ActionRow {
          title: _("Number of puzzles");
          [suffix]
          SpinButton n_puzzles {
            adjustment: Adjustment {
              lower: 1;
              upper: 100;
              step-increment: 1;
            };
            valign: center;
          }
        }
      }
    }
    Button {
      label: _("_Print");
      use-underline: true;
      styles ["suggested-action"]
      clicked => \$print_cb();
    }
  };
}
EOF

cat << EOF > src/blueprints/menu-button.blp
using Gtk 4.0;
template \$SudokuMenuButton : MenuButton {
  primary: true;
  icon-name: "open-menu-symbolic";
}
EOF

cat << EOF > src/blueprints/shortcuts-window.blp
using Gtk 4.0;
template \$SudokuShortcutsWindow : Gtk.Window {
  modal: true;
  title: _("Shortcuts");
  child: Gtk.Label { label: _("Shortcuts not available"); };
}
EOF

# C. Vala code fixes (Comprehensive)
find . -name "*.vala" -exec sed -i 's/Adw.PreferencesDialog/Adw.PreferencesWindow/g' {} +
find . -name "*.vala" -exec sed -i 's/Adw.AlertDialog/Adw.MessageDialog/g' {} +
find . -name "*.vala" -exec sed -i 's/\bAdw.WindowTitle\b/Gtk.Label/g' {} +
find . -name "*.vala" -exec sed -i 's/\bAdw.SpinRow\b/Adw.ActionRow/g' {} +
find . -name "*.vala" -exec sed -i 's/\bAdw.SwitchRow\b/Adw.ActionRow/g' {} +
find . -name "*.vala" -exec sed -i 's/\bAdw.ToolbarView\b/Gtk.Box/g' {} +
find . -name "*.vala" -exec sed -i 's/\bAdw.StatusPage\b/Gtk.Box/g' {} +
find . -name "*.vala" -exec sed -i 's/\bAdw.Dialog\b/Adw.Window/g' {} +
find . -name "*.vala" -exec sed -i 's/windowtitle.title = /windowtitle.label = /g' {} +
find . -name "*.vala" -exec sed -i 's/\.present\s*\([^)]+\)/.present()/g' {} +

# D. Match Vala callbacks to new Blueprint buttons in start-view.vala
sed -i 's/public void start_game_cb\s*(int\s*difficulty)/[CCode (instance_pos = -1)]\n    public void start_easy_cb(Button b) { start_game(1); }\n    [CCode (instance_pos = -1)]\n    public void start_medium_cb(Button b) { start_game(2); }\n    [CCode (instance_pos = -1)]\n    public void start_hard_cb(Button b) { start_game(3); }\n    [CCode (instance_pos = -1)]\n    public void start_very_hard_cb(Button b) { start_game(4); }\n    public void start_game_cb(int difficulty)/g' src/start-view.vala

# E. C++ fixes
sed -i '1i #include <ctime>\n#include <cstdlib>' lib/qqwing-wrapper.cpp
sed -i 's/srand\s*(.*)/srand(time(NULL))/g' lib/qqwing-wrapper.cpp

# 4. Build Sudoku
echo "=== Building Sudoku ==-"
meson setup build --prefix=/usr -Dbuildtype=release
meson compile -C build -v
DESTDIR="$REPO_ROOT/$APPDIR" meson install -C build
cd "$REPO_ROOT"

# 5. Packaging
echo "=== Packaging AppImage ==-"
wget -q https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage -O linuxdeploy
wget -q https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/master/linuxdeploy-plugin-gtk.sh -O linuxdeploy-plugin-gtk.sh
wget -q https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage -O appimagetool
chmod +x linuxdeploy linuxdeploy-plugin-gtk.sh appimagetool

export PATH="$PWD:$PATH"
export VERSION
export DEPLOY_GTK_VERSION=4

./linuxdeploy --appdir "$APPDIR" \
    -e "$APPDIR/usr/bin/gnome-sudoku" \
    --plugin gtk

glib-compile-schemas "$APPDIR/usr/share/glib-2.0/schemas"

cat << 'EOF' > "$APPDIR/AppRun"
#!/bin/sh
HERE="$(dirname "$(readlink -f "${0}")")"
export GSETTINGS_SCHEMA_DIR="$HERE/usr/share/glib-2.0/schemas"
export XDG_DATA_DIRS="$HERE/usr/share:$XDG_DATA_DIRS"
export LD_LIBRARY_PATH="$HERE/usr/lib:$HERE/usr/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH"
export GI_TYPELIB_PATH="$HERE/usr/lib/girepository-1.0:$HERE/usr/lib/x86_64-linux-gnu/girepository-1.0:$GI_TYPELIB_PATH"
export GTK_THEME=Adwaita
exec "$HERE/usr/bin/gnome-sudoku" "$@"
EOF
chmod +x "$APPDIR/AppRun"

./appimagetool "$APPDIR" Sudoku-49.4-x86_64.AppImage
echo "Done!"
