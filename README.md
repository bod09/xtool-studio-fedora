# xTool Studio on Fedora (Wine, no Bottles)

A one-shot installer that runs **xTool Studio** on Fedora through system Wine —
no Bottles, no Steam, no manual fiddling. It builds a clean Wine prefix,
extracts the app straight out of its installer (bypassing the broken Electron
installer that fails under Wine), fixes the Electron `EBADF` startup crash, and
drops a one-click launcher into your application menu with working
performance/rendering flags baked in.

Tested on Fedora 44 (KDE Plasma) with an AMD Radeon 890M iGPU and an xTool F2
connected over Wi-Fi.

## What you need first

1. **Fedora** (uses `dnf`).
2. **The xTool Studio installer `.exe`** — download it from
   <https://www.xtool.com/pages/software> and put it in `~/Downloads`.
   (The installer can't be auto-downloaded; xTool's links aren't stable.)

## Install

Put the installer in `~/Downloads`, then run:

```bash
curl -fsSL https://raw.githubusercontent.com/<YOUR_USER>/<YOUR_REPO>/main/install.sh | bash
```

The script auto-detects the newest `xTool-Studio*.exe` in `~/Downloads`.

To point it at a specific file instead:

```bash
curl -fsSL https://raw.githubusercontent.com/<YOUR_USER>/<YOUR_REPO>/main/install.sh \
  | bash -s -- /path/to/xTool-Studio-x64-1.7.30.exe
```

Or clone and run locally:

```bash
git clone https://github.com/<YOUR_USER>/<YOUR_REPO>.git
cd <YOUR_REPO>
./install.sh ~/Downloads/xTool-Studio-x64-1.7.30.exe
```

When it finishes, launch **xTool Studio** from your app menu.

## Match the scale on your display (DPI)

Wine renders at 96 DPI by default, which looks tiny on a HiDPI screen. The
script sets DPI to **163**, which matches a desktop scale of **170 %**
(`96 × 1.70 ≈ 163`).

If your desktop uses a different scale, edit the `DPI=` line near the top of
`install.sh` before running, using `96 × (your scale ÷ 100)`. For example:
125 % → 120, 150 % → 144, 200 % → 192.

## First run

1. Pick your region and sign in / create an account.
2. Connect the F2: it needs a **one-time USB connection on any computer** (e.g.
   a Windows PC) to save Wi-Fi credentials to the machine. After that it joins
   your network and Studio finds it over Wi-Fi — no USB needed on Linux.
3. Make sure the PC and the F2 are on the same network.

## Performance note

The editor runs but feels sluggish — this is the inherent cost of a Chromium
canvas going through Wine on an integrated GPU, not a misconfiguration. The
launcher already uses the fastest *stable* setup:

* `ntsync`/`fsync` fast thread synchronization
* the `performance` power profile (set on each launch)
* hardware-accelerated rendering via `--use-angle=gl`

`--use-angle=vulkan` is marginally faster but reintroduces visual glitches
(ANGLE and DXVK fighting over the same Vulkan driver), so `gl` is the default.
For heavy design work, consider editing on a native Windows install and using
the Fedora install to send jobs.

## Updating

In-app auto-update will likely fail (it relaunches the same Electron installer
that breaks under Wine). To update, download the new installer and re-run the
script — it reuses the existing prefix and just swaps the app files:

```bash
./install.sh ~/Downloads/xTool-Studio-x64-NEWVERSION.exe
```

## Uninstall

```bash
rm -rf ~/.local/share/xtool-studio \
       ~/.local/bin/xtool-studio.sh \
       ~/.local/share/applications/xtool-studio.desktop \
       ~/.local/share/icons/hicolor/256x256/apps/xtool-studio.png
```

## How it works (the short version)

* **No Bottles.** Bottles only ever built the prefix; at runtime we call
  `/usr/bin/wine` directly. The script builds the prefix itself with `wineboot`.
* **Installer bypass.** xTool's Electron installer aborts under Wine on its
  "close running instance" check. The app payload is just a 7-Zip archive
  (`$PLUGINSDIR/app-64.7z`) inside the `.exe`, so we extract and copy it.
* **EBADF fix.** Electron crashes when Wine hands Node pipe-type stdout/stderr.
  The launcher runs Wine with stdout/stderr redirected to real files, so Node
  builds plain file writers instead of sockets.

## Disclaimer

Unofficial. xTool does not support Linux. Use at your own risk.
