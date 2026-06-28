#!/usr/bin/env bash
#
# xTool Studio on Fedora (via Wine, no Bottles)
# ------------------------------------------------
# Builds a clean Wine prefix, extracts xTool Studio straight from its
# installer (bypassing the broken Electron installer), and creates a
# one-click launcher with all the working performance/rendering flags.
#
# Usage:
#   ./install.sh [/path/to/xTool-Studio-x64-VERSION.exe]
#
# If no path is given, the script looks for an installer in ~/Downloads.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Config — tweak these if you like
# ---------------------------------------------------------------------------
APP_NAME="xTool Studio"
SLUG="xtool-studio"
PREFIX="$HOME/.local/share/${SLUG}/wineprefix"   # dedicated Wine prefix
INSTALL_DIR="drive_c/Program Files/${APP_NAME}"  # path inside the prefix
DPI=163                                           # 96 x desktop-scale; 163 = 170%
ANGLE_BACKEND="gl"                                # gl = clean+accelerated (vulkan glitches)

BIN_DIR="$HOME/.local/bin"
LAUNCHER="$BIN_DIR/${SLUG}.sh"
DESKTOP_FILE="$HOME/.local/share/applications/${SLUG}.desktop"
ICON_DIR="$HOME/.local/share/icons/hicolor/256x256/apps"
ICON_PATH="$ICON_DIR/${SLUG}.png"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
say()  { printf '\033[1;36m::\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "Run this as your normal user, not root (it uses sudo only where needed)."
command -v dnf >/dev/null 2>&1 || die "This script targets Fedora (dnf not found)."

# ---------------------------------------------------------------------------
# 1. Locate the installer .exe
# ---------------------------------------------------------------------------
INSTALLER="${1:-}"
if [ -z "$INSTALLER" ]; then
    INSTALLER="$(ls -1t "$HOME"/Downloads/xTool-Studio*.exe 2>/dev/null | head -1 || true)"
fi
[ -n "$INSTALLER" ] && [ -f "$INSTALLER" ] || die \
"Could not find an xTool Studio installer.
   Download it from https://www.xtool.com/pages/software (or s.xtool.com/software),
   then re-run:   ./install.sh ~/Downloads/xTool-Studio-x64-VERSION.exe"
INSTALLER="$(readlink -f "$INSTALLER")"
say "Using installer: $INSTALLER"

# ---------------------------------------------------------------------------
# 2. Dependencies
# ---------------------------------------------------------------------------
say "Installing dependencies (you may be prompted for your password)…"
sudo dnf install -y wine winetricks 7zip icoutils ImageMagick \
    >/dev/null || die "Dependency install failed."

command -v wine    >/dev/null || die "wine not available after install."
command -v 7z      >/dev/null || die "7z not available after install."
command -v wrestool >/dev/null || die "wrestool (icoutils) not available after install."

# ---------------------------------------------------------------------------
# 3. Build a clean Wine prefix (Windows 10, 64-bit, DPI)
# ---------------------------------------------------------------------------
export WINEPREFIX="$PREFIX"
export WINEARCH=win64
export WINEDEBUG=-all

if [ -f "$PREFIX/system.reg" ]; then
    say "Wine prefix already exists at $PREFIX (reusing)."
else
    say "Creating Wine prefix at $PREFIX …"
    mkdir -p "$PREFIX"
    wineboot -i >/dev/null 2>&1 || die "wineboot failed to initialise the prefix."
    say "Setting Windows version to 10 …"
    winetricks -q win10 >/dev/null 2>&1 || warn "winetricks win10 reported an issue; continuing."
fi

say "Setting DPI to $DPI …"
wine reg add "HKCU\\Control Panel\\Desktop" /v LogPixels /t REG_DWORD /d "$DPI" /f \
    >/dev/null 2>&1 || warn "Could not set DPI; you can adjust it later."
wineserver -w 2>/dev/null || true

# ---------------------------------------------------------------------------
# 4. Extract the app straight out of the installer
# ---------------------------------------------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
say "Extracting application payload from installer…"
# Outer NSIS archive holds the inner electron-builder app archive.
7z x "$INSTALLER" '$PLUGINSDIR/app-64.7z' -o"$WORK/outer" >/dev/null \
    || die "Could not extract app-64.7z from the installer (unexpected installer layout)."
INNER="$(find "$WORK/outer" -iname 'app-64.7z' | head -1)"
[ -n "$INNER" ] || die "Inner app archive not found inside installer."
7z x "$INNER" -o"$WORK/app" >/dev/null || die "Could not unpack the application archive."
[ -f "$WORK/app/${APP_NAME}.exe" ] || die "Extracted payload is missing ${APP_NAME}.exe."

# ---------------------------------------------------------------------------
# 5. Install the app into the prefix
# ---------------------------------------------------------------------------
DEST="$PREFIX/$INSTALL_DIR"
say "Installing app to: $DEST"
mkdir -p "$DEST"
cp -rf "$WORK/app/." "$DEST/"
APP_EXE="$DEST/${APP_NAME}.exe"

# ---------------------------------------------------------------------------
# 6. Extract the application icon
# ---------------------------------------------------------------------------
say "Extracting icon…"
mkdir -p "$ICON_DIR"
if wrestool -x -t 14 -o "$WORK/icons" "$INSTALLER" >/dev/null 2>&1 \
   && ICO="$(ls -1 "$WORK"/icons/*.ico 2>/dev/null | head -1)" && [ -n "$ICO" ] \
   && magick "$ICO" "$WORK/icons/out.png" >/dev/null 2>&1; then
    BIG="$(ls -S "$WORK"/icons/out*.png 2>/dev/null | head -1)"
    [ -n "$BIG" ] && cp "$BIG" "$ICON_PATH"
fi
[ -f "$ICON_PATH" ] || warn "Icon extraction failed; the launcher will use a generic icon."

# ---------------------------------------------------------------------------
# 7. Write the launcher script
# ---------------------------------------------------------------------------
say "Writing launcher: $LAUNCHER"
mkdir -p "$BIN_DIR"
cat > "$LAUNCHER" <<EOF
#!/usr/bin/env bash
# Launcher for ${APP_NAME} under Wine.
# Runs system Wine directly with file-backed stdio (fixes the Electron EBADF
# crash that occurs when stdout/stderr are pipes) plus performance flags.
export WINEPREFIX="$PREFIX"
export WINEARCH=win64
export WINENTSYNC=1
export WINEFSYNC=1
export WINEESYNC=1
export WINEDEBUG=-all
powerprofilesctl set performance 2>/dev/null || true
exec /usr/bin/wine "$APP_EXE" \\
    --use-angle=${ANGLE_BACKEND} --ignore-gpu-blocklist --enable-gpu-rasterization \\
    >/tmp/${SLUG}-out.log 2>/tmp/${SLUG}-err.log
EOF
chmod +x "$LAUNCHER"

# ---------------------------------------------------------------------------
# 8. Write the desktop entry
# ---------------------------------------------------------------------------
say "Writing desktop entry: $DESKTOP_FILE"
mkdir -p "$(dirname "$DESKTOP_FILE")"
cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Name=${APP_NAME}
Comment=xTool laser software (Wine)
Exec=${LAUNCHER}
Icon=${SLUG}
Terminal=false
Type=Application
Categories=Graphics;
EOF

# ---------------------------------------------------------------------------
# 9. Refresh desktop / icon caches
# ---------------------------------------------------------------------------
gtk-update-icon-cache "$HOME/.local/share/icons/hicolor" >/dev/null 2>&1 || true
update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true
kbuildsycoca6 >/dev/null 2>&1 || true

say "Done!"
echo
echo "  Launch '${APP_NAME}' from your application menu, or run: $LAUNCHER"
echo "  Logs:        /tmp/${SLUG}-out.log  and  /tmp/${SLUG}-err.log"
echo "  Wine prefix: $PREFIX"
echo
echo "  Notes:"
echo "   - First run: set region/login, then connect the F2 over Wi-Fi."
echo "   - If the editor renders glitchy, edit $LAUNCHER and keep --use-angle=gl."
echo "   - To uninstall: rm -rf \"$PREFIX\" \"$LAUNCHER\" \"$DESKTOP_FILE\" \"$ICON_PATH\""
