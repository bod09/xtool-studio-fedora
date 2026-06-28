#!/usr/bin/env bash
#
# xTool Studio on Fedora (via Wine, no extra frameworks)
# ------------------------------------------------------
# Interactive, re-runnable installer and configurator.
#
#   First run : installs everything (deps, Wine prefix, app, icon, launcher).
#   Later runs: reconfigure GPU/DPI/sync, update the app, set up USB, or
#               uninstall, WITHOUT rebuilding the prefix or re-extracting the
#               app unless you explicitly ask for it.
#
# Usage:
#   ./install.sh [/path/to/xTool-Studio-x64-VERSION.exe]
#
# A menu is shown on every run. Your choices are saved to
#   ~/.config/xtool-studio/config
# and pre-filled the next time you run the script.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Constants (not user-tunable; these are layout/paths, not preferences)
# ---------------------------------------------------------------------------
APP_NAME="xTool Studio"
SLUG="xtool-studio"
SHARE_DIR="$HOME/.local/share/${SLUG}"
PREFIX="$SHARE_DIR/wineprefix"                   # dedicated Wine prefix
INSTALL_DIR="drive_c/Program Files/${APP_NAME}"  # path inside the prefix

BIN_DIR="$HOME/.local/bin"
LAUNCHER="$BIN_DIR/${SLUG}.sh"
DESKTOP_FILE="$HOME/.local/share/applications/${SLUG}.desktop"
ICON_DIR="$HOME/.local/share/icons/hicolor/256x256/apps"
ICON_PATH="$ICON_DIR/${SLUG}.png"
ICON_FILE="${SLUG}.png"   # icon shipped in the repo, alongside this script
ICON_URL="https://raw.githubusercontent.com/bod09/xtool-studio-fedora/main/${ICON_FILE}"

# Directory this script lives in, used to find the bundled icon. Empty when the
# script is piped straight into bash (curl | bash), in which case we download it.
SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"
if [ -f "$SCRIPT_SOURCE" ]; then
    SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_SOURCE")" && pwd)"
else
    SCRIPT_DIR=""
fi

CONFIG_DIR="$HOME/.config/${SLUG}"
CONFIG_FILE="$CONFIG_DIR/config"

# USB serial (CH340) setup
UDEV_RULE="/etc/udev/rules.d/99-xtool-ch340.rules"
USB_SYMLINK="xtool"   # stable /dev/xtool created by the udev rule

APP_EXE="$PREFIX/$INSTALL_DIR/${APP_NAME}.exe"   # derived, same every run

# Passed-in installer path (optional), and a scratch dir cleaned on exit.
INSTALLER_ARG="${1:-}"
INSTALLER=""
WORK=""

# ---------------------------------------------------------------------------
# User-configurable settings (defaults; overwritten by config + prompts)
# ---------------------------------------------------------------------------
GPU_BACKEND="gl"          # gl | vulkan | disable-gpu
DPI=""                    # blank => detect on first configure (never silently 163)
SYNC="auto"               # auto | on | off  (ntsync/fsync/esync)
INSTALLER_PATH=""         # last installer used (remembered, informational)

# Detection results filled in by detect_gpu / detect_scale.
GPU_NAME=""
GPU_VENDOR="unknown"
DETECTED_SCALE=""
DETECTED_METHOD=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
say()  { printf '\033[1;36m::\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

cleanup() { [ -n "${WORK:-}" ] && rm -rf "$WORK"; }
trap cleanup EXIT

# Ask a free-text question with a default. Prompt goes to stderr (via read -p),
# the answer to stdout, so this is safe to use in "x=$(prompt_default ...)".
prompt_default() {
    local q="$1" d="$2" ans=""
    read -r -p "$q [$d]: " ans || true
    printf '%s' "${ans:-$d}"
}

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
[ "$(id -u)" -ne 0 ] || die "Run this as your normal user, not root (it uses sudo only where needed)."
command -v dnf >/dev/null 2>&1 || die "This script targets Fedora (dnf not found)."

# Make the menu work even under "curl ... | bash": in that case stdin is the
# script itself, so reopen the controlling terminal for interactive reads.
# Probe in a subshell first: in a truly headless context (no controlling
# terminal) /dev/tty can pass a read test yet fail to open, and a failed
# "exec <" would abort a non-interactive shell. The probe avoids that.
if [ ! -t 0 ] && ( exec </dev/tty ) 2>/dev/null; then
    exec </dev/tty
fi

# ---------------------------------------------------------------------------
# Config persistence
# ---------------------------------------------------------------------------
load_config() {
    # Defaults are already set above; the config file overrides them.
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck disable=SC1090  # our own generated, trusted file
        . "$CONFIG_FILE"
    fi
}

save_config() {
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<EOF
# xTool Studio installer settings - auto-generated, re-run install.sh to change.
GPU_BACKEND="$GPU_BACKEND"
DPI="$DPI"
SYNC="$SYNC"
INSTALLER_PATH="$INSTALLER_PATH"
EOF
    say "Settings saved to $CONFIG_FILE"
}

# ---------------------------------------------------------------------------
# Detection: GPU
# ---------------------------------------------------------------------------
detect_gpu() {
    GPU_NAME=""
    GPU_VENDOR="unknown"
    if command -v lspci >/dev/null 2>&1; then
        GPU_NAME=$(lspci 2>/dev/null | grep -Ei 'vga|3d controller|display' \
            | sed -E 's/^[0-9a-f:.]+ [^:]+: //' | head -1 || true)
    fi
    if [ -z "$GPU_NAME" ] && command -v glxinfo >/dev/null 2>&1; then
        GPU_NAME=$(glxinfo 2>/dev/null | grep -i 'OpenGL renderer' \
            | cut -d: -f2- | sed 's/^ *//' | head -1 || true)
    fi
    case "${GPU_NAME,,}" in
        *nvidia*|*geforce*|*quadro*) GPU_VENDOR="nvidia" ;;
        *amd*|*radeon*|*ati*)        GPU_VENDOR="amd" ;;
        *intel*)                     GPU_VENDOR="intel" ;;
        *)                           GPU_VENDOR="unknown" ;;
    esac
}

# ---------------------------------------------------------------------------
# Detection: display scale -> DPI
#
# We compute DPI as round(96 * scale). The scale comes from the desktop:
#   KDE   : kscreen-doctor, then kdeglobals, then the kscreen config cache.
#   GNOME : gsettings text-scaling-factor combined with the per-monitor
#           (Mutter) scale from ~/.config/monitors.xml.
# If nothing usable is found we leave DETECTED_SCALE empty and the caller
# falls back to a NEUTRAL 96 (100%, no scaling) - never a silent 163.
# ---------------------------------------------------------------------------
detect_scale() {
    DETECTED_SCALE=""
    DETECTED_METHOD=""
    local de="${XDG_CURRENT_DESKTOP:-}"
    local s=""

    case "${de,,}" in
        *kde*|*plasma*)
            if command -v kscreen-doctor >/dev/null 2>&1; then
                # Strip ANSI colour codes first: kscreen-doctor colourises its
                # output, and the escape digits (e.g. "\e[01;33m") would
                # otherwise be picked up as the scale value. Read the number
                # after "Scale:" from the first (primary) output.
                s=$(kscreen-doctor -o 2>/dev/null \
                    | sed 's/\x1b\[[0-9;]*m//g' \
                    | grep -iE 'Scale:' \
                    | grep -oE '[0-9]+(\.[0-9]+)?' | head -1 || true)
                if [ -n "$s" ]; then
                    DETECTED_SCALE="$s"; DETECTED_METHOD="kscreen-doctor"; return
                fi
            fi
            if [ -f "$HOME/.config/kdeglobals" ]; then
                s=$(grep -E '^[[:space:]]*ScaleFactor[[:space:]]*=' "$HOME/.config/kdeglobals" 2>/dev/null \
                    | head -1 | grep -oE '[0-9]+(\.[0-9]+)?' | head -1 || true)
                if [ -n "$s" ]; then
                    DETECTED_SCALE="$s"; DETECTED_METHOD="kdeglobals"; return
                fi
            fi
            local kf=""
            kf=$(find "$HOME/.config/kscreen" -type f 2>/dev/null | head -1 || true)
            if [ -n "$kf" ]; then
                s=$(grep -oE '"scale":[0-9]+(\.[0-9]+)?' "$kf" 2>/dev/null \
                    | head -1 | grep -oE '[0-9]+(\.[0-9]+)?' || true)
                if [ -n "$s" ]; then
                    DETECTED_SCALE="$s"; DETECTED_METHOD="kscreen config"; return
                fi
            fi
            ;;
        *gnome*|*unity*|*ubuntu*|*cinnamon*)
            # GNOME-family: only trust this path if gsettings is present.
            if command -v gsettings >/dev/null 2>&1; then
                local text="1" isf="" base=""
                text=$(gsettings get org.gnome.desktop.interface text-scaling-factor 2>/dev/null \
                    | grep -oE '[0-9]+(\.[0-9]+)?' | head -1 || true)
                [ -n "$text" ] || text="1"
                isf=$(gsettings get org.gnome.desktop.interface scaling-factor 2>/dev/null \
                    | grep -oE '[0-9]+' | head -1 || true)
                # Fractional per-monitor scale is stored by Mutter in monitors.xml.
                if [ -f "$HOME/.config/monitors.xml" ]; then
                    base=$(grep -oE '<scale>[0-9]+(\.[0-9]+)?</scale>' "$HOME/.config/monitors.xml" 2>/dev/null \
                        | head -1 | grep -oE '[0-9]+(\.[0-9]+)?' || true)
                fi
                if [ -z "$base" ]; then
                    if [ -n "$isf" ] && [ "$isf" -ge 1 ] 2>/dev/null; then
                        base="$isf"
                    else
                        base="1"
                    fi
                fi
                s=$(awk -v b="$base" -v t="$text" 'BEGIN{printf "%.4f", b*t}')
                if [ -n "$s" ]; then
                    DETECTED_SCALE="$s"; DETECTED_METHOD="gsettings/monitors.xml"; return
                fi
            fi
            ;;
    esac
    # Anything else: leave DETECTED_SCALE empty -> neutral fallback in caller.
}

# ---------------------------------------------------------------------------
# Interactive choosers. Each prints its menu to stderr and the chosen value to
# stdout, so callers can do  VAR="$(choose_x "$VAR")".
# ---------------------------------------------------------------------------
choose_gpu() {
    local cur="$1" def=1 ans=""
    {
        echo "GPU rendering backend:"
        echo "  1) gl          - stable, hardware accelerated (default)"
        echo "  2) vulkan      - faster, but may show visual glitches"
        echo "  3) disable-gpu - software rendering, slowest but safest"
    } >&2
    case "$cur" in gl) def=1 ;; vulkan) def=2 ;; disable-gpu) def=3 ;; esac
    read -r -p "Choose [1-3] ($def): " ans || true
    ans="${ans:-$def}"
    case "$ans" in 1) echo gl ;; 2) echo vulkan ;; 3) echo disable-gpu ;; *) echo "$cur" ;; esac
}

choose_sync() {
    local cur="$1" def=1 ans="" detected="off"
    [ -e /dev/ntsync ] && detected="on"
    {
        echo "Thread-sync accelerators (ntsync/fsync/esync):"
        echo "  /dev/ntsync present: $detected"
        echo "  1) auto - enable them when /dev/ntsync exists (default)"
        echo "  2) on   - force enable"
        echo "  3) off  - disable"
    } >&2
    case "$cur" in auto) def=1 ;; on) def=2 ;; off) def=3 ;; esac
    read -r -p "Choose [1-3] ($def): " ans || true
    ans="${ans:-$def}"
    case "$ans" in 1) echo auto ;; 2) echo on ;; 3) echo off ;; *) echo "$cur" ;; esac
}

# Resolve the sync setting to a yes/no for launcher generation.
sync_enabled() {
    case "$SYNC" in
        on)  return 0 ;;
        off) return 1 ;;
        *)   [ -e /dev/ntsync ] ;;   # auto
    esac
}

# ---------------------------------------------------------------------------
# DPI configuration (detect, suggest, let the user accept or override)
# ---------------------------------------------------------------------------
configure_dpi() {
    local current="$DPI" suggested="" def="" ans=""
    detect_scale
    if [ -n "$DETECTED_SCALE" ]; then
        local pct dpi
        pct=$(awk -v s="$DETECTED_SCALE" 'BEGIN{printf "%.0f", s*100}')
        dpi=$(awk -v s="$DETECTED_SCALE" 'BEGIN{printf "%.0f", s*96}')
        suggested="$dpi"
        say "Detected display scale ${pct}% -> suggested DPI ${dpi} (via ${DETECTED_METHOD})"
    else
        warn "Could not detect your display scale; falling back to DPI 96 (100%, no scaling)."
        warn "If you are on a HiDPI screen, set this manually as 96 x your_scale (e.g. 170% -> 163)."
        suggested="96"
    fi
    # Pre-fill with the previously saved value if there is one, else the suggestion.
    def="${current:-$suggested}"
    ans="$(prompt_default "Enter DPI (96 = 100%)" "$def")"
    if ! [[ "$ans" =~ ^[0-9]+$ ]]; then
        warn "Not a whole number; keeping $def."
        ans="$def"
    fi
    DPI="$ans"
}

# ---------------------------------------------------------------------------
# Settings wizard (GPU, DPI, sync) - pre-filled from current values.
# ---------------------------------------------------------------------------
configure_settings() {
    detect_gpu
    say "Detected GPU: ${GPU_NAME:-unknown} (vendor: ${GPU_VENDOR})"
    if [ "$GPU_VENDOR" = "nvidia" ]; then
        warn "Nvidia detected: ANGLE-under-Wine is fussier on Nvidia; 'gl' is the safest choice."
    fi
    # NOTE: we deliberately do NOT auto-pick gl vs vulkan. Whether the canvas
    # renders *correctly* (no glitches) cannot be probed from software - it
    # depends on the exact GPU/driver/ANGLE/DXVK interaction and only shows up
    # visually. So we detect the GPU for information, default to the safe 'gl',
    # and let you eyeball the result and switch. "Reconfigure settings only"
    # can relaunch the app so you can compare backends side by side.
    GPU_BACKEND="$(choose_gpu "$GPU_BACKEND")"

    configure_dpi

    SYNC="$(choose_sync "$SYNC")"

    save_config
}

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------
ensure_deps() {
    say "Installing dependencies (you may be prompted for your password)..."
    # Only what is genuinely required: Wine to run it, winetricks for the win10
    # prefix tweak, 7zip to unpack the installer. The icon ships in the repo, so
    # no icoutils/ImageMagick image tooling is needed.
    sudo dnf install -y wine winetricks 7zip \
        >/dev/null || die "Dependency install failed."
    command -v wine >/dev/null || die "wine not available after install."
    command -v 7z   >/dev/null || die "7z not available after install."
}

# ---------------------------------------------------------------------------
# Build a clean Wine prefix (Windows 10, 64-bit).  [PROTECTED LOGIC]
# wineboot + winetricks win10 are the hard-won working combination; untouched.
# ---------------------------------------------------------------------------
build_prefix() {
    export WINEPREFIX="$PREFIX"
    export WINEARCH=win64
    export WINEDEBUG=-all

    if [ -f "$PREFIX/system.reg" ]; then
        say "Wine prefix already exists at $PREFIX (reusing)."
    else
        say "Creating Wine prefix at $PREFIX ..."
        mkdir -p "$PREFIX"
        wineboot -i >/dev/null 2>&1 || die "wineboot failed to initialise the prefix."
        say "Setting Windows version to 10 ..."
        winetricks -q win10 >/dev/null 2>&1 || warn "winetricks win10 reported an issue; continuing."
    fi
}

# Apply the chosen DPI to the prefix registry (LogPixels). Cheap and idempotent;
# safe to call on reconfigure as long as the prefix exists.
apply_dpi() {
    [ -f "$PREFIX/system.reg" ] || return 0
    say "Applying DPI $DPI to the prefix ..."
    WINEPREFIX="$PREFIX" WINEARCH=win64 WINEDEBUG=-all \
        wine reg add "HKCU\\Control Panel\\Desktop" /v LogPixels /t REG_DWORD /d "$DPI" /f \
        >/dev/null 2>&1 || warn "Could not set DPI; you can adjust it later."
    WINEPREFIX="$PREFIX" wineserver -w 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Extract the app straight out of the installer.  [PROTECTED LOGIC]
# The outer NSIS archive holds the inner electron-builder app archive at the
# literal path $PLUGINSDIR/app-64.7z (NOT a shell variable). Untouched.
# ---------------------------------------------------------------------------
extract_app() {
    WORK="$(mktemp -d)"
    say "Extracting application payload from installer..."
    # shellcheck disable=SC2016  # $PLUGINSDIR is a literal path inside the archive
    7z x "$INSTALLER" '$PLUGINSDIR/app-64.7z' -o"$WORK/outer" >/dev/null \
        || die "Could not extract app-64.7z from the installer (unexpected installer layout)."
    INNER="$(find "$WORK/outer" -iname 'app-64.7z' | head -1)"
    [ -n "$INNER" ] || die "Inner app archive not found inside installer."
    7z x "$INNER" -o"$WORK/app" >/dev/null || die "Could not unpack the application archive."
    [ -f "$WORK/app/${APP_NAME}.exe" ] || die "Extracted payload is missing ${APP_NAME}.exe."

    local dest="$PREFIX/$INSTALL_DIR"
    say "Installing app to: $dest"
    mkdir -p "$dest"
    cp -rf "$WORK/app/." "$dest/"

    rm -rf "$WORK"
    WORK=""
}

# Install the application icon. It ships in the repo as $ICON_FILE, so there is
# no runtime image tooling: copy the bundled file when it sits next to this
# script (git clone), otherwise download it from the repo (curl | bash).
# Best-effort: a missing icon only means the menu entry uses a generic one.
install_icon() {
    say "Installing icon..."
    mkdir -p "$ICON_DIR"
    if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/$ICON_FILE" ]; then
        if cp -f "$SCRIPT_DIR/$ICON_FILE" "$ICON_PATH"; then
            return 0
        fi
    fi
    if command -v curl >/dev/null 2>&1 \
       && curl -fsSL "$ICON_URL" -o "$ICON_PATH" 2>/dev/null \
       && [ -s "$ICON_PATH" ]; then
        return 0
    fi
    warn "Could not place the app icon; the launcher will use a generic icon."
}

# ---------------------------------------------------------------------------
# Generate the launcher from the current settings.  [PROTECTED LOGIC INSIDE]
# The Wine env vars and the stdout/stderr->file redirection (the EBADF fix)
# are unchanged. Only the GPU flags and sync block are driven by config, which
# is exactly what the configurator is for. We deliberately do NOT touch the
# system power profile: that is the user's own preference, not ours to change.
# ---------------------------------------------------------------------------
write_launcher() {
    mkdir -p "$BIN_DIR"

    local gpu_flags sync_block
    case "$GPU_BACKEND" in
        gl)          gpu_flags='--use-angle=gl --ignore-gpu-blocklist --enable-gpu-rasterization' ;;
        vulkan)      gpu_flags='--use-angle=vulkan --ignore-gpu-blocklist --enable-gpu-rasterization' ;;
        disable-gpu) gpu_flags='--disable-gpu' ;;
        *)           gpu_flags='--use-angle=gl --ignore-gpu-blocklist --enable-gpu-rasterization' ;;
    esac

    if sync_enabled; then
        # Exact known-good trio from the original working launcher.
        sync_block=$'export WINENTSYNC=1\nexport WINEFSYNC=1\nexport WINEESYNC=1'
    else
        sync_block='# thread-sync accelerators disabled (no /dev/ntsync, or your choice)'
    fi

    say "Writing launcher: $LAUNCHER"
    cat > "$LAUNCHER" <<EOF
#!/usr/bin/env bash
# Launcher for ${APP_NAME} under Wine. Auto-generated by install.sh.
# Re-run install.sh -> "Reconfigure settings only" to regenerate this file.
#
# EBADF fix: Electron/Node crashes when Wine hands it pipe-type stdout/stderr,
# so we redirect both to real files below. Node then builds plain file writers
# instead of sockets. Do not remove the redirection.
export WINEPREFIX="$PREFIX"
export WINEARCH=win64
$sync_block
export WINEDEBUG=-all
exec /usr/bin/wine "$APP_EXE" \\
    $gpu_flags \\
    >/tmp/${SLUG}-out.log 2>/tmp/${SLUG}-err.log
EOF
    chmod +x "$LAUNCHER"
}

# Generate the desktop entry from the current settings.
write_desktop() {
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
}

refresh_caches() {
    gtk-update-icon-cache "$HOME/.local/share/icons/hicolor" >/dev/null 2>&1 || true
    update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true
    kbuildsycoca6 >/dev/null 2>&1 || true
}

# Offer to launch so the user can eyeball rendering and compare GPU backends.
offer_relaunch() {
    [ -x "$LAUNCHER" ] || return 0
    [ -f "$APP_EXE" ] || return 0
    local ans
    ans="$(prompt_default "Launch now to eyeball the rendering? (yes/no)" "no")"
    if [ "$ans" = "yes" ]; then
        say "Launching... close it, re-run this script, and switch the backend to compare."
        "$LAUNCHER" >/dev/null 2>&1 &
    fi
}

# ---------------------------------------------------------------------------
# Locate an installer .exe (explicit path wins, else newest in ~/Downloads).
# Sets the global INSTALLER. Returns non-zero if nothing is found.
# ---------------------------------------------------------------------------
locate_installer() {
    local given="${1:-}" found=""
    if [ -n "$given" ] && [ -f "$given" ]; then
        found="$given"
    else
        found=$(find "$HOME/Downloads" -maxdepth 1 -iname 'xTool-Studio*.exe' -printf '%T@ %p\n' 2>/dev/null \
            | sort -rn | head -1 | cut -d' ' -f2- || true)
    fi
    if [ -z "$found" ] || [ ! -f "$found" ]; then
        return 1
    fi
    INSTALLER="$(readlink -f "$found")"
    return 0
}

final_notes() {
    say "Done!"
    echo
    echo "  Launch '${APP_NAME}' from your application menu, or run: $LAUNCHER"
    echo "  Logs:        /tmp/${SLUG}-out.log  and  /tmp/${SLUG}-err.log"
    echo "  Wine prefix: $PREFIX"
    echo "  Settings:    $CONFIG_FILE"
    echo
    echo "  Notes:"
    echo "   - First run: set region/login, then connect the F2 over Wi-Fi."
    echo "   - If the app asks to install RNDIS/CH340 drivers, tick 'No more"
    echo "     reminders' and close them (they cannot install under Wine and"
    echo "     reappear otherwise). For a USB cable connection, re-run and pick"
    echo "     'Set up USB device connection'."
    echo "   - Re-run this script any time to reconfigure GPU/DPI/sync without reinstalling."
    echo "   - To uninstall, re-run and pick 'Uninstall'."
}

# ---------------------------------------------------------------------------
# Menu actions
# ---------------------------------------------------------------------------
do_full_install() {
    say "Full install / repair."
    configure_settings
    if ! locate_installer "$INSTALLER_ARG"; then
        die "Could not find an xTool Studio installer.
   Download it from https://www.xtool.com/pages/software, put it in ~/Downloads,
   then re-run:   ./install.sh ~/Downloads/xTool-Studio-x64-VERSION.exe"
    fi
    say "Using installer: $INSTALLER"
    INSTALLER_PATH="$INSTALLER"

    ensure_deps
    build_prefix
    apply_dpi
    extract_app
    install_icon
    write_launcher
    write_desktop
    refresh_caches
    save_config
    final_notes
    offer_relaunch
}

do_reconfigure() {
    say "Reconfigure settings only (no reinstall, no re-extract)."
    if [ ! -f "$PREFIX/system.reg" ]; then
        warn "No Wine prefix yet at $PREFIX. Settings will be saved and the launcher"
        warn "written, but you will still need a full install before the app can run."
    fi
    configure_settings
    write_launcher
    write_desktop
    apply_dpi          # cheap registry tweak; only runs if the prefix exists
    refresh_caches
    say "Settings reapplied."
    offer_relaunch
}

do_update() {
    say "Update app (re-extract from a newer installer into the existing prefix)."
    [ -f "$PREFIX/system.reg" ] || die "No existing prefix at $PREFIX. Run a full install first."
    local p
    p="$(prompt_default "Installer path (blank = newest in ~/Downloads)" "")"
    if [ -n "$p" ]; then
        locate_installer "$p" || die "Installer not found: $p"
    else
        locate_installer || die "No xTool-Studio*.exe found in ~/Downloads."
    fi
    say "Updating app from: $INSTALLER"
    INSTALLER_PATH="$INSTALLER"
    extract_app        # settings, launcher and desktop entry are left untouched
    refresh_caches
    save_config
    say "App updated. Your settings were kept."
}

# ---------------------------------------------------------------------------
# USB device connection (CH340 serial).
#
# The CH340 "driver" xTool Studio offers to install is a no-op under Wine -
# there is no Windows driver model to install into, which is why its box never
# clears. On Linux the kernel IS the driver: the ch341 module exposes the
# adapter as /dev/ttyUSB0. So we set up the Linux side (permissions, a stable
# name, and ModemManager/brltty kept out of the way) and point a Wine COM port
# at it. Needs sudo; to fully verify, the device must be plugged in over USB.
#
# (USB networking via RNDIS is handled automatically by the Linux kernel, so it
# needs no setup here - the same network path your Wi-Fi connection already uses.)
# ---------------------------------------------------------------------------
do_usb_setup() {
    local user="${USER:-$(id -un)}"
    say "USB device connection setup (CH340 serial)."
    {
        echo
        echo "  The CH340 'driver' the app installs does nothing under Wine."
        echo "  Linux's own ch341 module is the driver; we configure the Linux"
        echo "  side and map a Wine COM port to it. In the app you can then tick"
        echo "  'No more reminders' on the CH340 box."
        echo
    } >&2

    # 1) kernel module (the actual driver)
    if modinfo -F filename ch341 >/dev/null 2>&1; then
        say "ch341 module: available (auto-loads when the device is plugged in)."
    else
        warn "ch341 module not found - USB serial may not work on this kernel."
    fi

    # 2) brltty grabs CH340 (vendor 1a86) on many distros, after which the port
    #    vanishes. Only act if a brltty rule actually claims it.
    local brl="" f=""
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if grep -qE '1a86|7523' "$f" 2>/dev/null; then brl="$f"; break; fi
    done < <(find /usr/lib/udev/rules.d /etc/udev/rules.d -iname '*brltty*' 2>/dev/null)
    if [ -n "$brl" ]; then
        warn "brltty claims CH340 devices via: $brl"
        local a
        a="$(prompt_default "Disable it (recommended unless you use a braille display)? (yes/no)" "yes")"
        if [ "$a" = "yes" ]; then
            # A same-named file under /etc overrides the one in /usr/lib;
            # linking it to /dev/null makes it empty.
            if sudo ln -sf /dev/null "/etc/udev/rules.d/$(basename "$brl")"; then
                say "Neutralised brltty's CH340 rule."
            else
                warn "Could not override the brltty rule."
            fi
        fi
    else
        say "brltty: no CH340-claiming rule (good)."
    fi

    # 3) dialout membership (needed to open /dev/ttyUSB*)
    if id -nG "$user" | tr ' ' '\n' | grep -qx dialout; then
        say "dialout group: already a member."
    else
        say "Adding $user to the 'dialout' group..."
        if sudo usermod -aG dialout "$user"; then
            warn "Added - you must log out and back in for it to take effect."
        else
            warn "Could not add you to the dialout group."
        fi
    fi

    # 4) udev rule: stable /dev/xtool name, group access, ModemManager kept away
    say "Installing udev rule: $UDEV_RULE"
    if ! sudo tee "$UDEV_RULE" >/dev/null <<EOF
# xTool engraver CH340/CH341/CH9102 USB-serial adapter.
# Stable /dev/${USB_SYMLINK} symlink, group access, and tell ModemManager to
# leave it alone so the app can open the port.
SUBSYSTEM=="tty", ATTRS{idVendor}=="1a86", SYMLINK+="${USB_SYMLINK}", MODE="0660", GROUP="dialout", ENV{ID_MM_DEVICE_IGNORE}="1"
EOF
    then
        warn "Could not write the udev rule (needs sudo)."
    else
        sudo udevadm control --reload-rules 2>/dev/null || true
        sudo udevadm trigger --subsystem-match=tty 2>/dev/null || true
    fi

    # 5) Wine COM1 -> the stable device symlink
    mkdir -p "$PREFIX/dosdevices"
    ln -sfn "/dev/${USB_SYMLINK}" "$PREFIX/dosdevices/com1"
    say "Mapped Wine COM1 -> /dev/${USB_SYMLINK}"

    # 6) live status
    if command -v lsusb >/dev/null 2>&1 && lsusb 2>/dev/null | grep -qiE '1a86'; then
        say "CH340 device detected now:"
        ls -l /dev/ttyUSB* "/dev/${USB_SYMLINK}" 2>/dev/null || true
    else
        say "No CH340 device plugged in right now - connect the engraver to test."
    fi

    {
        echo
        echo "  Next:"
        echo "   1. Plug the engraver in over USB (if you were just added to"
        echo "      'dialout', log out and back in first)."
        echo "   2. In xTool Studio tick 'No more reminders' on the CH340 box."
        echo "   3. The device should be available over USB. If not, replug once."
        echo
    } >&2
}

do_uninstall() {
    say "Uninstall: removes the app, prefix, launcher, desktop entry and icon."
    local ans
    ans="$(prompt_default "Type 'yes' to confirm" "no")"
    [ "$ans" = "yes" ] || { say "Aborted."; return; }
    rm -rf "$SHARE_DIR" "$LAUNCHER" "$DESKTOP_FILE" "$ICON_PATH"
    local rc
    rc="$(prompt_default "Also remove saved settings ($CONFIG_FILE)? (yes/no)" "no")"
    [ "$rc" = "yes" ] && rm -f "$CONFIG_FILE"
    if [ -e "$UDEV_RULE" ]; then
        local ru
        ru="$(prompt_default "Also remove the USB udev rule ($UDEV_RULE, needs sudo)? (yes/no)" "no")"
        if [ "$ru" = "yes" ]; then
            sudo rm -f "$UDEV_RULE" || true
            sudo udevadm control --reload-rules 2>/dev/null || true
        fi
    fi
    refresh_caches
    say "Uninstalled."
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------
show_menu() {
    echo
    say "xTool Studio on Fedora - installer and configurator"
    if [ -f "$CONFIG_FILE" ]; then
        say "Saved settings: backend=$GPU_BACKEND dpi=${DPI:-unset} sync=$SYNC"
    else
        say "No saved settings yet (first run)."
    fi
    echo

    local PS3="Select an option (number): "
    local opt
    select opt in \
        "Full install / repair" \
        "Reconfigure settings only" \
        "Update app (re-extract from newer installer)" \
        "Set up USB device connection (CH340 serial)" \
        "Uninstall" \
        "Quit"; do
        case "$opt" in
            "Full install / repair")                        do_full_install; break ;;
            "Reconfigure settings only")                    do_reconfigure;  break ;;
            "Update app (re-extract from newer installer)")  do_update;       break ;;
            "Set up USB device connection (CH340 serial)")   do_usb_setup;    break ;;
            "Uninstall")                                    do_uninstall;    break ;;
            "Quit")                                         say "Bye.";      break ;;
            *)                                              warn "Invalid choice; enter a number 1-6." ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
load_config
show_menu
